"""Resolve RSS wrappers before publisher retrieval, with no independent transport.

The public Google ``Fbv4je`` / ``garturlreq`` wire protocol is documented by
https://github.com/SSujitX/google-news-url-decoder (MIT). This implementation
uses the caller's bounded, DNS-vetted downloader and never treats a Google
wrapper page, feed publication date, or arbitrary page link as source evidence.
"""
from __future__ import annotations

import base64
import binascii
import ipaddress
import json
import re
import urllib.parse
from html.parser import HTMLParser
from typing import Callable


class GoogleNewsResolveError(RuntimeError):
    """Sanitized resolution failure, suitable for conversion to ResearchError."""


Download = Callable[..., tuple[str, str, str]]
_BATCH_URL = "https://news.google.com/_/DotsSplashUi/data/batchexecute?rpcids=Fbv4je"


def is_google_news_url(url: str) -> bool:
    try:
        return urllib.parse.urlsplit(url).hostname == "news.google.com"
    except (ValueError, TypeError):
        return False


def _publisher_url(value: str) -> str:
    try:
        if not isinstance(value, str) or len(value) > 16_384 or any(ord(c) <= 32 for c in value):
            raise ValueError
        parsed = urllib.parse.urlsplit(value)
        host = parsed.hostname or ""
        if (parsed.scheme != "https" or not host or parsed.username or parsed.password
                or parsed.port not in (None, 443) or "\\" in value
                or host == "localhost" or host.endswith(".local")
                or any(host == domain or host.endswith("." + domain)
                       for domain in ("google.com", "googleusercontent.com", "gstatic.com"))):
            raise ValueError
        try:
            address = ipaddress.ip_address(host)
        except ValueError:
            address = None
        if address is not None and not address.is_global:
            raise ValueError
        return urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, parsed.path or "/", parsed.query, ""))
    except (TypeError, ValueError):
        raise GoogleNewsResolveError("GOOGLE_NEWS_DESTINATION: no valid original HTTPS publisher URL") from None


def _article_id(url: str) -> str:
    try:
        parsed = urllib.parse.urlsplit(url)
        match = re.fullmatch(r"/(?:rss/)?(?:articles|read)/([A-Za-z0-9_-]{8,4096})/?", parsed.path)
        if (parsed.scheme != "https" or parsed.hostname != "news.google.com"
                or parsed.username or parsed.password or parsed.port not in (None, 443) or not match):
            raise ValueError
        return match.group(1)
    except (ValueError, TypeError):
        raise GoogleNewsResolveError("GOOGLE_NEWS_URL: unsupported Google News article URL") from None


def _legacy_url(token: str) -> str | None:
    """Old IDs carry a protobuf length-delimited field containing the URL."""
    try:
        raw = base64.b64decode(token + "=" * (-len(token) % 4), altchars=b"-_", validate=True)
    except (ValueError, binascii.Error):
        return None
    if not raw.startswith(b"\x08\x13\x22"):
        return None
    size, cursor, shift = 0, 3, 0
    while cursor < len(raw) and shift <= 28:
        byte = raw[cursor]
        cursor += 1
        size |= (byte & 0x7F) << shift
        if byte < 0x80:
            break
        shift += 7
    else:
        return None
    if size <= 0 or cursor + size > len(raw):
        return None
    value = raw[cursor:cursor + size]
    if not value.startswith((b"https://", b"http://")):
        return None
    try:
        return _publisher_url(value.decode("utf-8"))
    except UnicodeError:
        raise GoogleNewsResolveError("GOOGLE_NEWS_DESTINATION: malformed original publisher URL") from None


class _ArticlePage(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.signature: str | None = None
        self.timestamp: str | None = None
        self.canonical: list[str] = []

    def handle_starttag(self, tag, attrs):
        attributes = dict(attrs)
        if attributes.get("data-n-a-sg") and attributes.get("data-n-a-ts"):
            self.signature = attributes["data-n-a-sg"]
            self.timestamp = attributes["data-n-a-ts"]
        # Only explicit canonical metadata qualifies. Ordinary links can point
        # to unrelated articles, subscriptions or Google's own help pages.
        if tag == "link" and "canonical" in (attributes.get("rel") or "").lower().split():
            if attributes.get("href"):
                self.canonical.append(attributes["href"])


def _request_body(token: str, timestamp: str, signature: str) -> bytes:
    # Fixed locale/context fields required by Google's public article resolver.
    context = [["X", "X", ["X", "X"], None, None, 1, 1, "US:en", None, 1,
                None, None, None, None, None, 0, 1], "X", "X", 1,
               [1, 1, 1], 1, 1, None, 0, 0, None, 0]
    request = ["garturlreq", context, token, int(timestamp), signature]
    rpc = [[ ["Fbv4je", json.dumps(request, separators=(",", ":"))] ]]
    return urllib.parse.urlencode({"f.req": json.dumps(rpc, separators=(",", ":"))}).encode("ascii")


def _response_url(content: str) -> str:
    """Read framed JSON and require the matching RPC's garturlres payload."""
    decoder = json.JSONDecoder()
    candidates: set[str] = set()

    def visit(node):
        if not isinstance(node, list):
            return
        if len(node) >= 3 and node[0] == "wrb.fr" and node[1] == "Fbv4je":
            try:
                payload = json.loads(node[2])
            except (TypeError, ValueError):
                return
            if isinstance(payload, list) and len(payload) >= 2 and payload[0] == "garturlres":
                candidates.add(_publisher_url(payload[1]))
            return
        for child in node:
            if isinstance(child, list):
                visit(child)

    # Responses may contain an XSSI prefix, byte-count lines and several JSON
    # frames. Parse only complete frames; do not regex a URL out of raw text.
    cursor, frames = 0, 0
    while cursor < len(content) and frames < 64:
        end = content.find("\n", cursor)
        end = len(content) if end == -1 else end
        start = cursor
        while start < end and content[start].isspace():
            start += 1
        if start < end and content[start] == "[":
            try:
                node, next_cursor = decoder.raw_decode(content, start)
            except (ValueError, RecursionError):
                pass
            else:
                try:
                    visit(node)
                except RecursionError:
                    raise GoogleNewsResolveError("GOOGLE_NEWS_RESPONSE: malformed resolver response") from None
                frames += 1
                cursor = max(next_cursor, end + 1)
                continue
        cursor = end + 1
    if len(candidates) != 1:
        raise GoogleNewsResolveError("GOOGLE_NEWS_RESPONSE: original publisher URL missing or ambiguous")
    return next(iter(candidates))


def resolve_google_url(url: str, download: Download) -> str:
    """Return an original HTTPS URL or fail; use at most one GET and one POST.

    ``download(url, data=None)`` returns ``(final_url, body, content_type)``.
    Non-None data is a form-encoded POST. The caller owns request budgeting,
    response-size limits, total timeout and public-address validation. This
    helper does not fetch the publisher or add anything to the source ledger.
    """
    if not is_google_news_url(url):
        return _publisher_url(url)
    token = _article_id(url)
    legacy = _legacy_url(token)
    if legacy is not None:
        return legacy
    try:
        final, content, _ = download("https://news.google.com/articles/" + token)
    except Exception:
        raise GoogleNewsResolveError("GOOGLE_NEWS_NETWORK: article redirect could not be retrieved") from None
    if not is_google_news_url(final):
        return _publisher_url(final)
    parser = _ArticlePage()
    try:
        parser.feed(content)
    except (ValueError, RecursionError):
        raise GoogleNewsResolveError("GOOGLE_NEWS_RESPONSE: article redirect could not be parsed") from None
    canonical = set()
    for link in parser.canonical:
        try:
            canonical.add(_publisher_url(urllib.parse.urljoin(final, link)))
        except GoogleNewsResolveError:
            continue
    if len(canonical) == 1:
        return next(iter(canonical))
    if (not parser.signature or len(parser.signature) > 2048 or not parser.timestamp
            or not re.fullmatch(r"\d{1,16}", parser.timestamp)):
        raise GoogleNewsResolveError("GOOGLE_NEWS_PARAMETERS: article resolver metadata unavailable")
    try:
        _, response, _ = download(_BATCH_URL, data=_request_body(token, parser.timestamp, parser.signature))
    except Exception:
        raise GoogleNewsResolveError("GOOGLE_NEWS_NETWORK: publisher URL resolution failed") from None
    return _response_url(response)
