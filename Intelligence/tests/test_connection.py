import copy
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from Intelligence.connection import AUTH_ENV, FIXED_ENV, isolated_environment, resolve_connection
from Intelligence.research import ResearchError


SECRET = "TEST_ONLY_SECRET_VALUE_DO_NOT_PRINT"
RELAY = {"ANTHROPIC_BASE_URL": "https://relay.example.test/api",
         "ANTHROPIC_CUSTOM_HEADERS": "x-relay-passthrough: anthropic\nx-relay-api-key: " + SECRET}


class ConnectionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.dedicated = self.home / "Library/Application Support/MayStock/Intelligence/connection.json"
        self.settings = self.home / ".claude/settings.json"

    def write(self, path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value))

    def resolve(self, environ=None):
        return resolve_connection({} if environ is None else environ, home=self.home)

    def test_dedicated_relay_wins_as_group_over_parent_route_auth_and_host_ipc(self):
        self.write(self.dedicated, RELAY)
        inherited = {"ANTHROPIC_BASE_URL": "https://wrong-parent.example.test",
                     "ANTHROPIC_API_KEY": "wrong-api-key", "ANTHROPIC_AUTH_TOKEN": "wrong-bearer",
                     "CLAUDE_CODE_OAUTH_TOKEN": "wrong-oauth", "CLAUDE_CODE_USE_VERTEX": "1",
                     "AWS_ACCESS_KEY_ID": "wrong-aws", "CLAUDE_CODE_HOST_SESSION_ID": "parent-session",
                     "CLAUDE_CODE_MESSAGING_SOCKET": "/tmp/parent", "CLAUDE_CODE_MESSAGING_TOKEN": "parent-token",
                     "CLAUDE_CODE_SDK_HAS_HOST_AUTH_REFRESH": "1", "CLAUDE_CODE_SDK_HAS_OAUTH_REFRESH": "1",
                     "CLAUDE_CODE_EXECPATH": "/parent/claude", "CLAUDE_CODE_OAUTH_SCOPES": "parent-scopes",
                     "CLAUDECODE": "1", "ANTHROPIC_UNIX_SOCKET": "/parent/socket",
                     "_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL": "1", "CLAUDE_CONFIG_DIR": "/user/config",
                     "PATH": "/usr/bin", "HOME": str(self.home), "MAYSTOCK_CLAUDE_PATH": "/pinned/claude"}
        profile = self.resolve(inherited)
        child = isolated_environment(inherited, profile)
        self.assertEqual(profile.env, RELAY)
        self.assertEqual(profile.source, "connection")
        self.assertEqual(child, {**RELAY, **FIXED_ENV, "CLAUDE_CONFIG_DIR": "/user/config",
                                 "PATH": "/usr/bin", "HOME": str(self.home), "MAYSTOCK_CLAUDE_PATH": "/pinned/claude"})
        self.assertIn("ANTHROPIC_BASE_URL", profile.ignored_environment_keys)
        self.assertIn("CLAUDE_CODE_MESSAGING_TOKEN", profile.ignored_environment_keys)
        self.assertNotIn("ANTHROPIC_API_KEY", child)

    def test_dedicated_valid_config_does_not_read_unrelated_broken_claude_settings(self):
        self.write(self.dedicated, RELAY)
        self.settings.parent.mkdir(parents=True)
        self.settings.write_text("invalid JSON " + SECRET)
        self.assertEqual(self.resolve().env, RELAY)

    def test_environment_group_does_not_borrow_settings_auth(self):
        self.write(self.settings, {"env": {"ANTHROPIC_BASE_URL": "https://legacy.example.test",
                                          "ANTHROPIC_AUTH_TOKEN": SECRET}})
        profile = self.resolve({"ANTHROPIC_BASE_URL": "https://environment.example.test"})
        self.assertEqual(profile.source, "environment")
        self.assertEqual(profile.env, {"ANTHROPIC_BASE_URL": "https://environment.example.test"})

    def test_environment_auth_does_not_borrow_settings_endpoint(self):
        self.write(self.settings, {"env": RELAY})
        profile = self.resolve({"ANTHROPIC_API_KEY": SECRET})
        self.assertEqual(profile.env, {"ANTHROPIC_API_KEY": SECRET})
        self.assertIsNone(profile.origin)

    def test_dedicated_endpoint_only_does_not_borrow_environment_headers(self):
        self.write(self.dedicated, {"ANTHROPIC_BASE_URL": "https://dedicated.example.test"})
        profile = self.resolve(RELAY)
        self.assertEqual(profile.env, {"ANTHROPIC_BASE_URL": "https://dedicated.example.test"})

    def test_settings_route_is_supported_without_explicit_process_route(self):
        self.write(self.settings, {"env": RELAY})
        profile = self.resolve({"HTTPS_PROXY": "http://proxy.example.test:8080"})
        self.assertEqual(profile.source, "claude_settings")
        self.assertEqual(profile.env, {**RELAY, "HTTPS_PROXY": "http://proxy.example.test:8080"})

    def test_legacy_environment_only_relay_needs_no_additional_api_key(self):
        profile = self.resolve(RELAY)
        self.assertEqual(profile.source, "environment")
        self.assertEqual(profile.env, RELAY)
        self.assertEqual(profile.header_names, ("x-relay-api-key", "x-relay-passthrough"))

    def test_native_login_remains_available_when_no_connection_is_configured(self):
        inherited = {"HOME": str(self.home), "PATH": "/usr/bin", "CLAUDE_CODE_HOST_SESSION_ID": "stale",
                     "CLAUDE_CONFIG_DIR": str(self.home / ".claude")}
        profile = self.resolve(inherited)
        self.assertEqual(profile.source, "native")
        self.assertEqual(profile.env, {})
        child = isolated_environment(inherited, profile)
        self.assertEqual(child["HOME"], inherited["HOME"])
        self.assertEqual(child["CLAUDE_CONFIG_DIR"], inherited["CLAUDE_CONFIG_DIR"])
        self.assertNotIn("CLAUDE_CODE_HOST_SESSION_ID", child)

    def test_environment_oauth_login_is_preserved_when_it_is_selected_group(self):
        inherited = {"CLAUDE_CODE_OAUTH_TOKEN": SECRET, "CLAUDE_CODE_OAUTH_SCOPES": "stale-scopes"}
        profile = self.resolve(inherited)
        child = isolated_environment(inherited, profile)
        self.assertEqual(child["CLAUDE_CODE_OAUTH_TOKEN"], SECRET)
        self.assertNotIn("CLAUDE_CODE_OAUTH_SCOPES", child)

    def test_explicit_dedicated_transport_overrides_environment(self):
        self.write(self.dedicated, {**RELAY, "HTTPS_PROXY": "http://dedicated.example.test:8080",
                                   "NODE_EXTRA_CA_CERTS": "/dedicated/ca.pem"})
        profile = self.resolve({"HTTPS_PROXY": "http://parent.example.test:8080", "NODE_EXTRA_CA_CERTS": "/parent/ca.pem",
                                "NO_PROXY": "localhost"})
        self.assertEqual(profile.env["HTTPS_PROXY"], "http://dedicated.example.test:8080")
        self.assertEqual(profile.env["NODE_EXTRA_CA_CERTS"], "/dedicated/ca.pem")
        self.assertEqual(profile.env["NO_PROXY"], "localhost")

    def test_environment_transport_overrides_legacy_settings_transport(self):
        self.write(self.settings, {"env": {**RELAY, "HTTPS_PROXY": "http://settings.example.test:8080"}})
        profile = self.resolve({"HTTPS_PROXY": "http://environment.example.test:8080"})
        self.assertEqual(profile.env["HTTPS_PROXY"], "http://environment.example.test:8080")

    def test_diagnostics_do_not_contain_secrets_url_path_or_userinfo(self):
        self.write(self.dedicated, {**RELAY, "ANTHROPIC_BASE_URL": "https://relay.example.test:8443/private/" + SECRET})
        profile = self.resolve({"ANTHROPIC_API_KEY": "OTHER_SECRET"})
        diagnostics = profile.diagnostics()
        self.assertEqual(diagnostics["origin"], "https://relay.example.test:8443")
        self.assertEqual(set(diagnostics), {"source", "origin", "headerNames", "ignoredEnvironmentKeys"})
        serialized = json.dumps(diagnostics)
        self.assertNotIn(SECRET, serialized)
        self.assertNotIn("OTHER_SECRET", serialized)
        self.assertNotIn("private", serialized)
        self.assertNotIn(SECRET, repr(profile))

    def test_invalid_base_urls_reject_without_echoing_values(self):
        invalid = ["ftp://example.test/" + SECRET, "https://user:" + SECRET + "@example.test",
                   "https://example.test?token=" + SECRET, "https://example.test#" + SECRET,
                   "https://example.test/" + SECRET + "?", "not a URL " + SECRET,
                   "https://example.test:invalid/" + SECRET, "https://example.test/\n" + SECRET]
        for base in invalid:
            with self.subTest(base_kind=invalid.index(base)):
                self.write(self.dedicated, {"ANTHROPIC_BASE_URL": base})
                with self.assertRaises(ResearchError) as caught:
                    self.resolve()
                self.assertTrue(str(caught.exception).startswith("CONNECTION_CONFIG:"))
                self.assertNotIn(SECRET, str(caught.exception))

    def test_http_and_ipv6_origins_are_supported(self):
        self.write(self.dedicated, {"ANTHROPIC_BASE_URL": "http://[::1]:8080/v1"})
        self.assertEqual(self.resolve().origin, "http://[::1]:8080")

    def test_headers_accept_real_newlines_and_colons_in_values(self):
        self.write(self.dedicated, {"ANTHROPIC_CUSTOM_HEADERS": "X-One: prefix:rest\r\nX-Two: second"})
        profile = self.resolve()
        self.assertEqual(profile.header_names, ("x-one", "x-two"))
        self.assertEqual(profile.env["ANTHROPIC_CUSTOM_HEADERS"], "X-One: prefix:rest\r\nX-Two: second")

    def test_headers_reject_literal_newlines_duplicates_empty_values_and_invalid_names(self):
        invalid = ["X-One: " + SECRET + r"\nX-Two: value", "X-One: " + SECRET + "\nx-one: value",
                   "X-One:", "Invalid Name: " + SECRET, "NoColon " + SECRET, "X-One: \x00" + SECRET,
                   "X-One: " + SECRET + "\rX-Two: value", "X-One: " + SECRET + "\vX-Two: value", ""]
        for value in invalid:
            with self.subTest(header_kind=invalid.index(value)):
                self.write(self.dedicated, {"ANTHROPIC_CUSTOM_HEADERS": value})
                with self.assertRaises(ResearchError) as caught:
                    self.resolve()
                self.assertNotIn(SECRET, str(caught.exception))

    def test_partial_relay_configuration_cannot_borrow_missing_fields(self):
        invalid = [{"ANTHROPIC_CUSTOM_HEADERS": RELAY["ANTHROPIC_CUSTOM_HEADERS"]},
                   {"ANTHROPIC_BASE_URL": RELAY["ANTHROPIC_BASE_URL"], "ANTHROPIC_CUSTOM_HEADERS": "x-relay-api-key: " + SECRET},
                   {"ANTHROPIC_BASE_URL": RELAY["ANTHROPIC_BASE_URL"], "ANTHROPIC_CUSTOM_HEADERS": "x-relay-passthrough: anthropic"},
                   {**RELAY, "ANTHROPIC_CUSTOM_HEADERS": "x-relay-passthrough: " + SECRET + "\nx-relay-api-key: valid"}]
        for value in invalid:
            with self.subTest(config_kind=invalid.index(value)):
                self.write(self.dedicated, value)
                with self.assertRaises(ResearchError) as caught:
                    self.resolve(RELAY)
                self.assertNotIn(SECRET, str(caught.exception))

    def test_explicit_missing_path_fails_instead_of_falling_back(self):
        with self.assertRaisesRegex(ResearchError, "MAYSTOCK_INTELLIGENCE_CONNECTION"):
            self.resolve({**RELAY, "MAYSTOCK_INTELLIGENCE_CONNECTION": str(self.home / "missing.json")})

    def test_explicit_connection_override_is_used(self):
        alternate = self.home / "another.json"
        self.write(alternate, RELAY)
        self.write(self.dedicated, {"ANTHROPIC_BASE_URL": "https://ignored.example.test"})
        self.assertEqual(self.resolve({"MAYSTOCK_INTELLIGENCE_CONNECTION": "~/another.json"}).env, RELAY)

    def test_broken_and_wrong_type_dedicated_configuration_fail_safely(self):
        self.dedicated.parent.mkdir(parents=True)
        invalid = ["malformed " + SECRET, json.dumps([SECRET]),
                   json.dumps({"ANTHROPIC_BASE_URL": {"secret": SECRET}})]
        for value in invalid:
            self.dedicated.write_text(value)
            with self.assertRaises(ResearchError) as caught:
                self.resolve(RELAY)
            self.assertTrue(str(caught.exception).startswith("CONNECTION_CONFIG:"))
            self.assertNotIn(SECRET, str(caught.exception))

    def test_only_whitelisted_string_configuration_is_accepted(self):
        self.write(self.dedicated, {**RELAY, "PATH": "/malicious", "CLAUDE_CODE_MESSAGING_TOKEN": SECRET,
                                   "apiKeyHelper": "do not execute", "unrelated": {"ignored": True}})
        self.assertEqual(self.resolve().env, RELAY)
        self.assertNotIn("CLAUDE_CODE_MESSAGING_TOKEN", AUTH_ENV)

    def test_resolving_and_isolating_do_not_mutate_any_input_or_os_environment(self):
        self.write(self.dedicated, RELAY)
        inherited = {"PATH": "/usr/bin", "CLAUDE_CODE_HOST_SESSION_ID": "parent", "ANTHROPIC_BASE_URL": "https://parent.test"}
        before = copy.deepcopy(inherited)
        actual_environment = dict(os.environ)
        profile = self.resolve(inherited)
        profile_before = copy.deepcopy(profile.env)
        child = isolated_environment(inherited, profile)
        child["ANTHROPIC_BASE_URL"] = "https://changed.test"
        self.assertEqual(inherited, before)
        self.assertEqual(profile.env, profile_before)
        self.assertEqual(dict(os.environ), actual_environment)

    def test_resolve_defaults_to_os_environment_without_mutation(self):
        with patch.dict(os.environ, {**RELAY, "HOME": str(self.home)}, clear=True):
            before = dict(os.environ)
            profile = resolve_connection()
            self.assertEqual(profile.env, RELAY)
            self.assertEqual(dict(os.environ), before)


if __name__ == "__main__":
    unittest.main()
