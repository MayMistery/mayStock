"""Runner-level connection isolation and retry regressions, without model calls."""
import asyncio
import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import AsyncMock, Mock, patch

from claude_agent_sdk import AssistantMessage, ResultMessage
from claude_agent_sdk._errors import ResultError

from Intelligence import runner
from Intelligence.connection import FIXED_ENV
from Intelligence.research import ResearchError


RELAY_SECRET = "TEST_RELAY_CREDENTIAL_NEVER_IN_DIAGNOSTICS"
PARENT_SECRET = "TEST_PARENT_CREDENTIAL_NEVER_IN_DIAGNOSTICS"
PROVIDER_SECRET = "TEST_PROVIDER_PROSE_NEVER_IN_DIAGNOSTICS"


class RunnerConnectionTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="maystock-runner-connection-")
        self.addCleanup(directory.cleanup)
        self.directory = Path(directory.name)
        self.connection = self.directory / "private-connection.json"
        self.route = {
            "ANTHROPIC_BASE_URL": "https://relay.example.test:8443/private/" + RELAY_SECRET,
            "ANTHROPIC_CUSTOM_HEADERS": "x-relay-passthrough: anthropic\nx-relay-api-key: " + RELAY_SECRET,
        }
        self.connection.write_text(json.dumps(self.route))
        self.environment = {
            "HOME": str(self.directory), "PATH": "/usr/bin:/bin",
            "MAYSTOCK_INTELLIGENCE_CONNECTION": str(self.connection),
            "ANTHROPIC_BASE_URL": "https://unrelated-parent.example.test",
            "ANTHROPIC_API_KEY": PARENT_SECRET,
            "ANTHROPIC_AUTH_TOKEN": PARENT_SECRET,
            "CLAUDE_CODE_OAUTH_TOKEN": PARENT_SECRET,
            "CLAUDECODE": "1",
            "CLAUDE_CODE_HOST_SESSION_ID": "parent-session",
            "CLAUDE_CODE_MESSAGING_SOCKET": "/tmp/parent-session.sock",
            "CLAUDE_CODE_MESSAGING_TOKEN": PARENT_SECRET,
            "CLAUDE_CODE_SDK_HAS_HOST_AUTH_REFRESH": "1",
            "CLAUDE_CODE_EXECPATH": "/unrelated/global/claude",
            "_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL": "1",
            "HTTPS_PROXY": "http://proxy.example.test:8080",
        }
        # configure_runtime mutates the worker's actual process environment and
        # caches its profile. Both must be restored after each in-process test.
        self.environment_patch = patch.dict(os.environ, self.environment, clear=True)
        self.environment_patch.start()
        self.addCleanup(self.environment_patch.stop)
        self.profile_patch = patch.object(runner, "_active_connection", None)
        self.profile_patch.start()
        self.addCleanup(self.profile_patch.stop)

    def test_configure_runtime_removes_parent_credentials_and_ipc_from_os_environ(self):
        profile = runner.configure_runtime()
        options = runner.sdk_options(str(self.directory))
        removed = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN",
                   "CLAUDECODE", "CLAUDE_CODE_HOST_SESSION_ID", "CLAUDE_CODE_MESSAGING_SOCKET",
                   "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_SDK_HAS_HOST_AUTH_REFRESH",
                   "CLAUDE_CODE_EXECPATH", "_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL"]
        for key in removed:
            with self.subTest(key=key):
                self.assertNotIn(key, os.environ, "Omitting SDK options.env keys does not isolate its inherited environment")
                self.assertNotIn(key, options.env)
        self.assertEqual(profile.source, "connection")
        self.assertEqual(os.environ["ANTHROPIC_BASE_URL"], self.route["ANTHROPIC_BASE_URL"])
        self.assertEqual(os.environ["ANTHROPIC_CUSTOM_HEADERS"], self.route["ANTHROPIC_CUSTOM_HEADERS"])
        self.assertEqual(options.env["ANTHROPIC_CUSTOM_HEADERS"], self.route["ANTHROPIC_CUSTOM_HEADERS"])
        self.assertEqual(os.environ["HTTPS_PROXY"], self.environment["HTTPS_PROXY"])
        for key, value in FIXED_ENV.items():
            self.assertEqual(os.environ[key], value)
        self.assertIs(runner._active_connection, profile)

    def test_sdk_options_leave_cli_choice_to_sdk_despite_global_claude(self):
        runner.configure_runtime()
        with patch("shutil.which", return_value="/unrelated/global/claude"):
            options = runner.sdk_options(str(self.directory))
        self.assertIsNone(options.cli_path)
        self.assertEqual(options.model, runner.MODEL)
        self.assertIsNone(options.fallback_model)

    def test_explicit_cli_override_survives_runtime_isolation(self):
        selected_cli = "/opt/maystock-pinned-runtime/claude"
        os.environ["MAYSTOCK_CLAUDE_PATH"] = selected_cli
        runner.configure_runtime()
        self.assertEqual(runner.sdk_options(str(self.directory)).cli_path, selected_cli)
        diagnostic = runner.doctor()
        self.assertEqual(diagnostic["cliSelection"], "override")
        self.assertEqual(diagnostic["claudePath"], selected_cli)

    def test_repair_second_query_rate_limit_does_not_reuse_previous_success(self):
        self.check_second_query_failure(429, "MODEL_RATE_LIMIT")

    def test_repair_second_query_auth_failure_does_not_reuse_previous_success(self):
        self.check_second_query_failure(401, "AUTH_REQUIRED")

    def test_repair_second_query_does_not_keep_previous_assistant_error(self):
        self.check_second_query_failure(None, "MODEL_FAILED", first_assistant_error="authentication_failed")

    def check_second_query_failure(self, status, expected_code, first_assistant_error=None):
        first = ResultMessage(subtype="success", duration_ms=1, duration_api_ms=1,
                              is_error=False, num_turns=1, session_id="fixture-session",
                              result=PROVIDER_SECRET, structured_output={"events": "invalid-array"})
        second_failure = ResultError(
            "provider prose " + PROVIDER_SECRET,
            data={"subtype": "error_during_execution", "api_error_status": status,
                  "terminal_reason": "api_error", "result": "request failed " + PROVIDER_SECRET},
            exit_code=1)
        client = Mock()
        client.__aenter__ = AsyncMock(return_value=client)
        client.__aexit__ = AsyncMock(return_value=False)
        client.query = AsyncMock(side_effect=[None, second_failure])

        async def response():
            if first_assistant_error:
                yield AssistantMessage(content=[], model="fixture-model", error=first_assistant_error)
            yield first

        client.receive_response = Mock(side_effect=response)
        validator = Mock(side_effect=ResearchError("REPORT_SCHEMA: events must be an array"))
        progress_output = io.StringIO()
        with patch("claude_agent_sdk.ClaudeSDKClient", return_value=client), \
             contextlib.redirect_stderr(progress_output), \
             self.assertRaises(ResearchError) as caught:
            asyncio.run(runner.invoke_model(object(), "original research request", validator))
        self.assertTrue(str(caught.exception).startswith(expected_code + ":"))
        self.assertEqual(client.query.await_count, 2)
        self.assertEqual(client.receive_response.call_count, 1)
        validator.assert_called_once_with(first.structured_output)
        events = [json.loads(line) for line in progress_output.getvalue().splitlines()]
        failure = next(event for event in events if event["stage"] == "model_exception")
        self.assertEqual(failure["code"], expected_code)
        self.assertEqual(failure["apiStatus"], status)
        self.assertEqual(failure["errorClass"], "ResultError")
        self.assertIsNone(failure["assistantError"], "A repair attempt must not inherit the previous assistant error")
        self.assertNotIn(PROVIDER_SECRET, progress_output.getvalue() + str(caught.exception))

    def test_doctor_reports_effective_profile_without_credentials_or_url_path(self):
        runner.configure_runtime()
        diagnostic = runner.doctor()
        self.assertEqual(diagnostic["source"], "connection")
        self.assertEqual(diagnostic["origin"], "https://relay.example.test:8443")
        self.assertEqual(diagnostic["headerNames"], ["x-relay-api-key", "x-relay-passthrough"])
        self.assertEqual(diagnostic["cliSelection"], "sdk_default")
        self.assertTrue(diagnostic["settingsIsolated"])
        self.assertTrue(diagnostic["routingConfigured"])
        self.assertIn("ANTHROPIC_API_KEY", diagnostic["ignoredEnvironmentKeys"])
        self.assertIn("CLAUDE_CODE_MESSAGING_TOKEN", diagnostic["ignoredEnvironmentKeys"])
        self.assertNotIn("ANTHROPIC_API_KEY", diagnostic["routingEnvironmentKeys"])
        serialized = json.dumps(diagnostic)
        for value in (RELAY_SECRET, PARENT_SECRET, self.route["ANTHROPIC_BASE_URL"],
                      str(self.connection), "/tmp/parent-session.sock"):
            self.assertNotIn(value, serialized)

    def test_main_configures_process_before_entering_any_async_operation(self):
        async def observe_configured_runtime(args):
            self.assertTrue(args.doctor)
            self.assertNotIn("ANTHROPIC_API_KEY", os.environ)
            self.assertNotIn("CLAUDE_CODE_MESSAGING_TOKEN", os.environ)
            self.assertEqual(os.environ["ANTHROPIC_BASE_URL"], self.route["ANTHROPIC_BASE_URL"])
            return runner.doctor()

        output = io.StringIO()
        progress_output = io.StringIO()
        with patch.object(runner, "main_async", side_effect=observe_configured_runtime), \
             patch("sys.argv", ["runner.py", "--doctor"]), contextlib.redirect_stdout(output), \
             contextlib.redirect_stderr(progress_output):
            status = runner.main()
        self.assertEqual(status, 0)
        self.assertEqual(json.loads(output.getvalue())["source"], "connection")
        self.assertNotIn(RELAY_SECRET, output.getvalue() + progress_output.getvalue())
        self.assertNotIn(PARENT_SECRET, output.getvalue() + progress_output.getvalue())


if __name__ == "__main__":
    unittest.main()
