"""Every stderr diagnostic is declared, and carries only declared fields.

The app writes the "notice" events to its engine log, so a field that slipped
past the declaration would be a field nobody reviewed for secrets. These walk
the source, not a list of today's call sites.
"""
import ast
import contextlib
import io
import json
from pathlib import Path
import re
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import runner  # noqa: E402
from connection import ConnectionProfile  # noqa: E402
from model_diagnostics import model_error_fields  # noqa: E402

# What a `**splat` inside a progress() call expands to, by the expression
# splatted. A splat this table does not know fails the walk below.
SPLATS = {
    "fields": set(model_error_fields()),
    "model_error_fields": set(model_error_fields()),
    "diagnostics": set(ConnectionProfile(env={}, source="native", origin=None, header_names=(),
                                         ignored_environment_keys=()).diagnostics()),
}


def progress_calls():
    for path in sorted(ROOT.glob("*.py")):
        for node in ast.walk(ast.parse(path.read_text(), filename=str(path))):
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "progress":
                yield path.name, node


class DiagnosticsContractTests(unittest.TestCase):
    def test_every_call_names_a_declared_stage_with_declared_fields(self):
        calls = list(progress_calls())
        self.assertGreater(len(calls), 10)
        for file, call in calls:
            where = f"{file}:{call.lineno}"
            self.assertTrue(call.args and isinstance(call.args[0], ast.Constant), f"{where}: stage must be a literal")
            stage = call.args[0].value
            self.assertIn(stage, runner.DIAGNOSTICS, f"{where}: undeclared stage {stage}")
            allowed = runner.DIAGNOSTICS[stage][1]
            for keyword in call.keywords:
                if keyword.arg is not None:
                    self.assertIn(keyword.arg, allowed, f"{where}: {stage} does not declare {keyword.arg}")
                    continue
                value = keyword.value
                name = value.func.id if isinstance(value, ast.Call) and isinstance(value.func, ast.Name) else \
                    value.id if isinstance(value, ast.Name) else None
                self.assertIn(name, SPLATS, f"{where}: unknown splat in {stage}")
                self.assertLessEqual(SPLATS[name], allowed, f"{where}: {stage} splats undeclared fields")

    def test_levels_are_info_or_notice(self):
        for stage, (level, _) in runner.DIAGNOSTICS.items():
            self.assertIn(level, {"info", "notice"}, stage)

    def test_an_undeclared_field_is_dropped_and_named_never_its_value(self):
        stream = io.StringIO()
        with contextlib.redirect_stderr(stream):
            runner.progress("fetch_failed", host="example.test", token="SENTINEL-VALUE-NEVER-LOGGED")
        event = json.loads(stream.getvalue())
        self.assertEqual(event["stage"], "fetch_failed")
        self.assertEqual(event["level"], "notice")
        self.assertEqual(event["host"], "example.test")
        self.assertEqual(event["undeclaredFields"], ["token"])
        self.assertNotIn("SENTINEL", stream.getvalue())

    def test_the_contract_names_exactly_the_notices(self):
        contract = (ROOT.parent / "docs" / "INTELLIGENCE-CONTRACT.md").read_text()
        line = next(l for l in contract.splitlines() if l.startswith("Notices"))
        documented = set(re.findall(r"`([a-z_]+)`", line))
        declared = {stage for stage, (level, _) in runner.DIAGNOSTICS.items() if level == "notice"}
        self.assertEqual(documented, declared)


if __name__ == "__main__":
    unittest.main()
