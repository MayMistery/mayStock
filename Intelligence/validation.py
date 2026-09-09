"""Deterministic boundaries after the model: provenance, occurrence time, dedup, quotes."""
from __future__ import annotations

import copy
import datetime as dt
import difflib
import hashlib
import math
import re
import urllib.parse
from zoneinfo import ZoneInfo

if __package__:
    from .model_selection import DEFAULT_MODEL, normalize_model
    from .research import CALENDARS, SEARCH_TOPICS, Research, ResearchError, canonical_url, normalize
    from .schema import REPORT_SCHEMA
else:
    from model_selection import DEFAULT_MODEL, normalize_model
    from research import CALENDARS, SEARCH_TOPICS, Research, ResearchError, canonical_url, normalize
    from schema import REPORT_SCHEMA

UTC = dt.timezone.utc
MAX_QUOTE_AGE = 300
DISCOVERY_HOSTS = {"news.google.com", "www.bing.com", "bing.com"}
PUBLISHING = re.compile(r"\b(?:published|updated|posted|last modified|datepublished|datemodified)\b", re.I)
ISO_TIME = re.compile(r"\b\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(?::\d{2})?(?:Z|\s*(?:UTC|GMT)|[+-]\d{2}:?\d{2})\b", re.I)
NATURAL_DATE = re.compile(r"\b(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?|tember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\.?\s+\d{1,2}(?:st|nd|rd|th)?[,]?\s+\d{4}\b", re.I)
DATE_ISO = re.compile(r"\b\d{4}-\d{2}-\d{2}\b")
EXPLICIT_TIME = re.compile(r"\b\d{1,2}:\d{2}(?::\d{2})?\s*(?:[ap]\.?m\.?)?\s*(?:UTC|GMT|EST|EDT|ET|PST|PDT|PT|[+-]\d{2}:?\d{2})\b", re.I)
RETROSPECTIVE = re.compile(r"\b(?:yesterday|previously|last (?:week|month|year|night)|days? (?:ago|earlier)|hours? (?:ago|earlier))\b|昨日|昨天|此前|去年|上周|上月", re.I)
FUTURE_INTENT = re.compile(r"\b(?:will|scheduled|expected to|plans to|next briefing)\b", re.I)
OCCURRENCE = re.compile(r"\b(?:announced|released|struck|attacked|launched|began|started|signed|voted|approved|rejected|halted|suspended|resumed|killed|exploded|explosion|hit|took effect|entered into force|effective|occurred|happened|detonated|agreed|ordered|seized|breached|hacked|filed|met|meeting|scheduled|release|statement)\b|宣布|发生|发动|生效|袭击|签署|发布|暂停|重启|会议|决议", re.I)


def finite(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def parse_request(request: dict) -> dict:
    if not isinstance(request, dict) or request.get("kind") not in {"daily", "hourly", "flash"}:
        raise ResearchError("REQUEST_INVALID: expected daily, hourly or flash request")
    if not finite(request.get("now")) or not 0 < request["now"] < 32_503_680_000:
        raise ResearchError("REQUEST_INVALID: now must be a finite Unix timestamp")
    try:
        ZoneInfo(request["timezone"])
    except (KeyError, ValueError, TypeError):
        raise ResearchError("REQUEST_INVALID: timezone must be an IANA timezone") from None
    watchlist = request.get("watchlist")
    if not isinstance(watchlist, list) or len(watchlist) > 200 or any(
        not isinstance(x, str) or not x.strip() or len(x) > 80 for x in watchlist
    ):
        raise ResearchError("REQUEST_INVALID: watchlist must contain instrument identifiers")
    if not finite(request.get("horizonHours")) or not 0 < request["horizonHours"] <= 720:
        raise ResearchError("REQUEST_INVALID: prediction horizon must be in (0, 720] hours")
    if not isinstance(request.get("quotes", []), list) or not isinstance(request.get("knownEvents", []), list):
        raise ResearchError("REQUEST_INVALID: quotes and knownEvents must be arrays")
    venues = request.get("venues", {})
    if not isinstance(venues, dict) or any(inst not in watchlist or venue not in {"okx", "schwab"}
                                           for inst, venue in venues.items()):
        raise ResearchError("REQUEST_INVALID: venues must map watchlist instruments to supported venues")
    request = copy.deepcopy(request)
    request["model"] = normalize_model(request.get("model", DEFAULT_MODEL))
    request["watchlist"] = list(dict.fromkeys(watchlist))
    request.setdefault("quotes", [])
    request.setdefault("knownEvents", [])
    return request


def window(request):
    now = request["now"]
    if request["kind"] != "daily":
        return now - (1800 if request["kind"] == "flash" else 3600), now
    today = dt.datetime.fromtimestamp(now, ZoneInfo(request["timezone"])).replace(hour=0, minute=0, second=0, microsecond=0)
    # End is exclusive: today-7 ... today+30, including 23/25-hour DST days.
    return (today - dt.timedelta(days=7)).timestamp(), (today + dt.timedelta(days=31)).timestamp()


def occurrence_timestamps(evidence: str, planned=False) -> list[float]:
    """Accept explicit occurrence dates/times, never bare article publishing metadata.

    Deliberately conservative: '20 minutes ago' and liveblog timestamp headings do
    not establish when the described event occurred. Exact occurrence prose is
    required for rolling flash/hourly windows.
    """
    from dateutil import parser

    text = normalize(evidence)
    if PUBLISHING.search(text) or RETROSPECTIVE.search(text) or not OCCURRENCE.search(text):
        return []
    if not planned and FUTURE_INTENT.search(text):
        return []
    # Never combine a date and time-of-day taken from unrelated event clauses.
    if len(NATURAL_DATE.findall(text)) + len(DATE_ISO.findall(text)) != 1:
        return []
    found = []
    text = re.sub(r"\b([ap])\.m\.", r"\1m", text, flags=re.I)
    for clause in re.split(r"(?<=[.!?])\s+", text):
        if not OCCURRENCE.search(clause):
            continue
        candidates = ISO_TIME.findall(clause)
        date_pattern = "(?:" + NATURAL_DATE.pattern + "|" + DATE_ISO.pattern + ")"
        bound = re.compile("(" + date_pattern + r")\s*(?:,|at)?\s*(" + EXPLICIT_TIME.pattern + ")", re.I)
        candidates.extend(date + " " + clock for date, clock in bound.findall(clause))
        for candidate in candidates:
            try:
                parsed = parser.parse(candidate,
                                      tzinfos={"UTC": 0, "GMT": 0, "EST": -18000, "EDT": -14400,
                                               "PST": -28800, "PDT": -25200,
                                               "ET": ZoneInfo("America/New_York"), "PT": ZoneInfo("America/Los_Angeles")})
                if parsed.tzinfo:
                    found.append(parsed.timestamp())
            except (ValueError, OverflowError):
                pass
    return found


def calendar_timestamp(evidence: str) -> float | None:
    match = re.search(r"DTSTART((?:;[^:\r\n]+)*):([0-9]{8}(?:T[0-9]{6}Z?)?)", evidence)
    if not match:
        return None
    parameters, raw = match.groups()
    tz_match = re.search(r";TZID=([^;\s]+)", parameters)
    tz_name = tz_match.group(1) if tz_match else None
    try:
        date = dt.datetime.strptime(raw.rstrip("Z"), "%Y%m%dT%H%M%S" if "T" in raw else "%Y%m%d")
        zone = UTC if raw.endswith("Z") else ZoneInfo(tz_name or "America/New_York")
        return date.replace(tzinfo=zone).timestamp()
    except (ValueError, KeyError):
        return None


def source_is_primary_calendar(url):
    host = urllib.parse.urlsplit(url).hostname or ""
    return any(host == base or host.endswith("." + base)
               for base in {"bls.gov", "bea.gov", "federalreserve.gov", "fred.stlouisfed.org"})


def fred_cpi_timestamps(evidence, full_text):
    from dateutil import parser
    if "All times are US Central Time" not in normalize(full_text):
        return []
    pattern = re.compile("(" + NATURAL_DATE.pattern + r")(?:\s+Updated)?\s*\|\s*(\d{1,2}:\d{2}\s*[ap]m)\s*\|\s*Consumer Price Index", re.I)
    return [parser.parse(date + " " + clock).replace(tzinfo=ZoneInfo("America/Chicago")).timestamp()
            for date, clock in pattern.findall(normalize(evidence))]


def verified_minute(event, research=None):
    for source in event["sources"]:
        evidence = source["evidence"]
        if event["status"] == "scheduled" and source_is_primary_calendar(source["url"]):
            stamp = calendar_timestamp(evidence)
            if stamp is not None and abs(stamp - event["occurredAt"]) < 60:
                return True
            if research and urllib.parse.urlsplit(source["url"]).hostname == "fred.stlouisfed.org":
                document = research.documents.get(canonical_url(source["url"]))
                if document and any(abs(stamp - event["occurredAt"]) < 60
                                    for stamp in fred_cpi_timestamps(evidence, document.text)):
                    return True
        if any(abs(stamp - event["occurredAt"]) < 60 for stamp in occurrence_timestamps(evidence, planned=event["status"] == "scheduled")):
            return True
    return False


def verified_day(event, timezone):
    from dateutil import parser

    # A day must be present in occurrence prose, or in the official calendar.
    # Scheduled status requires calendar/schedule language in addition to a date.
    expected_dates = {dt.datetime.fromtimestamp(event["occurredAt"], zone).date()
                      for zone in (UTC, ZoneInfo(timezone), ZoneInfo("America/New_York"))}
    for source in event["sources"]:
        evidence = normalize(source["evidence"])
        official = source_is_primary_calendar(source["url"])
        scheduled = event["status"] == "scheduled"
        if scheduled:
            calendar_path = re.search(r"schedule|calendar|\.ics", urllib.parse.urlsplit(source["url"]).path, re.I)
            if not official or not (calendar_path or re.search(r"schedule|calendar|release|meeting|DTSTART", evidence, re.I)):
                continue
            stamp = calendar_timestamp(evidence)
            if stamp is not None and dt.datetime.fromtimestamp(stamp, ZoneInfo("America/New_York")).date() in expected_dates:
                return True
        elif PUBLISHING.search(evidence) or RETROSPECTIVE.search(evidence) or not OCCURRENCE.search(evidence):
            continue
        elif FUTURE_INTENT.search(evidence):
            # An advance plan cannot prove that the event later happened.
            continue
        dates = NATURAL_DATE.findall(evidence) + DATE_ISO.findall(evidence)
        if not scheduled and len(dates) != 1:
            continue
        for value in dates:
            try:
                if parser.parse(value).date() in expected_dates:
                    return True
            except (ValueError, OverflowError):
                pass
        if scheduled:
            # Fed calendars render '2026 FOMC Meetings ... September 15-16*'.
            # Bind the month/day to its nearest preceding year heading.
            for date in expected_dates:
                pattern = rf"\b{date.strftime('%B')}\s+(\d{{1,2}})(?:\s*[-–]\s*(\d{{1,2}}))?\b"
                for match in re.finditer(pattern, evidence, re.I):
                    years = re.findall(r"\b20\d{2}\b", evidence[:match.start()])
                    days = {int(x) for x in match.groups() if x}
                    if years and int(years[-1]) == date.year and date.day in days:
                        return True
    return False


def event_id(event):
    # Anchor to source and occurrence minute. Model-generated wording never changes identity.
    anchor = min(canonical_url(source["url"]) for source in event["sources"])
    key = f"{anchor}|{int(event['occurredAt'] // 60)}|{event['category']}"
    if event["status"] == "scheduled":
        # Shared macro calendars routinely contain simultaneous releases (e.g.
        # CPI and real earnings); preserve the publisher's event identifier.
        identities = []
        for source in event["sources"]:
            match = (re.search(r"(?:^|\n)UID:([^\r\n]+)", source["evidence"])
                     or re.search(r"(?:^|\n)SUMMARY:([^\r\n]+)", source["evidence"]))
            if match:
                identities.append(normalize(match.group(1)))
        parsed_anchor = urllib.parse.urlsplit(anchor)
        fred_release = urllib.parse.parse_qs(parsed_anchor.query).get("rid") if parsed_anchor.hostname == "fred.stlouisfed.org" else None
        key += "|" + (min(identities) if identities else
                      "fred-release-" + fred_release[0] if fred_release else normalized_title(event["title"]))
    return "evt_" + hashlib.sha256(key.encode()).hexdigest()[:24]


def normalized_title(title):
    return re.sub(r"[^a-z0-9\u4e00-\u9fff]", "", title.casefold())


def is_known(event, known):
    for previous in known:
        if not isinstance(previous, dict):
            continue
        if event["id"] == previous.get("id"):
            return True
        stamp = previous.get("occurredAt")
        if finite(stamp) and abs(event["occurredAt"] - stamp) <= 300:
            similarity = difflib.SequenceMatcher(None, normalized_title(event["title"]),
                                                 normalized_title(str(previous.get("title", "")))).ratio()
            if similarity >= 0.78:
                return True
    return False


def verified_sources(sources, research, subject):
    """Bind every citation to a document actually read by this run's host."""
    for source in sources:
        key = canonical_url(source["url"])
        current = research.documents.get(key)
        versions = ([current] if current else []) + list(getattr(research, "document_history", {}).get(key, []))
        if not versions:
            raise ResearchError(f"SOURCE_UNFETCHED: {subject} cites a URL that was not read this run")
        evidence = normalize(source["evidence"])
        document = next((d for d in versions if evidence in normalize(d.text)), None)
        if not 30 <= len(evidence) <= 2000 or not document:
            raise ResearchError(f"SOURCE_EVIDENCE: {subject} evidence is not an exact fetched-source excerpt")
        key = canonical_url(document.url)
        if urllib.parse.urlsplit(key).hostname in DISCOVERY_HOSTS:
            raise ResearchError("SOURCE_DISCOVERY_ONLY: search feeds do not establish evidence")
        source.update(url=key, retrievedAt=document.retrieved_at)


def validated_findings(findings, request, research, report_id):
    aliases, seen, retained, rejected = {}, set(), [], 0
    watchlist = set(request["watchlist"])
    for finding in findings:
        local_id = finding["id"].strip()
        if not local_id or local_id in seen:
            raise ResearchError("FINDING_ID: analysis identifiers must be nonempty and unique")
        if not finding["title"].strip() or not finding["body"].strip():
            raise ResearchError("FINDING_CONTENT: analysis title and body must be nonempty")
        if len(set(finding["instIds"])) != len(finding["instIds"]) or not set(finding["instIds"]) <= watchlist:
            raise ResearchError("FINDING_INSTRUMENT: analysis must reference unique watchlist instruments")
        seen.add(local_id)
        try:
            if finding["kind"] != "unknown" and not finding["sources"]:
                raise ResearchError("FINDING_SOURCE: observations and inferences require fetched evidence")
            verified_sources(finding["sources"], research, "analysis")
        except ResearchError as exc:
            if not str(exc).startswith(("SOURCE_", "FINDING_SOURCE:")):
                raise
            # Isolate one bad conclusion, never keep its claim after stripping
            # the citation. Other independently verified research remains useful.
            rejected += 1
            continue
        except ValueError:
            # A malformed model-supplied URL can fail urllib parsing directly.
            rejected += 1
            continue
        host_id = "finding_" + hashlib.sha256(f"{report_id}|{local_id}".encode()).hexdigest()[:24]
        aliases[finding["id"]] = host_id
        finding["id"] = host_id
        retained.append(finding)
    return retained, aliases, rejected


def insufficient(inst, request, reason, reference_price=None, completed_at=None):
    return {"instId": inst, "direction": "insufficient", "confidence": "low",
            "horizonHours": request["horizonHours"], "generatedAt": request["now"] if completed_at is None else completed_at,
            "referencePrice": reference_price, "drivers": [reason],
            "invalidation": "取得可核验市场依据后重新评估。" if reference_price is not None else "取得新鲜报价及可核验市场依据后重新评估。",
            "eventIds": [], "findingIds": []}


def validate_report(report: dict, request: dict, research: Research, completed_at=None) -> dict:
    from jsonschema import Draft202012Validator

    report = copy.deepcopy(report)
    if isinstance(report, dict):
        # Provenance belongs to the host's selected request, even if a model
        # attempts to supply its own name or an invalid metadata value.
        report["model"] = normalize_model(request.get("model", DEFAULT_MODEL))
    errors = list(Draft202012Validator(REPORT_SCHEMA).iter_errors(report))
    if errors:
        raise ResearchError("REPORT_SCHEMA: model output does not match the intelligence contract")
    completed_at = request["now"] if completed_at is None else completed_at
    if not finite(completed_at) or completed_at < request["now"]:
        raise ResearchError("REPORT_TIME: completion must be a finite timestamp at or after request time")
    report_id = "rpt_" + hashlib.sha256(f"{request['kind']}|{request['now']}".encode()).hexdigest()[:24]
    findings, finding_aliases, rejected_findings = validated_findings(report.get("analysis", []), request, research, report_id)
    if not research.searches:
        raise ResearchError("RESEARCH_INCOMPLETE: no news searches were completed")
    missing_topics = [q for q in SEARCH_TOPICS.values() if q not in research.searches]
    market_urls = set(getattr(research, "market_document_urls", set()))
    market_failures = getattr(research, "market_failures", [])
    has_news_leads = any(research.searches.values())
    publisher_docs = [doc for doc in research.documents.values()
                      if canonical_url(doc.url) not in research.calendar_document_urls
                      and canonical_url(doc.url) not in market_urls
                      and urllib.parse.urlsplit(doc.url).hostname not in DISCOVERY_HOSTS]
    unread_news = has_news_leads and not publisher_docs
    sourced_analysis = any(f["kind"] != "unknown" and f["sources"] for f in findings)
    if unread_news and (request["kind"] == "flash" or not sourced_analysis):
        raise ResearchError("RESEARCH_UNVERIFIED: news leads were found but no original publisher was read; this is not a no-news result")
    coverage_complete = not (getattr(research, "review_failed", False) or rejected_findings or research.failures or missing_topics or unread_news or market_failures
                             or research.failed_fetches or research.failed_searches or research.calendar_failures)
    start, end = window(request)
    eligible_start = start
    if request["kind"] != "daily":
        eligible_start = max(start, completed_at - (1800 if request["kind"] == "flash" else 3600))
    events, aliases, seen = [], {}, set()
    rejected_precision = 0
    for event in report["events"]:
        if not finite(event["occurredAt"]):
            raise ResearchError("EVENT_TIME: invalid occurrence timestamp")
        verified_sources(event["sources"], research, "event")
        precise = event["timePrecision"] == "minute" and verified_minute(event, research)
        if event["timePrecision"] == "minute" and not precise:
            event["timePrecision"] = "unknown"
            event["status"] = "unverified"
            rejected_precision += 1
        elif event["timePrecision"] == "day" and not verified_day(event, request["timezone"]):
            event["timePrecision"] = "unknown"
            event["status"] = "unverified"
        elif event["timePrecision"] == "unknown":
            event["status"] = "unverified"
        if event["status"] == "occurred" and event["occurredAt"] > request["now"]:
            raise ResearchError("EVENT_FUTURE: an occurred event cannot be in the future")
        if request["kind"] != "daily":
            if not precise or event["status"] != "occurred" or not eligible_start < event["occurredAt"] <= end:
                continue
        elif not start <= event["occurredAt"] < end:
            continue
        old_id = event["id"]
        event["id"] = event_id(event)
        aliases[old_id] = event["id"]
        if event["id"] in seen or (request["kind"] == "flash" and is_known(event, request["knownEvents"])):
            continue
        seen.add(event["id"])
        events.append(event)
    event_ids = {e["id"] for e in events if e["status"] != "unverified"}
    finding_by_id = {f["id"]: f for f in findings}
    input_predictions = {p["instId"]: p for p in report["predictions"]}
    # Input quotes were observed before request time; tool quotes may be newer.
    # In either case a slow research run must not extend their actual freshness.
    quotes = {}
    quote_candidates = [(q, request["now"]) for q in request["quotes"] if isinstance(q, dict)]
    market_quotes = getattr(research, "market_quotes", {})
    quote_candidates.extend(({**q, "instId": inst}, completed_at) for inst, q in market_quotes.items()
                            if isinstance(q, dict) and q.get("instId", inst) == inst
                            and inst in request["watchlist"])
    for quote, observed_at in quote_candidates:
        price, as_of, inst = quote.get("price"), quote.get("asOf"), quote.get("instId")
        if (not finite(price) or price <= 0 or not finite(as_of) or as_of > observed_at
                or not 0 <= completed_at - as_of <= MAX_QUOTE_AGE):
            continue
        if inst not in quotes or as_of > quotes[inst]["asOf"]:
            quotes[inst] = quote
    predictions = []
    for inst in request["watchlist"]:
        quote = quotes.get(inst, {})
        price = quote.get("price")
        if price is None:
            predictions.append(insufficient(inst, request, "截至报告完成时缺少最近5分钟内的有效报价，无法给出有依据的方向判断。", completed_at=completed_at))
            continue
        prediction = input_predictions.get(inst)
        if not prediction:
            predictions.append(insufficient(inst, request, "模型未给出该标的的证据支持判断。", price, completed_at))
            continue
        referenced = list(dict.fromkeys(aliases.get(e, e) for e in prediction["eventIds"]))
        finding_refs = list(dict.fromkeys(finding_aliases.get(f, f) for f in prediction.get("findingIds", [])))
        supported_findings = {fid for fid, finding in finding_by_id.items()
                              if finding["kind"] != "unknown" and inst in finding["instIds"]}
        invalid_references = not set(referenced) <= event_ids or not set(finding_refs) <= supported_findings
        if invalid_references or (prediction["direction"] != "insufficient" and (
                not (referenced or finding_refs)
                or not prediction["drivers"] or not all(d.strip() for d in prediction["drivers"])
                or not prediction["invalidation"].strip())):
            prediction = insufficient(inst, request, "方向判断缺少适用于该标的的已核验事件或研究依据、驱动因素或失效条件。", price, completed_at)
        else:
            prediction["eventIds"] = [e for e in referenced if e in event_ids]
            prediction["findingIds"] = [f for f in finding_refs if f in supported_findings]
        prediction["referencePrice"] = price
        prediction["horizonHours"] = request["horizonHours"]
        prediction["generatedAt"] = completed_at
        predictions.append(prediction)
    report.update({"id": report_id,
                   "kind": request["kind"], "generatedAt": completed_at,
                   "windowStart": start, "windowEnd": end, "events": sorted(events, key=lambda e: e["occurredAt"]),
                   "analysis": findings, "predictions": predictions, "coverageComplete": coverage_complete})
    verified = len({id(d) for d in research.documents.values()})
    market_count = len({canonical_url(d.url) for d in research.documents.values()
                        if canonical_url(d.url) in market_urls})
    if rejected_findings:
        # The model's free-form lead/coverage could repeat a rejected claim.
        # Rebuild the lead solely from retained, explicitly typed conclusions.
        report["coverage"] = f"{rejected_findings} 条分析未通过来源校验，已整条移除；仅保留独立通过校验的内容。"
        if not sourced_analysis and not events:
            report["title"] = "研究证据未通过校验"
            report["summary"] = "本轮分析的事实与推断未保留可核验依据，无法据此形成方向判断；这不代表市场没有新事件。"
        else:
            labels = {"observation": "观察", "inference": "推断", "unknown": "待核实"}
            report["title"] = "市场研究 · 部分结论未通过核验"
            report["summary"] = "部分分析的来源证据未通过校验，已移除。保留内容：" + "；".join(
                f"{labels[f['kind']]}：{f['title']}" for f in findings)
            if not findings:
                report["summary"] = "分析结论的来源证据未通过校验，已移除；通过校验的事件保留在日历中。"
    report["coverage"] = (f"完成 {len(research.searches)} 次新闻搜索；读取 {verified} 个来源"
                          f"（含 {market_count} 个市场数据来源），核验 {len(findings)} 条研究结论。" + report["coverage"])
    report["coverage"] += " ".join(research.coverage_notes)
    if missing_topics or research.failures:
        report["coverage"] += f" 基础新闻覆盖存在缺口：{len(missing_topics)} 个主题未完成；未据此推断这些领域没有新事件。"
    if unread_news:
        report["coverage"] += " 新闻线索的原始正文尚未读到；当前保留的是有来源的市场研究，不能据此判断全面无新闻。"
    if market_failures:
        report["coverage"] += f" {len(market_failures)} 次市场数据请求未完成；未将缺失数据解释为零变动或零成交。"
    if research.calendar_failures:
        report["coverage"] += " 日历覆盖不完整：" + "、".join(research.calendar_failures) + "官方来源本轮读取失败；未推算缺失日程。"
    if research.failed_fetches or research.failed_searches:
        report["coverage"] += (f" 部分研究未完成：{len(research.failed_fetches)} 个页面、"
                               f"{len(research.failed_searches)} 次额外搜索读取失败；仅展示成功核验的事件与研究依据。")
    if rejected_precision:
        report["coverage"] += f" {rejected_precision} 条事件未通过发生时间核验；不作为小时更新或快报。"
    if not coverage_complete:
        report["coverage"] = "覆盖不完整：部分来源或补充搜索未完成，本报告仅代表已成功读取的来源。 " + report["coverage"]
    if not rejected_findings and not events and (request["kind"] == "flash" or not findings):
        period = {"flash": "最近30分钟", "hourly": "最近60分钟", "daily": "本次日历窗口"}[request["kind"]]
        report["title"] = "已读取来源未核验到新事件"
        report["summary"] = f"仅在本轮已完成检索和成功读取的来源范围内，未核验到符合{period}发生时间与去重条件的新事件。"
        if not coverage_complete:
            report["title"] = "部分覆盖：已读取来源未核验到新事件"
            report["summary"] = "覆盖不完整。" + report["summary"] + "尚未完成的来源无法判断，不能据此断言全面无新闻。"
    return report
