"""The packaged interpreter must leave signed application resources intact."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class PackagedRuntimeTests(unittest.TestCase):
    def test_startup_does_not_add_import_caches_to_app_resources(self):
        source = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory(prefix="maystock-signed-resources-") as directory:
            resources = Path(directory)
            for module in source.glob("*.py"):
                shutil.copy2(module, resources / module.name)
            before = {p.name: p.read_bytes() for p in resources.iterdir()}
            environment = dict(os.environ)
            environment.pop("PYTHONDONTWRITEBYTECODE", None)
            result = subprocess.run([sys.executable, str(resources / "runner.py"), "--help"],
                                    cwd=resources, env=environment, capture_output=True,
                                    text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(set(p.name for p in resources.iterdir()), set(before))
            self.assertTrue(all((resources / name).read_bytes() == contents
                                for name, contents in before.items()))


if __name__ == "__main__":
    unittest.main()
