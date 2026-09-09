import copy
import io
import json
import os
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from model_selection import DEFAULT_MODEL, normalize_model
from research import ResearchError
import runner
from schema import MODEL_REPORT_SCHEMA, REPORT_SCHEMA
from validation import parse_request, validate_report
from test_intelligence import report, request, research
from test_review import NOW, report as analysis_report, request as analysis_request, research as analysis_research, review


CUSTOM_MODEL = "model_hub/es1_orange_o48_for_bench_expert[1m]"


class ModelSelectionTests(unittest.TestCase):
    def test_legacy_request_uses_default_even_with_inherited_model(self):
        with patch.dict(os.environ, {"ANTHROPIC_MODEL": "parent/wrong-model"}):
            self.assertEqual(parse_request(request())["model"], DEFAULT_MODEL)
            self.assertEqual(runner.sdk_options("/tmp").model, DEFAULT_MODEL)

    def test_explicit_request_is_normalized_without_mutating_input(self):
        value = request()
        value["model"] = " \n" + CUSTOM_MODEL + "\t "
        original = copy.deepcopy(value)
        with patch.dict(os.environ, {"ANTHROPIC_MODEL": "parent/wrong-model"}):
            parsed = parse_request(value)
            options = runner.sdk_options("/tmp", model=parsed["model"])
        self.assertEqual(value, original)
        self.assertEqual(parsed["model"], CUSTOM_MODEL)
        self.assertEqual(options.model, CUSTOM_MODEL)
        self.assertIsNone(options.fallback_model)
        self.assertNotIn("ANTHROPIC_MODEL", options.env)

    def test_model_identifier_boundaries_and_invalid_values_are_safe(self):
        self.assertEqual(normalize_model("a" * 200), "a" * 200)
        self.assertEqual(normalize_model("a.B-c_d/e:f[1m]"), "a.B-c_d/e:f[1m]")
        invalid = [None, 12, True, {}, [], "", "  \n ", "a" * 201,
                   "módél", "-model", "/model", "secret\nheader: value",
                   "private?key=secret", "model name", "model$secret"]
        for value in invalid:
            with self.subTest(value_type=type(value).__name__):
                incoming = request()
                incoming["model"] = value
                with self.assertRaises(ResearchError) as raised:
                    parse_request(incoming)
                self.assertEqual(str(raised.exception),
                                 "REQUEST_MODEL: model must be a nonempty ASCII identifier of at most 200 characters")

    def test_report_model_is_host_owned_and_wire_optional(self):
        from jsonschema import Draft202012Validator

        self.assertNotIn("model", MODEL_REPORT_SCHEMA["properties"])
        self.assertNotIn("model", REPORT_SCHEMA["required"])
        self.assertTrue(Draft202012Validator(REPORT_SCHEMA).is_valid(report()))
        selected = parse_request({**request(), "model": CUSTOM_MODEL})
        for spoofed in ("wrong/model", None, {"secret": "do not echo"}):
            draft = {**report(), "model": spoofed}
            original = copy.deepcopy(draft)
            result = validate_report(draft, selected, research())
            self.assertEqual(result["model"], CUSTOM_MODEL)
            self.assertEqual(draft, original)
            self.assertTrue(Draft202012Validator(REPORT_SCHEMA).is_valid(result))
        self.assertEqual(validate_report(report(), request(), research())["model"], DEFAULT_MODEL)


class ModelExecutionTests(unittest.IsolatedAsyncioTestCase):
    async def test_generation_and_real_review_share_selected_model(self):
        store = analysis_research()
        store.bootstrap = AsyncMock(return_value={})
        selected = {**analysis_request(), "model": CUSTOM_MODEL}
        invocations = []

        async def invoke(options, prompt, validator=None):
            invocations.append(options)
            self.assertEqual(options.model, CUSTOM_MODEL)
            self.assertIsNone(options.fallback_model)
            if validator:
                self.assertEqual(json.loads(prompt)["request"]["model"], CUSTOM_MODEL)
                return await validator(analysis_report())
            return review()

        with (patch.object(runner, "Research", return_value=store),
              patch.object(runner, "invoke_model", side_effect=invoke),
              patch.object(runner, "refresh_reference_quotes", new_callable=AsyncMock),
              patch.object(runner.time, "time", return_value=NOW + 100),
              patch.object(runner, "progress") as progress):
            result = await runner.make_report(selected)
        self.assertEqual(len(invocations), 2)
        self.assertTrue(invocations[0].mcp_servers)
        self.assertFalse(invocations[1].mcp_servers)
        self.assertEqual(result["model"], CUSTOM_MODEL)
        for call in progress.call_args_list:
            if call.args[0] in {"research_start", "consistency_review_start", "consistency_review_done"}:
                self.assertEqual(call.kwargs["model"], CUSTOM_MODEL)

    async def test_smoke_model_uses_cli_selection(self):
        args = SimpleNamespace(doctor=False, smoke_model=True, smoke_retrieval=False,
                               model=" " + CUSTOM_MODEL + " ")
        with patch.object(runner, "invoke_model", new_callable=AsyncMock, return_value={"status": "ok"}) as invoke:
            result = await runner.main_async(args)
        self.assertEqual(invoke.call_args.args[0].model, CUSTOM_MODEL)
        self.assertEqual(result, {"model": CUSTOM_MODEL, "result": {"status": "ok"}})

    async def test_doctor_uses_cli_selection_without_calling_model(self):
        args = SimpleNamespace(doctor=True, smoke_model=False, smoke_retrieval=False, model=CUSTOM_MODEL)
        with patch.object(runner, "invoke_model", new_callable=AsyncMock) as invoke:
            result = await runner.main_async(args)
        invoke.assert_not_called()
        self.assertEqual(result["model"], CUSTOM_MODEL)

    async def test_invalid_cli_model_is_rejected_before_invocation(self):
        args = SimpleNamespace(doctor=False, smoke_model=True, smoke_retrieval=False,
                               model="model?private=secret")
        with patch.object(runner, "invoke_model", new_callable=AsyncMock) as invoke:
            with self.assertRaisesRegex(ResearchError, "^REQUEST_MODEL:"):
                await runner.main_async(args)
        invoke.assert_not_called()

    async def test_report_request_wins_over_diagnostic_cli_model(self):
        args = SimpleNamespace(doctor=False, smoke_model=False, smoke_retrieval=False,
                               model="diagnostic/other-model")
        value = {**request(), "model": CUSTOM_MODEL}
        with (patch.object(sys, "stdin", io.StringIO(json.dumps(value))),
              patch.object(runner, "make_report", new_callable=AsyncMock, return_value={}) as make_report):
            await runner.main_async(args)
        self.assertEqual(make_report.call_args.args[0]["model"], CUSTOM_MODEL)


if __name__ == "__main__":
    unittest.main()
