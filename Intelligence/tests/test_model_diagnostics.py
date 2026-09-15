"""Failure classification and safe metadata need no network or model calls."""
import json
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from model_diagnostics import model_error, model_error_fields
from research import ResearchError


class ModelDiagnosticsTests(unittest.TestCase):
    def test_structured_http_status_overrides_conflicting_prose_and_assistant_error(self):
        for status, expected in ((401, "AUTH_REQUIRED"), (403, "MODEL_ACCESS_DENIED"),
                                 (429, "MODEL_RATE_LIMIT"), (400, "MODEL_REQUEST_REJECTED"),
                                 (500, "MODEL_UPSTREAM_UNAVAILABLE"), (502, "MODEL_UPSTREAM_UNAVAILABLE"),
                                 (503, "MODEL_UPSTREAM_UNAVAILABLE"), (529, "MODEL_UPSTREAM_UNAVAILABLE")):
            with self.subTest(status=status):
                message = SimpleNamespace(api_error_status=status,
                    result="The selected model may not exist; model_not_found; authentication failure 401.")
                fields = model_error_fields(message, assistant_error="invalid_request")
                self.assertEqual(fields["code"], expected)
                self.assertEqual(fields["apiStatus"], status)
                self.assertEqual(fields["evidence"], "http_status")
                self.assertIsInstance(model_error(message), ResearchError)
                self.assertTrue(str(model_error(message)).startswith(expected + ":"))

    def test_assistant_error_enums_are_used_without_provider_prose(self):
        for value, expected in (("authentication_failed", "AUTH_REQUIRED"),
                                ("billing_error", "MODEL_RATE_LIMIT"), ("rate_limit", "MODEL_RATE_LIMIT"),
                                ("invalid_request", "MODEL_REQUEST_REJECTED"),
                                ("server_error", "MODEL_UPSTREAM_UNAVAILABLE")):
            with self.subTest(value=value):
                fields = model_error_fields(SimpleNamespace(result="selected model"), value)
                self.assertEqual(fields["code"], expected)
                self.assertEqual(fields["assistantError"], value)
                self.assertEqual(fields["evidence"], "assistant_error")

    def test_explicit_model_not_found_identifier_can_confirm_missing_model(self):
        for message in (SimpleNamespace(result='API Error: {"error":{"code":"model_not_found"}}'),
                        SimpleNamespace(errors=["model_not_found"]),
                        SimpleNamespace(api_error_status=404, result="model_not_found")):
            with self.subTest(message=message):
                self.assertEqual(model_error_fields(message)["code"], "MODEL_UNAVAILABLE")
        for prose in ("model_not_foundation", "prefix_model_not_found_suffix", "model not found", "unrecognized_model"):
            with self.subTest(prose=prose):
                self.assertEqual(model_error_fields(SimpleNamespace(result=prose))["code"], "MODEL_FAILED")

    def test_generic_selected_model_hint_does_not_claim_missing_model_or_bad_credentials(self):
        message = SimpleNamespace(result="There is an issue with the selected model. It may not exist or you may not have access.")
        fields = model_error_fields(message)
        self.assertEqual(fields["code"], "MODEL_REQUEST_REJECTED")
        self.assertEqual(fields["evidence"], "ambiguous_model_access")
        text = str(model_error(message))
        for unsupported_advice in ("ANTHROPIC", "API_KEY", "重新配置", "登录", "认证失败"):
            self.assertNotIn(unsupported_advice, text)

    def test_http_404_without_model_error_code_is_not_model_unavailable(self):
        fields = model_error_fields(SimpleNamespace(api_error_status=404, result="Route not found"))
        self.assertEqual(fields["code"], "MODEL_REQUEST_REJECTED")
        self.assertEqual(fields["evidence"], "http_status")

    def test_prose_numbers_do_not_imply_http_status(self):
        for prose in ("Request has 429 tokens", "See error detail at line 401", "A server_error appears in this quoted explanation"):
            with self.subTest(prose=prose):
                fields = model_error_fields(SimpleNamespace(result=prose))
                self.assertEqual(fields["code"], "MODEL_FAILED")
                self.assertIsNone(fields["apiStatus"])

    def test_unknown_fields_and_secret_bearing_prose_never_escape(self):
        secret = "SECRET_SENTINEL_DO_NOT_DISCLOSE"
        secret_type = type(secret, (Exception,), {})
        message = secret_type(secret)
        message.result = "selected model at https://user:" + secret + "@relay.invalid/path?key=" + secret
        message.errors = [secret, {"api_key": secret}]
        message.stderr = "x-relay-api-key: " + secret
        message.api_error_status = secret
        message.subtype = secret
        message.terminal_reason = secret
        message.data = {"authorization": secret}
        fields = model_error_fields(message, assistant_error=secret)
        serialized = json.dumps(fields) + str(model_error(message, assistant_error=secret))
        self.assertNotIn(secret, serialized)
        for fragment in ("relay.invalid", "x-relay-api-key", "https://", "authorization"):
            self.assertNotIn(fragment, serialized)
        self.assertEqual(set(fields), {"code", "evidence", "apiStatus", "errorClass", "subtype", "terminalReason", "assistantError"})
        self.assertEqual(fields["errorClass"], "unknown")
        self.assertIsNone(fields["subtype"])
        self.assertIsNone(fields["terminalReason"])
        self.assertIsNone(fields["assistantError"])

    def test_invalid_http_status_values_are_not_copied_or_coerced(self):
        for status in (True, False, "401", 401.0, -1, 0, 99, 600, float("nan"), {"secret": "x"}):
            with self.subTest(status=status):
                fields = model_error_fields(SimpleNamespace(api_error_status=status))
                self.assertIsNone(fields["apiStatus"])
                self.assertEqual(fields["code"], "MODEL_FAILED")
                json.dumps(fields, allow_nan=False)

    def test_known_sdk_enums_are_safe_metadata_and_none_is_classified(self):
        fields = model_error_fields(SimpleNamespace(subtype="error_max_turns", terminal_reason="max_turns"))
        self.assertEqual(fields["subtype"], "error_max_turns")
        self.assertEqual(fields["terminalReason"], "max_turns")
        self.assertEqual(fields["code"], "MODEL_FAILED")
        self.assertIsNone(model_error_fields()["errorClass"])
        self.assertEqual(model_error_fields()["code"], "MODEL_FAILED")

    def test_actual_sdk_result_and_exception_share_classification(self):
        from claude_agent_sdk import ResultMessage
        from claude_agent_sdk._errors import ResultError
        result = ResultMessage(subtype="error_during_execution", duration_ms=1, duration_api_ms=1,
                               is_error=True, num_turns=1, session_id="fixture-session",
                               api_error_status=429, result="selected model could not complete")
        error = ResultError("provider failure", data={"subtype": "error_during_execution",
                            "api_error_status": 429, "terminal_reason": "api_error",
                            "result": "selected model could not complete"}, exit_code=1)
        for message, name in ((result, "ResultMessage"), (error, "ResultError")):
            with self.subTest(name=name):
                fields = model_error_fields(message)
                self.assertEqual(fields["code"], "MODEL_RATE_LIMIT")
                self.assertEqual(fields["apiStatus"], 429)
                self.assertEqual(fields["errorClass"], name)

    def test_actual_sdk_assistant_error_is_recognized(self):
        from claude_agent_sdk import AssistantMessage
        message = AssistantMessage(content=[], model="fixture-model", error="authentication_failed")
        fields = model_error_fields(message)
        self.assertEqual(fields["code"], "AUTH_REQUIRED")
        self.assertEqual(fields["assistantError"], "authentication_failed")
        self.assertEqual(fields["errorClass"], "AssistantMessage")


if __name__ == "__main__":
    unittest.main()
