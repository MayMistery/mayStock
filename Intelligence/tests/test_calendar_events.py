"""Calendar provenance and civil-date regressions; all fixtures are offline."""
import datetime as dt
from pathlib import Path
import sys
import unittest
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from calendar_events import assemble_calendar_events
from research import CALENDARS, Document, Research, SEARCH_TOPICS, canonical_url, normalize
from validation import validate_report, window


BEA = CALENDARS["BEA"]
FED = CALENDARS["Federal Reserve"]
FRED = "https://fred.stlouisfed.org/releases/calendar?rid=10&y=2026"
NOW = dt.datetime(2026, 9, 8, 4, tzinfo=dt.timezone.utc).timestamp()


def request(timezone="Asia/Taipei", now=NOW):
    return {"kind": "daily", "now": now, "timezone": timezone, "horizonHours": 1,
            "watchlist": [], "quotes": [], "knownEvents": []}


def ics_event(uid, summary, stamp="20260930T123000Z", extra=""):
    return (f"BEGIN:VEVENT\nSUMMARY:{summary}\nDTSTART;VALUE=DATE-TIME:{stamp}\n"
            f"UID:{uid}\n{extra}END:VEVENT")


def ics(*events):
    return "BEGIN:VCALENDAR\nVERSION:2.0\n" + "\n".join(events) + "\nEND:VCALENDAR"


def research(*sources):
    value = Research()
    value.searches = {query: [] for query in SEARCH_TOPICS.values()}
    for url, text in sources:
        value.documents[canonical_url(url)] = Document(canonical_url(url), text, NOW - 20)
        value.calendar_document_urls.add(canonical_url(url))
    return value


def validated_events(req, store):
    events = assemble_calendar_events(req, store)
    start, end = window(req)
    report = {"id": "calendar-test", "kind": "daily", "generatedAt": req["now"],
              "windowStart": start, "windowEnd": end, "title": "日历", "summary": "",
              "coverage": "", "events": events, "predictions": []}
    return validate_report(report, req, store)["events"]


class OfficialCalendarAssemblyTests(unittest.TestCase):
    def test_simultaneous_gdp_and_pce_keep_distinct_publisher_ids(self):
        store = research((BEA, ics(ics_event("gdp-1", "Gross Domestic Product, Third Estimate"),
                                   ics_event("pce-1", "Personal Income and Outlays, August 2026"))))
        events = validated_events(request(), store)
        self.assertEqual(len(events), 2)
        self.assertEqual(len({event["id"] for event in events}), 2)
        self.assertTrue(all(event["status"] == "scheduled" for event in events))
        self.assertTrue(all(event["timePrecision"] == "minute" for event in events))
        self.assertEqual(events[0]["occurredAt"], dt.datetime(2026, 9, 30, 12, 30, tzinfo=dt.timezone.utc).timestamp())

    def test_folded_summary_is_readable_but_source_excerpt_stays_original(self):
        block = ics_event("folded-id", "Gross Domestic Product, Third Quarter (Advance Estima\n te)")
        store = research((BEA, ics(block)))
        event = validated_events(request(), store)[0]
        self.assertIn("Advance Estimate", event["summary"])
        self.assertIn("Estima\n te", event["sources"][0]["evidence"])
        self.assertEqual(event["sources"][0]["retrievedAt"], NOW - 20)

    def test_summary_rewording_or_translation_does_not_replace_stable_uid(self):
        first = assemble_calendar_events(request(), research((BEA, ics(ics_event("stable", "Series original title")))))[0]
        second = assemble_calendar_events(request(), research((BEA, ics(ics_event("stable", "Series updated wording")))))[0]
        self.assertEqual(first["id"], second["id"])

    def test_past_scheduled_release_is_not_asserted_to_have_occurred(self):
        store = research((BEA, ics(ics_event("past", "International Trade", "20260903T123000Z"))))
        event = validated_events(request(), store)[0]
        self.assertLess(event["occurredAt"], NOW)
        self.assertEqual(event["status"], "scheduled")
        self.assertIn("不代表已经公布", event["summary"])

    def test_cancelled_and_out_of_window_events_are_omitted(self):
        store = research((BEA, ics(ics_event("cancel", "GDP", extra="STATUS:CANCELLED\n"),
                                   ics_event("old", "GDP", "20260831T123000Z"),
                                   ics_event("late", "GDP", "20261009T123000Z"))))
        self.assertEqual(assemble_calendar_events(request(), store), [])

    def test_more_than_ten_eligible_releases_are_retained(self):
        blocks = [ics_event(f"series-{day}", f"Official series {day}", f"202609{day:02d}T123000Z")
                  for day in range(9, 23)]
        events = validated_events(request(), research((BEA, ics(*blocks))))
        self.assertEqual(len(events), 14)

    def test_oversized_description_uses_contiguous_complete_evidence_fields(self):
        block = ics_event("long", "GDP", extra="DESCRIPTION:" + "x" * 3000 + "\n")
        store = research((BEA, ics(block)))
        event = validated_events(request(), store)[0]
        evidence = event["sources"][0]["evidence"]
        self.assertLessEqual(len(evidence), 2000)
        self.assertIn(evidence, store.documents[canonical_url(BEA)].text)
        self.assertIn("UID:long", evidence)
        self.assertIn("DTSTART", evidence)

    def test_unbounded_gap_between_evidence_fields_is_not_spliced(self):
        block = ("BEGIN:VEVENT\nSUMMARY:GDP\nDESCRIPTION:" + "x" * 2500
                 + "\nDTSTART:20260930T123000Z\nUID:long-gap\nEND:VEVENT")
        self.assertEqual(assemble_calendar_events(request(), research((BEA, ics(block)))), [])

    def test_ics_all_day_is_source_date_in_requested_timezone_and_validates(self):
        block = "BEGIN:VEVENT\nSUMMARY:Economic data release\nDTSTART;VALUE=DATE:20260930\nUID:day-only\nEND:VEVENT"
        for timezone in ("Asia/Taipei", "Pacific/Honolulu"):
            event = validated_events(request(timezone), research((BEA, ics(block))))[0]
            local = dt.datetime.fromtimestamp(event["occurredAt"], ZoneInfo(timezone))
            self.assertEqual((local.month, local.day, local.hour), (9, 30, 0))
            self.assertEqual((event["status"], event["timePrecision"]), ("scheduled", "day"))
            self.assertIn("具体时刻未核实", event["summary"])

    def test_fred_cpi_uses_documented_central_timezone_not_eastern(self):
        text = "Release Calendar\nFriday September 11, 2026 |\n7:30 am |\nConsumer Price Index\n|\nAll times are US Central Time."
        store = research((FRED, text))
        event = validated_events(request(), store)[0]
        self.assertEqual(event["occurredAt"], dt.datetime(2026, 9, 11, 12, 30, tzinfo=dt.timezone.utc).timestamp())
        self.assertIn("美国中部时间", event["summary"])
        self.assertNotIn("美国东部时间", event["summary"])
        self.assertIn(normalize(event["sources"][0]["evidence"]), normalize(text))

    def test_fred_without_explicit_timezone_never_guesses_a_timestamp(self):
        text = "Release Calendar\nFriday September 11, 2026 | 7:30 am | Consumer Price Index |"
        self.assertEqual(assemble_calendar_events(request(), research((FRED, text))), [])

    def test_fomc_range_has_two_civil_days_without_inventing_decision_time(self):
        text = "2026 FOMC Meetings\nJanuary\n27-28\nSeptember\n15-16*\n2025 FOMC Meetings\nSeptember\n16-17*"
        for timezone in ("Asia/Taipei", "Pacific/Honolulu"):
            events = validated_events(request(timezone), research((FED, text)))
            local = [dt.datetime.fromtimestamp(event["occurredAt"], ZoneInfo(timezone)) for event in events]
            self.assertEqual([(day.month, day.day, day.hour) for day in local], [(9, 15, 0), (9, 16, 0)])
            self.assertTrue(all((event["status"], event["timePrecision"]) == ("scheduled", "day") for event in events))
            self.assertTrue(all("来源日历日期，具体时刻未核实" in event["summary"] for event in events))
            self.assertTrue(all("未推定" in event["summary"] for event in events))

    def test_fomc_can_include_next_year_when_38_day_window_crosses_year_end(self):
        now = dt.datetime(2026, 12, 20, 4, tzinfo=dt.timezone.utc).timestamp()
        text = "2026 FOMC Meetings\nDecember\n15-16\n2027 FOMC Meetings\nJanuary\n12-13"
        events = validated_events(request(now=now), research((FED, text)))
        self.assertEqual(len(events), 4)
        self.assertEqual({dt.datetime.fromtimestamp(event["occurredAt"], ZoneInfo("Asia/Taipei")).year for event in events}, {2026, 2027})

    def test_alias_ledger_keys_do_not_duplicate_calendar_entries(self):
        store = research((BEA, ics(ics_event("alias", "GDP"))))
        store.documents["https://www.bea.gov/old-calendar-link"] = next(iter(store.documents.values()))
        self.assertEqual(len(assemble_calendar_events(request(), store)), 1)

    def test_arbitrary_calendar_host_or_fred_series_is_not_treated_as_official_cpi(self):
        store = research(("https://example.org/calendar.ics", ics(ics_event("untrusted", "GDP"))),
                         ("https://fred.stlouisfed.org/releases/calendar?rid=315&y=2026",
                          "Friday September 11, 2026 | 7:30 am | Consumer Price Index | All times are US Central Time."))
        self.assertEqual(assemble_calendar_events(request(), store), [])

    def test_hourly_and_flash_never_receive_planned_calendar_entries(self):
        for kind in ("hourly", "flash"):
            req = request()
            req["kind"] = kind
            self.assertEqual(assemble_calendar_events(req, research((BEA, ics(ics_event("future", "GDP"))))), [])


if __name__ == "__main__":
    unittest.main()
