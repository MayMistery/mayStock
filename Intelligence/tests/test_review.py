"""A second reading can revise interpretation without changing its evidence."""
import copy
import json
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from research import ResearchError
from review import apply_review, audit_report, REVIEW_SCHEMA
from runner import make_report
from test_analysis import NOW, report, request, research
from validation import validate_report


def review():
    return {"title": "Observed selling, uncertain cause", "summary": "The observations permit several explanations.",
            "corrections": [{"findingId": "positioning", "title": "Positioning does not prove new shorts",
                             "replacements": [{"before": "is consistent with fresh short exposure",
                                               "after": "does not establish trader intent on its own"}],
                             "kind": "inference"}],
            "predictionCorrections": [{"instId": "BTC-USDT", "direction": "neutral", "confidence": "low",
                                       "drivers": ["Price and positioning alone do not establish continuation"],
                                       "invalidation": "A confirmed break below the observed low"}]}


class ReviewContractTests(unittest.TestCase):
    def test_review_preserves_evidence_identity_time_window_and_forecast_reference(self):
        original = report()
        original["events"] = [{"id": "event-sentinel", "sources": [{"url": "https://example.org/event"}]}]
        original.update(generatedAt=NOW, windowStart=NOW - 3600, windowEnd=NOW)
        original["predictions"][0].update(referencePrice=78440, generatedAt=NOW, horizonHours=1)
        revised = apply_review(original, review())
        for field in ("id", "kind", "generatedAt", "windowStart", "windowEnd", "events", "coverage"):
            self.assertEqual(revised[field], original[field], field)
        for field in ("id", "sources", "instIds"):
            self.assertEqual(revised["analysis"][0][field], original["analysis"][0][field], field)
        for field in ("instId", "generatedAt", "referencePrice", "horizonHours", "eventIds", "findingIds"):
            self.assertEqual(revised["predictions"][0][field], original["predictions"][0][field], field)
        replacement = review()["corrections"][0]["replacements"][0]
        self.assertEqual(revised["analysis"][0]["body"], original["analysis"][0]["body"].replace(
            replacement["before"], replacement["after"], 1))
        self.assertEqual(revised["predictions"][0]["direction"], "neutral")

    def test_caller_draft_is_not_mutated_or_aliased(self):
        original = report()
        before = copy.deepcopy(original)
        revised = apply_review(original, review())
        self.assertEqual(original, before)
        revised["analysis"][0]["sources"][0]["evidence"] = "Changed returned source"
        revised["predictions"][0]["eventIds"].append("changed")
        self.assertEqual(original, before)

    def test_corrections_must_target_existing_unique_ids(self):
        for field, identifier in (("corrections", "findingId"), ("predictionCorrections", "instId")):
            for mode in ("unknown", "duplicate"):
                with self.subTest(field=field, mode=mode):
                    value = review()
                    if mode == "unknown":
                        value[field][0][identifier] = "not-in-draft"
                    else:
                        value[field].append(copy.deepcopy(value[field][0]))
                    with self.assertRaisesRegex(ResearchError, "REVIEW_REFERENCE"):
                        apply_review(report(), value)

    def test_bad_shapes_and_attempted_evidence_or_price_changes_are_rejected(self):
        variants = []
        missing = review()
        del missing["summary"]
        variants.append(missing)
        extra = review()
        extra["sources"] = []
        variants.append(extra)
        for field in ("sources", "id", "instIds", "body"):
            value = review()
            value["corrections"][0][field] = "attempted mutation"
            variants.append(value)
        for field in ("referencePrice", "horizonHours", "generatedAt", "findingIds"):
            value = review()
            value["predictionCorrections"][0][field] = 999
            variants.append(value)
        wrong_kind = review()
        wrong_kind["corrections"][0]["kind"] = "verified-cause"
        variants.append(wrong_kind)
        nested_extra = review()
        nested_extra["corrections"][0]["replacements"][0]["sources"] = []
        variants.append(nested_extra)
        for value in variants:
            with self.subTest(value=value), self.assertRaisesRegex(ResearchError, "REVIEW_SCHEMA"):
                apply_review(report(), value)

    def test_review_cannot_blank_lead_or_analysis(self):
        for field in ("title", "summary", "finding_title", "finding_body"):
            value = review()
            if field == "finding_body":
                value["corrections"][0]["replacements"] = [{"before": report()["analysis"][0]["body"], "after": " "}]
            elif field == "finding_title":
                value["corrections"][0]["title"] = " "
            else:
                value[field] = " "
            with self.subTest(field=field), self.assertRaisesRegex(ResearchError, "REVIEW_CONTENT"):
                apply_review(report(), value)

    def test_sentence_replacement_rejects_missing_empty_and_ambiguous_matches(self):
        for mode in ("nonmatching", "empty", "ambiguous"):
            draft, value = report(), review()
            before = "A sentence that does not occur in the draft."
            if mode == "empty":
                before = ""
            elif mode == "ambiguous":
                before = "Prices fell."
                draft["analysis"][0]["body"] = "Prices fell. Volume grew. Prices fell."
            value["corrections"][0]["replacements"] = [{"before": before, "after": "Corrected statement."}]
            unchanged = copy.deepcopy(draft)
            with self.subTest(mode=mode), self.assertRaisesRegex(ResearchError, "REVIEW_CONTENT"):
                apply_review(draft, value)
            self.assertEqual(draft, unchanged)

    def test_kind_only_correction_can_leave_body_untouched(self):
        value = review()
        value["corrections"][0].update(kind="unknown", replacements=[])
        out = apply_review(report(), value)
        self.assertEqual(out["analysis"][0]["body"], report()["analysis"][0]["body"])
        self.assertEqual(out["analysis"][0]["kind"], "unknown")

    def test_review_failure_is_a_host_owned_coverage_gap(self):
        store = research()
        self.assertTrue(validate_report(report(), request(), store)["coverageComplete"])
        store.review_failed = True
        out = validate_report(report(), request(), store)
        self.assertFalse(out["coverageComplete"])
        self.assertEqual(out["predictions"][0]["direction"], "down")
        self.assertEqual(len(out["analysis"]), 1)


class ReviewAsyncTests(unittest.IsolatedAsyncioTestCase):
    async def test_flash_and_analysis_free_reports_skip_sdk(self):
        invoke = AsyncMock()
        options = Mock()
        for req, draft in ((request("flash"), report()), (request(), {**report(), "analysis": []})):
            self.assertIs(await audit_report(draft, req, invoke, options), draft)
        invoke.assert_not_awaited()
        options.assert_not_called()

    async def test_audit_uses_no_research_tools_and_applies_structured_corrections(self):
        configured = SimpleNamespace(max_turns=40, system_prompt="original")
        options = Mock(return_value=configured)
        invoke = AsyncMock(return_value=review())
        out = await audit_report(report(), request(), invoke, options)
        self.assertEqual(options.call_args.kwargs, {"schema": REVIEW_SCHEMA})
        self.assertEqual(len(options.call_args.args), 1)
        self.assertEqual(configured.max_turns, 3)
        self.assertEqual(configured.effort, "low")
        self.assertEqual(out["predictions"][0]["direction"], "neutral")
        payload = json.loads(invoke.call_args.args[1])
        self.assertEqual(payload["draft"], report())
        self.assertEqual(payload["timezone"], request()["timezone"])
        self.assertEqual(payload["horizonHours"], 1)

    async def test_runner_records_failed_review_and_retains_validated_draft(self):
        store = research()
        store.bootstrap = AsyncMock(return_value={})

        async def fake_model(_options, _prompt, validator):
            return await validator(report())

        with (patch("runner.Research", return_value=store),
              patch("runner.sdk_options", return_value=SimpleNamespace()),
              patch("runner.invoke_model", side_effect=fake_model),
              patch("runner.refresh_reference_quotes", new_callable=AsyncMock),
              patch("runner.time.time", return_value=NOW + 100),
              patch("review.audit_report", new_callable=AsyncMock,
                    side_effect=ResearchError("REVIEW_REFERENCE: a correction invented an identifier"))):
            out = await make_report(request())
        self.assertTrue(store.review_failed)
        self.assertFalse(out["coverageComplete"])
        self.assertEqual(out["predictions"][0]["direction"], "down")
        self.assertEqual(out["analysis"][0]["body"], report()["analysis"][0]["body"])
        self.assertIn("一致性复核本轮未完成", out["coverage"])

    async def test_runner_reviews_after_research_and_assigns_host_ids_only_once(self):
        store = research()
        store.bootstrap = AsyncMock(return_value={})
        phases = []

        async def fake_model(_options, _prompt, validator):
            draft = await validator(report())
            phases.append("research_complete")
            return draft

        async def fake_review(draft, _request, _invoke, _options):
            self.assertEqual(phases, ["research_complete"])
            self.assertEqual(draft["analysis"][0]["id"], "positioning")
            self.assertEqual(draft["predictions"][0]["findingIds"], ["positioning"])
            phases.append("review_complete")
            return apply_review(draft, review())

        async def refresh(_market, _request):
            self.assertEqual(phases, ["research_complete", "review_complete"])
            phases.append("quotes_refreshed")

        with (patch("runner.Research", return_value=store),
              patch("runner.sdk_options", return_value=SimpleNamespace()),
              patch("runner.invoke_model", side_effect=fake_model),
              patch("runner.refresh_reference_quotes", side_effect=refresh),
              patch("runner.time.time", return_value=NOW + 100),
              patch("review.audit_report", side_effect=fake_review)):
            out = await make_report(request())
        expected = validate_report(apply_review(report(), review()), request(), research(), completed_at=NOW + 100)
        self.assertEqual(phases, ["research_complete", "review_complete", "quotes_refreshed"])
        self.assertEqual(out["analysis"][0]["id"], expected["analysis"][0]["id"])
        self.assertEqual(out["predictions"][0]["findingIds"], [out["analysis"][0]["id"]])
        self.assertEqual(out["predictions"][0]["direction"], "neutral")


if __name__ == "__main__":
    unittest.main()
