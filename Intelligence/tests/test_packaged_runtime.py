"""The packaged interpreter must leave signed application resources intact."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class PackagedRuntimeTests(unittest.TestCase):
    def test_packaged_prediction_modules_import_without_mutating_resources(self):
        source = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory(prefix="maystock-prediction-resources-") as directory:
            resources = Path(directory) / "Intelligence"
            shutil.copytree(source, resources, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
            before = {p.relative_to(resources): p.read_bytes() for p in resources.rglob("*") if p.is_file()}
            environment = dict(os.environ)
            environment.pop("PYTHONDONTWRITEBYTECODE", None)
            environment.pop("PYTHONPYCACHEPREFIX", None)
            # The app executes runner.py as a script, rather than importing it.
            # run_path executes that same initialization without entering the
            # paid report path; the direct --help process is tested below.
            # Do not use -B or inherited cache suppression to hide mutations.
            result = subprocess.run([sys.executable, "-c", """
import asyncio, json, runpy
runpy.run_path('runner.py', run_name='maystock_packaging_probe')
from prediction_markets.__main__ import parser
from prediction_markets.sdk import PredictionResearch
from research import Research
assert parser().parse_args(['validate-config', '--config', 'examples/prediction-markets.json'])
print(json.dumps(asyncio.run(PredictionResearch(Research()).query())['providers']))
"""], cwd=resources, env=environment, capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('"polymarket", "kalshi"', result.stdout)
            after = {p.relative_to(resources): p.read_bytes() for p in resources.rglob("*") if p.is_file()}
            self.assertEqual(set(before), set(after), "Packaged resources gained or lost files")
            self.assertTrue(all(after[path] == data for path, data in before.items()),
                            "Packaged resource contents were modified")

    def test_startup_does_not_add_import_caches_to_app_resources(self):
        source = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory(prefix="maystock-signed-resources-") as directory:
            resources = Path(directory)
            for module in source.glob("*.py"):
                shutil.copy2(module, resources / module.name)
            before = {p.name: p.read_bytes() for p in resources.iterdir()}
            environment = dict(os.environ)
            environment.pop("PYTHONDONTWRITEBYTECODE", None)
            environment.pop("PYTHONPYCACHEPREFIX", None)
            result = subprocess.run([sys.executable, str(resources / "runner.py"), "--help"],
                                    cwd=resources, env=environment, capture_output=True,
                                    text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(set(p.name for p in resources.iterdir()), set(before))
            self.assertTrue(all((resources / name).read_bytes() == contents
                                for name, contents in before.items()))


if __name__ == "__main__":
    unittest.main()
