"""Assemble source-backed economic calendar entries without asking the model.

Only the official calendars already present in the per-run provenance ledger are
read. The caller must still pass the combined report through validate_report.
Day-only dates are civil calendar labels in the requested display timezone, not
claims about the UTC time at which a meeting will begin or a decision will occur.
"""
from __future__ import annotations

import datetime as dt
import re
import urllib.parse
from zoneinfo import ZoneInfo

if __package__:
    from .research import CALENDARS, Document, Research, canonical_url
    from .validation import calendar_timestamp, event_id, fred_cpi_timestamps, window
else:
    from research import CALENDARS, Document, Research, canonical_url
    from validation import calendar_timestamp, event_id, fred_cpi_timestamps, window

MAX_EVIDENCE = 2000
MONTHS = {dt.date(2000, month, 1).strftime("%B"): month for month in range(1, 13)}


def _event(document: Document, title: str, stamp: float, evidence: str,
           *, precision="minute", summary="", importance="high") -> dict:
    value = {"id": "calendar", "title": title, "category": "macro", "importance": importance,
             "status": "scheduled", "occurredAt": stamp, "timePrecision": precision,
             "publishedAt": None,
             "summary": summary or "官方发布日历中的预定事项；排期不代表已经公布。",
             "impact": "关注实际结果相对市场预期的差异，以及利率、美元和风险偏好的反应。",
             "sources": [{"title": "官方经济日历", "url": document.url,
                          "publisher": urllib.parse.urlsplit(document.url).hostname or "",
                          "retrievedAt": document.retrieved_at, "evidence": evidence}]}
    value["id"] = event_id(value)
    return value


def _ics_field(block: str, name: str) -> str | None:
    # RFC 5545 folded content lines: unfold only for parsing; evidence stays raw.
    unfolded = re.sub(r"\r?\n[ \t]", "", block)
    match = re.search(rf"(?:^|\n){name}(?:;[^:\r\n]*)?:([^\r\n]*)", unfolded, re.I)
    if not match:
        return None
    return (match.group(1).replace(r"\n", " ").replace(r"\N", " ")
            .replace(r"\,", ",").replace(r"\;", ";").replace(r"\\", "\\"))


def _ics_evidence(block: str) -> str | None:
    if len(block) <= MAX_EVIDENCE:
        return block
    # A long description need not obscure a short, contiguous title/date/UID
    # excerpt. Never splice fields or blindly cut off the occurrence evidence.
    fields = []
    for name in ("SUMMARY", "DTSTART", "UID"):
        match = re.search(rf"(?:^|\n){name}(?:;[^:\r\n]*)?:[^\r\n]*(?:\r?\n[ \t][^\r\n]*)*",
                          block, re.I)
        if name != "UID" and match is None:
            return None
        if match:
            fields.append(match)
    excerpt = block[min(m.start() for m in fields):max(m.end() for m in fields)].strip()
    return excerpt if 30 <= len(excerpt) <= MAX_EVIDENCE else None


def _ics_title(original: str) -> tuple[str, str]:
    aliases = [
        (r"Personal Income and Outlays", "美国个人收入与支出（含 PCE）"),
        (r"Gross Domestic Product|\bGDP\b", "美国 GDP 数据发布"),
        (r"International Trade", "美国国际贸易数据发布"),
        (r"International Transactions|Investment Position", "美国国际收支与投资头寸"),
        (r"Consumer Price Index", "美国 CPI 发布"),
        (r"Producer Price Index", "美国 PPI 发布"),
        (r"Employment Situation", "美国非农就业报告"),
        (r"Job Openings", "美国职位空缺与劳动力流动报告"),
        (r"Real Earnings", "美国实际收入数据发布"),
    ]
    for pattern, title in aliases:
        if re.search(pattern, original, re.I):
            return title, "high"
    return original, "medium"


def _ics_events(document: Document, start: float, end: float, timezone: str):
    for match in re.finditer(r"(?m)^BEGIN:VEVENT\s*\r?\n.*?^END:VEVENT[^\S\r\n]*", document.text, re.S):
        block = match.group(0)
        if (_ics_field(block, "STATUS") or "").strip().upper() == "CANCELLED":
            continue
        original = _ics_field(block, "SUMMARY")
        raw_start = _ics_field(block, "DTSTART")
        evidence = _ics_evidence(block)
        stamp = calendar_timestamp(block)
        if not original or not raw_start or evidence is None or stamp is None:
            continue
        precision = "minute"
        if re.fullmatch(r"\d{8}", raw_start):
            day = dt.datetime.strptime(raw_start, "%Y%m%d").date()
            stamp = dt.datetime.combine(day, dt.time(), ZoneInfo(timezone)).timestamp()
            precision = "day"
        if not start <= stamp < end:
            continue
        title, importance = _ics_title(original)
        note = f"排期项目：{original}。官方发布日历中的预定事项；排期不代表已经公布。"
        if precision == "day":
            note += " 来源日历日期，具体时刻未核实；美国经济日历采用美国东部时间。"
        yield _event(document, title, stamp, evidence, precision=precision,
                     summary=note, importance=importance)


def _fred_events(document: Document, start: float, end: float):
    pattern = (r"(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)\s+"
               r"[A-Za-z]+\s+\d{1,2},\s+\d{4}(?:\s+Updated)?\s*\|\s*"
               r"\d{1,2}:\d{2}\s*[ap]m\s*\|\s*Consumer Price Index(?:\s*\|)?")
    for match in re.finditer(pattern, document.text, re.I):
        evidence = match.group(0)
        try:
            stamps = fred_cpi_timestamps(evidence, document.text)
        except (ValueError, OverflowError):
            continue
        if len(stamps) == 1 and start <= stamps[0] < end:
            yield _event(document, "美国 CPI 发布（FRED 转引 BLS）", stamps[0], evidence,
                         summary="FRED 转引的 BLS 发布排期；来源时区为美国中部时间，已换算为显示时区。排期不代表已经公布。")


def _fed_events(document: Document, start: float, end: float, timezone: str):
    zone = ZoneInfo(timezone)
    first_year = dt.datetime.fromtimestamp(start, zone).year
    last_year = dt.datetime.fromtimestamp(end - 1, zone).year
    headings = list(re.finditer(r"\b(20\d{2})\s+FOMC\s+Meetings\b", document.text, re.I))
    month_pattern = (r"(?m)^(" + "|".join(MONTHS) + r")[ \t]*(?:\r?\n|[ \t]+)"
                     r"(\d{1,2})(?:\s*[-–]\s*(\d{1,2}))?[ \t]*\*?"
                     r"(?:[ \t]*\([^\r\n]*\))?[ \t]*$")
    for index, heading in enumerate(headings):
        year = int(heading.group(1))
        if not first_year <= year <= last_year:
            continue
        section_end = headings[index + 1].start() if index + 1 < len(headings) else len(document.text)
        section = document.text[heading.start():section_end]
        for match in re.finditer(month_pattern, section, re.I):
            month = MONTHS[match.group(1).title()]
            first, last = int(match.group(2)), int(match.group(3) or match.group(2))
            if first > last or last - first > 6:
                continue
            evidence = section[:match.end()]
            if not 30 <= len(evidence) <= MAX_EVIDENCE:
                continue
            for day in range(first, last + 1):
                try:
                    stamp = dt.datetime(year, month, day, tzinfo=zone).timestamp()
                except ValueError:
                    continue
                if not start <= stamp < end:
                    continue
                phase = ("会议日" if first == last else "首日" if day == first
                         else "末日" if day == last else f"第 {day - first + 1} 日")
                yield _event(document, f"FOMC 会议（{phase}）", stamp, evidence, precision="day",
                             summary="来源日历日期，具体时刻未核实；按原始日期显示全天事项。来源为美国联储日历（美国东部时区），未推定声明或利率决议的发布时间；排期不代表会议已经举行。")


def assemble_calendar_events(request: dict, research: Research) -> list[dict]:
    """Return daily-window Event dictionaries with exact fetched-source evidence.

    This performs no I/O and never inserts planned entries into rolling news.
    Missing or unparsable sources yield no invented replacement entries.
    """
    if request.get("kind") != "daily":
        return []
    start, end = window(request)
    official = {canonical_url(url): name for name, url in CALENDARS.items()}
    events = []
    documents = {id(document): document for document in research.documents.values()}.values()
    for document in documents:
        url = canonical_url(document.url)
        name = official.get(url)
        parts = urllib.parse.urlsplit(url)
        query = urllib.parse.parse_qs(parts.query)
        if name in {"BLS", "BEA"}:
            events.extend(_ics_events(document, start, end, request["timezone"]))
        elif name == "Federal Reserve":
            events.extend(_fed_events(document, start, end, request["timezone"]))
        elif (parts.hostname == "fred.stlouisfed.org" and parts.path == "/releases/calendar"
              and query.get("rid") == ["10"]):
            events.extend(_fred_events(document, start, end))
    unique = {event["id"]: event for event in events}
    return sorted(unique.values(), key=lambda event: (event["occurredAt"], event["title"]))
