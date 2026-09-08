"""Public-web retrieval with a per-run provenance ledger; no model supplied fetch code."""
from __future__ import annotations

import asyncio
import dataclasses
import html
import http.client
import ipaddress
import json
import re
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from html.parser import HTMLParser


class ResearchError(RuntimeError):
    """A sanitized error safe to show in the UI."""


def normalize(text: str) -> str:
    return re.sub(r"\s+", " ", html.unescape(text)).strip()


def canonical_url(url: str) -> str:
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        raise ResearchError("SOURCE_URL: only public HTTPS URLs without credentials are supported")
    if parsed.port not in (None, 443):
        raise ResearchError("SOURCE_URL: nonstandard network port rejected")
    params = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
    params = [(k, v) for k, v in params if not k.lower().startswith("utm_")
              and k.lower() not in {"gclid", "fbclid", "mc_cid", "mc_eid"}]
    return urllib.parse.urlunsplit(("https", parsed.hostname.lower(), parsed.path or "/",
                                  urllib.parse.urlencode(sorted(params)), ""))


def check_public_url(url: str) -> str:
    url = canonical_url(url)
    host = urllib.parse.urlsplit(url).hostname
    try:
        addresses = resolve_public(host, 443)
    except OSError:
        raise ResearchError("SOURCE_DNS: public source could not be resolved") from None
    if not addresses or any(not ipaddress.ip_address(row[4][0]).is_global for row in addresses):
        raise ResearchError("SOURCE_URL: private or local network destination rejected")
    return url


class PublicRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        canonical_url(newurl)  # actual peer is vetted and pinned by the connection
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def resolve_public(host, port):
    # macOS getaddrinfo can block well beyond a socket timeout. A short-lived
    # fixed-code helper gives DNS a real wall-clock bound without stuck threads.
    script = "import json,socket,sys; print(json.dumps(socket.getaddrinfo(sys.argv[1],int(sys.argv[2]),type=socket.SOCK_STREAM)))"
    try:
        result = subprocess.run([sys.executable, "-c", script, host, str(port)],
                                capture_output=True, text=True, timeout=6, check=True)
        return json.loads(result.stdout)
    except (subprocess.SubprocessError, OSError, ValueError):
        raise ResearchError("SOURCE_DNS: public source lookup failed or exceeded six seconds") from None


def public_connection(address, timeout=12, source_address=None, **kwargs):
    """Pin DNS-vetted sockaddr at connect time; never resolve it a second time."""
    host, port = address
    started = time.monotonic()
    addresses = resolve_public(host, port)
    if not addresses or any(not ipaddress.ip_address(row[4][0]).is_global for row in addresses):
        raise ResearchError("SOURCE_URL: private or local network destination rejected")
    # IPv4 first avoids black-holed IPv6 on some local networks. All DNS results
    # were vetted above; each connect uses the already-vetted numeric sockaddr.
    addresses = sorted(addresses, key=lambda row: row[0] != socket.AF_INET)[:4]
    for family, kind, protocol, _, sockaddr in addresses:
        remaining = timeout - (time.monotonic() - started)
        if remaining <= 0:
            break
        connection = socket.socket(family, kind, protocol)
        try:
            connection.settimeout(min(3, remaining))
            if source_address:
                connection.bind(source_address)
            connection.connect(tuple(sockaddr))
            connection.settimeout(max(0.1, timeout - (time.monotonic() - started)))
            return connection
        except OSError:
            connection.close()
    raise OSError("Public source connection failed")


class PublicHTTPSConnection(http.client.HTTPSConnection):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        # HTTPSConnection preserves the original hostname for TLS certificate/SNI.
        self._create_connection = public_connection


class PublicHTTPSHandler(urllib.request.HTTPSHandler):
    def https_open(self, req):
        return self.do_open(PublicHTTPSConnection, req, context=self._context)


class PageText(HTMLParser):
    """Keep article text and link discovery; discard executable/hidden head content."""
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.skip = 0
        self.parts: list[str] = []
        self.links: list[str] = []

    def handle_starttag(self, tag, attrs):
        if tag in {"script", "style", "head", "noscript", "svg"}:
            self.skip += 1
        if tag == "a":
            self.links.extend(value for key, value in attrs if key == "href" and value)
        if tag in {"p", "div", "tr", "li", "br", "article", "h1", "h2", "h3"}:
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag in {"script", "style", "head", "noscript", "svg"}:
            self.skip = max(0, self.skip - 1)
        if tag in {"p", "div", "tr", "li", "article", "td", "th"}:
            self.parts.append("\n" if tag not in {"td", "th"} else " | ")

    def handle_data(self, data):
        if not self.skip:
            self.parts.append(data)

    @property
    def text(self):
        return "\n".join(normalize(line) for line in "".join(self.parts).splitlines()
                         if normalize(line))


@dataclasses.dataclass
class Document:
    url: str
    text: str
    retrieved_at: float
    links: list[str] = dataclasses.field(default_factory=list)

    def payload(self):
        return {"url": self.url, "retrievedAt": self.retrieved_at,
                "text": self.text, "links": self.links[:80]}


CALENDARS = {
    "BLS": "https://www.bls.gov/schedule/news_release/bls.ics",
    "Federal Reserve": "https://www.federalreserve.gov/monetarypolicy/fomccalendars.htm",
    "BEA": "https://www.bea.gov/news/schedule/ics/online-calendar-subscription.ics",
}
SEARCH_TOPICS = {
    "geopolitics_iran": "Iran",
    "geopolitics_ukraine": "Ukraine",
    "geopolitics_taiwan": "Taiwan",
    "policy_rates": "Federal Reserve",
    "policy_trade": "US tariffs",
    "crypto_bitcoin": "Bitcoin",
    "crypto_ethereum": "Ethereum",
}


class Research:
    def __init__(self, timeout: float = 12, max_requests: int = 45):
        self.timeout = timeout
        self.remaining = max_requests
        self.documents: dict[str, Document] = {}
        self.searches: dict[str, list[dict]] = {}
        self.failures: list[str] = []
        self.calendar_failures: list[str] = []
        self.failed_fetches: set[str] = set()
        self.failed_searches: set[str] = set()
        self.calendar_document_urls: set[str] = {canonical_url(url) for url in CALENDARS.values()}
        self.coverage_notes: list[str] = []
        self.blocked_urls: dict[str, str] = {}

    def _download(self, url: str, data: bytes | None = None) -> tuple[str, str, str]:
        self.remaining -= 1
        if self.remaining < 0:
            raise ResearchError("RESEARCH_BUDGET: maximum public-source requests reached")
        url = canonical_url(url)
        if data is not None and urllib.parse.urlsplit(url).hostname != "news.google.com":
            raise ResearchError("SOURCE_METHOD: form requests are only allowed for the Google News resolver")
        headers = {
            # FRED stalls requests bearing browser user-agent strings on this
            # host; its public calendar responds promptly to curl compatibility.
            "User-Agent": "curl/8.7.1" if urllib.parse.urlsplit(url).hostname == "fred.stlouisfed.org" else "Mozilla/5.0 (compatible; MayStockResearch/1.0)",
            "Accept": "text/html,application/rss+xml,application/xml,text/calendar,text/plain;q=0.9",
        }
        if data is not None:
            headers["Content-Type"] = "application/x-www-form-urlencoded;charset=UTF-8"
        request = urllib.request.Request(url, data=data, headers=headers)
        try:
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), PublicRedirects(), PublicHTTPSHandler())
            with opener.open(request, timeout=self.timeout) as response:
                content_type = response.headers.get_content_type()
                if content_type not in {"text/html", "text/plain", "text/calendar", "application/xml", "application/json",
                                        "text/xml", "application/rss+xml", "application/atom+xml", "application/octet-stream"}:
                    raise ResearchError("SOURCE_FORMAT: source does not provide readable text")
                data = response.read(2_000_001)
                if len(data) > 2_000_000:
                    raise ResearchError("SOURCE_SIZE: source exceeds two megabytes")
                return canonical_url(response.url), data.decode(response.headers.get_content_charset() or "utf-8", errors="replace"), content_type
        except ResearchError:
            raise
        except urllib.error.HTTPError as exc:
            raise ResearchError(f"SOURCE_HTTP_{exc.code}: source retrieval failed") from None
        except (OSError, urllib.error.URLError, TimeoutError):
            raise ResearchError("SOURCE_NETWORK: source retrieval timed out or failed") from None

    def _fetch(self, url: str) -> Document:
        key = canonical_url(url)
        if key in self.documents:
            return self.documents[key]
        if key in self.blocked_urls:
            raise ResearchError(self.blocked_urls[key])
        if __package__:
            from .google_news import GoogleNewsResolveError, is_google_news_url, resolve_google_url
        else:
            from google_news import GoogleNewsResolveError, is_google_news_url, resolve_google_url
        if is_google_news_url(key):
            try:
                publisher = resolve_google_url(key, self._download)
                document = self._fetch(publisher)
                self.documents[key] = document
                return document
            except GoogleNewsResolveError:
                error = "GOOGLE_NEWS_UNRESOLVED: cannot resolve original publisher; search exact title with publisher domain"
                self.blocked_urls[key] = error
                raise ResearchError(error) from None
        final, content, content_type = self._download(key)
        links = []
        if "html" in content_type or content.lstrip().lower().startswith(("<!doctype html", "<html")):
            page = PageText()
            page.feed(content)
            text = page.text
            for link in page.links:
                try:
                    links.append(canonical_url(urllib.parse.urljoin(final, link)))
                except (ResearchError, ValueError):
                    continue
        else:
            text = content
        if len(normalize(text)) < 80:
            raise ResearchError("SOURCE_EMPTY: source returned no substantive text")
        lower = normalize(text[:1500]).lower()
        if any(s in lower for s in ["verify you are human", "enable javascript and cookies to continue",
                                     "access denied", "unusual traffic from your computer"]):
            raise ResearchError("SOURCE_BLOCKED: publisher denied automated reading")
        document = Document(final, text[:100_000], time.time(), list(dict.fromkeys(links)))
        self.documents[key] = self.documents[final] = document
        return document

    async def fetch(self, url: str) -> dict:
        key = canonical_url(url)
        try:
            result = (await asyncio.to_thread(self._fetch, url)).payload()
            self.failed_fetches.discard(key)
            return result
        except ResearchError as exc:
            self.failed_fetches.add(key)
            if str(exc).startswith(("SOURCE_HTTP_403", "SOURCE_HTTP_404", "SOURCE_BLOCKED", "SOURCE_EMPTY", "SOURCE_FORMAT")):
                self.blocked_urls[key] = str(exc)
            raise

    def _search(self, query: str) -> list[dict]:
        if not query.strip() or len(query) > 500:
            raise ResearchError("SEARCH_QUERY: invalid query")
        # RSS is discovery only: pubDate/seen-date is NEVER occurrence evidence.
        bing_query = re.sub(r"\s+when:\S+", "", query)
        urls = ["https://www.bing.com/news/search?" + urllib.parse.urlencode({"q": bing_query, "format": "rss", "sortbydate": "1"}),
                "https://news.google.com/rss/search?" + urllib.parse.urlencode({"q": query, "hl": "en-US", "gl": "US", "ceid": "US:en"})]
        successful_feed = False
        for url in urls:
            try:
                _, content, _ = self._download(url)
                root = ET.fromstring(content)
                if root.tag not in {"rss", "{http://www.w3.org/2005/Atom}feed"}:
                    raise ResearchError("SEARCH_FORMAT: search endpoint did not return a feed")
                successful_feed = True
                rows = []
                for item in root.findall(".//item")[:24]:
                    link = item.findtext("link", "")
                    # Bing wraps publisher links in /news/apiclick.aspx?url=...
                    parts = urllib.parse.urlsplit(link)
                    if parts.hostname and parts.hostname.endswith("bing.com"):
                        link = urllib.parse.parse_qs(parts.query).get("url", [link])[0]
                    rows.append({"title": normalize(item.findtext("title", "")), "url": link,
                                 "publishedAtText": item.findtext("pubDate", ""),
                                 "publisher": item.findtext("source", ""),
                                 "publisherUrl": item.find("source").get("url", "") if item.find("source") is not None else "",
                                 "discoverySnippet": normalize(item.findtext("description", ""))[:1000]})
                if rows:
                    self.searches[query] = rows
                    return rows
            except (ResearchError, ET.ParseError, ValueError):
                continue
        if successful_feed:
            self.searches[query] = []
            return []
        raise ResearchError("SEARCH_UNAVAILABLE: both news search providers failed; this is not a no-news result")

    async def search(self, query: str) -> list[dict]:
        try:
            result = await asyncio.to_thread(self._search, query)
            self.failed_searches.discard(query)
            return result
        except ResearchError:
            self.failed_searches.add(query)
            raise

    async def bootstrap(self, kind: str) -> dict:
        tasks = {name: self.search(query) for name, query in SEARCH_TOPICS.items()}
        if kind == "daily":
            tasks.update({name: self.fetch(url) for name, url in CALENDARS.items()})
        async def timed(name, operation):
            started = time.monotonic()
            print(json.dumps({"stage": "bootstrap_source_start", "source": name}), file=sys.stderr, flush=True)
            try:
                return await operation
            finally:
                print(json.dumps({"stage": "bootstrap_source_done", "source": name,
                                  "seconds": round(time.monotonic() - started, 2)}), file=sys.stderr, flush=True)
        results = await asyncio.gather(*(timed(name, operation) for name, operation in tasks.items()), return_exceptions=True)
        output = {}
        for name, value in zip(tasks, results):
            if isinstance(value, Exception):
                if name in CALENDARS:
                    self.calendar_failures.append(name)
                    self.failed_fetches.discard(canonical_url(CALENDARS[name]))
                else:
                    self.failures.append(name)
            else:
                output[name] = value
        if self.failures:
            raise ResearchError("RESEARCH_INCOMPLETE: required sources unavailable: " + ", ".join(self.failures))
        if self.calendar_failures:
            output["calendarCoverageGaps"] = self.calendar_failures.copy()
        if "BLS" in self.calendar_failures:
            # FRED is a Federal Reserve Bank source that republishes the BLS CPI
            # release schedule. It is explicitly labeled secondary provenance.
            fallback = f"https://fred.stlouisfed.org/releases/calendar?rid=10&y={time.gmtime().tm_year}"
            try:
                output["CPI_calendar_via_FRED"] = await self.fetch(fallback)
                self.calendar_document_urls.add(canonical_url(fallback))
                self.coverage_notes.append("BLS直连失败；CPI日程采用圣路易斯联储FRED转引的发布日历，其余BLS日程仍有缺口。")
            except ResearchError:
                self.failed_fetches.discard(canonical_url(fallback))
                self.coverage_notes.append("BLS直连及FRED的CPI日历回退均未读取成功。")
        output["unreadableURLs"] = list(self.blocked_urls)
        return output
