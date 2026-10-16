"""Unit tests for action/setup.py — pure logic, no Docker required.

Run with: python3 -m unittest discover -s tests
"""

import importlib.util
import os
import tempfile
import unittest

_SPEC = importlib.util.spec_from_file_location(
    "setup_mod", os.path.join(os.path.dirname(__file__), "..", "action", "setup.py")
)
setup_mod = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(setup_mod)

BASE_ENV = {
    "RUNNER_TEMP": "/tmp/runner",
    "SP_REF_NAME": "main",
    "SP_RUN_ID": "42",
    "SP_CACHE_DIR": "",
    "SP_CACHE_KEY": "",
    "SP_CACHE_PATHS": "",
}


def resolve(**overrides):
    return setup_mod.resolve({**BASE_ENV, **overrides})


class ResolveTest(unittest.TestCase):
    def test_defaults_no_caching(self):
        cache_dir, key, paths = resolve()
        self.assertEqual(cache_dir, "/tmp/runner/salt-push-cache")
        self.assertEqual(key, "salt-push-main-42")
        self.assertEqual(paths, [])

    def test_explicit_dir_and_key(self):
        cache_dir, key, paths = resolve(SP_CACHE_DIR="/srv/cache", SP_CACHE_KEY="custom")
        self.assertEqual(cache_dir, "/srv/cache")
        self.assertEqual(key, "custom")
        self.assertEqual(paths, [])

    def test_dot_persists_whole_cache_dir(self):
        _, _, paths = resolve(SP_CACHE_PATHS=".")
        self.assertEqual(paths, ["/tmp/runner/salt-push-cache"])

    def test_set_but_no_entries_rejected(self):
        with self.assertRaises(setup_mod.ConfigError):
            resolve(SP_CACHE_PATHS="# only comments\n\n")

    def test_whitelist_resolved_against_cache_dir(self):
        _, _, paths = resolve(SP_CACHE_PATHS="# keep only these\n\nminion/extmods\nkeep/*.p\n")
        self.assertEqual(
            paths,
            [
                "/tmp/runner/salt-push-cache/minion/extmods",
                "/tmp/runner/salt-push-cache/keep/*.p",
            ],
        )

    def test_entries_normalized(self):
        _, _, paths = resolve(SP_CACHE_PATHS="keep/\n./minion")
        self.assertEqual(
            paths,
            ["/tmp/runner/salt-push-cache/keep", "/tmp/runner/salt-push-cache/minion"],
        )

    def test_absolute_entry_rejected(self):
        with self.assertRaises(setup_mod.ConfigError):
            resolve(SP_CACHE_PATHS="/etc/passwd")

    def test_traversal_entry_rejected(self):
        with self.assertRaises(setup_mod.ConfigError):
            resolve(SP_CACHE_PATHS="minion/../../secrets")


class MainTest(unittest.TestCase):
    def run_main(self, **overrides):
        with tempfile.NamedTemporaryFile("r", delete=False) as out:
            self.addCleanup(os.unlink, out.name)
            rc = setup_mod.main({**BASE_ENV, "GITHUB_OUTPUT": out.name, **overrides})
            return rc, out.read()

    def test_output_format(self):
        rc, output = self.run_main(SP_CACHE_PATHS="keep")
        self.assertEqual(rc, 0)
        self.assertEqual(
            output,
            "cache-dir=/tmp/runner/salt-push-cache\n"
            "key=salt-push-main-42\n"
            "cache-paths<<__SP_EOF__\n"
            "/tmp/runner/salt-push-cache/keep\n"
            "__SP_EOF__\n",
        )

    def test_caching_disabled_output(self):
        rc, output = self.run_main()
        self.assertEqual(rc, 0)
        self.assertIn("cache-paths<<__SP_EOF__\n__SP_EOF__\n", output)

    def test_multiline_paths_output(self):
        rc, output = self.run_main(SP_CACHE_PATHS="a\nb")
        self.assertEqual(rc, 0)
        self.assertIn(
            "cache-paths<<__SP_EOF__\n"
            "/tmp/runner/salt-push-cache/a\n"
            "/tmp/runner/salt-push-cache/b\n"
            "__SP_EOF__\n",
            output,
        )

    def test_config_error_exits_2_without_output(self):
        rc, output = self.run_main(SP_CACHE_PATHS="../escape")
        self.assertEqual(rc, 2)
        self.assertEqual(output, "")


if __name__ == "__main__":
    unittest.main()
