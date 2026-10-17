"""Unit tests for action/run.py — pure logic only, no Docker required.

Run with: python3 -m unittest discover -s tests
"""

import importlib.util
import os
import tempfile
import unittest

_SPEC = importlib.util.spec_from_file_location(
    "run", os.path.join(os.path.dirname(__file__), "..", "action", "run.py")
)
run = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(run)


class ParseCommandsTest(unittest.TestCase):
    def test_default_single_command(self):
        self.assertEqual(run.parse_commands("salt-call"), [("salt-call", ["salt-call"])])

    def test_blank_lines_and_comments_skipped(self):
        commands = run.parse_commands(
            "# comment\n\n   \nsalt-call test.ping\n  # indented\n"
        )
        self.assertEqual(commands, [("salt-call test.ping", ["salt-call", "test.ping"])])

    def test_quoting(self):
        [(_, argv)] = run.parse_commands("salt-call cmd.run 'touch /app/cache/a b'")
        self.assertEqual(argv, ["salt-call", "cmd.run", "touch /app/cache/a b"])

    def test_no_shell_evaluation(self):
        # Substitution, chaining and globbing stay literal arguments.
        [(_, argv)] = run.parse_commands(
            "salt-call test.ping $(touch /tmp/pwned); rm -rf *"
        )
        self.assertEqual(
            argv,
            ["salt-call", "test.ping", "$(touch", "/tmp/pwned);", "rm", "-rf", "*"],
        )

    def test_unbalanced_quote_is_config_error(self):
        with self.assertRaises(run.ConfigError):
            run.parse_commands("salt-call cmd.run 'unterminated")


class ParseEnvNamesTest(unittest.TestCase):
    def test_whitespace_and_comma_separated(self):
        self.assertEqual(
            run.parse_env_names("GH_TOKEN, OTHER\n  THIRD"),
            ["GH_TOKEN", "OTHER", "THIRD"],
        )

    def test_empty(self):
        self.assertEqual(run.parse_env_names(""), [])

    def test_value_injection_rejected(self):
        with self.assertRaises(run.ConfigError):
            run.parse_env_names("SALT_PUSH_USER=root")

    def test_flag_injection_rejected(self):
        with self.assertRaises(run.ConfigError):
            run.parse_env_names("-v")


class BuildDockerArgsTest(unittest.TestCase):
    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory()
        self.addCleanup(self.workspace.cleanup)
        self.env = {"SP_CACHE_DIR": os.path.join(self.workspace.name, "cache")}

    def build(self, **extra):
        args, _ = run.build_docker_args(
            {**self.env, **extra}, self.workspace.name, 1001, 118
        )
        return args

    def notices(self, **extra):
        _, notices = run.build_docker_args(
            {**self.env, **extra}, self.workspace.name, 1001, 118
        )
        return notices

    def mounts(self, args):
        return [args[i + 1] for i, arg in enumerate(args) if arg == "-v"]

    def test_base_args(self):
        args = self.build()
        self.assertEqual(args[:6], ["run", "--rm", "-e", "PUID=1001", "-e", "PGID=118"])
        self.assertTrue(os.path.isdir(self.env["SP_CACHE_DIR"]))
        self.assertEqual(self.mounts(args), [f"{self.env['SP_CACHE_DIR']}:/app/cache"])

    def test_absent_default_trees_skipped_with_notice(self):
        args, notices = run.build_docker_args(
            {**self.env, "SP_STATES": "srv/salt", "SP_PILLAR": "srv/pillar"},
            self.workspace.name,
            1001,
            118,
        )
        self.assertNotIn("/app/srv/salt:ro", " ".join(args))
        self.assertEqual(
            notices,
            [
                "states: default 'srv/salt' not present — skipped",
                "pillar: default 'srv/pillar' not present — skipped",
            ],
        )

    def test_present_default_trees_mounted(self):
        os.makedirs(os.path.join(self.workspace.name, "srv/salt"))
        args = self.build(SP_STATES="srv/salt", SP_PILLAR="srv/pillar")
        self.assertIn(
            f"{self.workspace.name}/srv/salt:/app/srv/salt:ro", self.mounts(args)
        )
        self.assertEqual(
            self.notices(SP_STATES="srv/salt", SP_PILLAR="srv/pillar"),
            ["pillar: default 'srv/pillar' not present — skipped"],
        )

    def test_explicit_missing_tree_is_config_error(self):
        with self.assertRaises(run.ConfigError):
            self.build(SP_STATES="typo/salt")

    def test_relative_and_absolute_paths(self):
        os.makedirs(os.path.join(self.workspace.name, "fixtures/pillar"))
        args = self.build(SP_PILLAR="fixtures/pillar")
        self.assertIn(
            f"{self.workspace.name}/fixtures/pillar:/app/srv/pillar:ro",
            self.mounts(args),
        )
        args = self.build(SP_PILLAR=os.path.join(self.workspace.name, "fixtures/pillar"))
        self.assertIn(
            f"{self.workspace.name}/fixtures/pillar:/app/srv/pillar:ro",
            self.mounts(args),
        )

    def test_ssh_and_logs_dirs_created_and_writable(self):
        args = self.build(SP_SSH_DIR="sshkeys", SP_LOGS_DIR="logs")
        for name, dest in (("sshkeys", "/app/ssh"), ("logs", "/app/logs")):
            path = os.path.join(self.workspace.name, name)
            self.assertTrue(os.path.isdir(path))
            self.assertIn(f"{path}:{dest}", self.mounts(args))

    def test_colon_in_path_is_config_error(self):
        with self.assertRaises(run.ConfigError):
            self.build(SP_SSH_DIR="a:b")

    def test_passthrough_and_env_pass(self):
        args = self.build(
            SP_FORCE_COLOR="true",
            SALT_LOG_LEVEL="debug",
            SALT_LOGFILE_LEVEL="info",
            SALT_RESOURCES="",
            SP_ENV_PASS="GH_TOKEN,OTHER",
        )
        env_flags = [args[i + 1] for i, arg in enumerate(args) if arg == "-e"]
        self.assertIn("SALT_FORCE_COLOR=true", env_flags)
        self.assertIn("SALT_LOG_LEVEL", env_flags)
        self.assertIn("SALT_LOGFILE_LEVEL", env_flags)
        self.assertNotIn("SALT_RESOURCES", env_flags)  # empty — not forwarded
        self.assertIn("GH_TOKEN", env_flags)
        self.assertIn("OTHER", env_flags)


class ValidateLogLevelsTest(unittest.TestCase):
    def test_valid_and_unset_pass(self):
        run.validate_log_levels({"SALT_LOG_LEVEL": "debug", "SALT_LOGFILE_LEVEL": ""})
        run.validate_log_levels({})

    def test_typo_is_config_error(self):
        with self.assertRaises(run.ConfigError) as ctx:
            run.validate_log_levels({"SALT_LOG_LEVEL": "warn"})
        self.assertIn("log-level 'warn'", str(ctx.exception))

    def test_file_level_validated(self):
        with self.assertRaises(run.ConfigError) as ctx:
            run.validate_log_levels({"SALT_LOGFILE_LEVEL": "verbose"})
        self.assertIn("log-file-level 'verbose'", str(ctx.exception))


class DescribeConfigTest(unittest.TestCase):
    def test_names_only_no_values(self):
        args = ["run", "--rm", "-e", "PUID=1001", "-e", "GH_TOKEN", "-v", "/a:/app/cache"]
        lines = run.describe_config(
            "img:tag", "img@sha256:abc", "never", args, ["a notice"]
        )
        self.assertEqual(
            lines,
            [
                "image: img:tag (img@sha256:abc)",
                "pull policy: never",
                "container env: PUID GH_TOKEN",
                "mount: /a:/app/cache",
                "a notice",
            ],
        )


class ImageIdentityTest(unittest.TestCase):
    class Result:
        def __init__(self, returncode, stdout=""):
            self.returncode = returncode
            self.stdout = stdout

    def test_digest_preferred(self):
        identity = run.image_identity(
            "img", run=lambda *a, **k: self.Result(0, "sha256:id repo@sha256:digest\n")
        )
        self.assertEqual(identity, "repo@sha256:digest")

    def test_id_fallback_for_local_images(self):
        identity = run.image_identity(
            "img", run=lambda *a, **k: self.Result(0, "sha256:id \n")
        )
        self.assertEqual(identity, "sha256:id")

    def test_unknown_on_inspect_failure(self):
        self.assertEqual(
            run.image_identity("img", run=lambda *a, **k: self.Result(1)), "unknown"
        )


class FormatDurationTest(unittest.TestCase):
    def test_seconds(self):
        self.assertEqual(run.format_duration(3.21), "3.2s")

    def test_minutes(self):
        self.assertEqual(run.format_duration(83.4), "1m23s")


class FormatSummaryTest(unittest.TestCase):
    def result(self, line, rc, start=0, end=0, duration=1.0):
        return {
            "line": line,
            "rc": rc,
            "start": start,
            "end": end,
            "duration": duration,
        }

    def test_statuses_and_skipped(self):
        log = b"pingfail"
        summary = run.format_summary(
            [
                self.result("salt-call test.ping", 0, 0, 4),
                self.result("salt-call state.apply fail", 2, 4, 8),
                self.result("salt-call never.ran", None),
            ],
            log,
        )
        self.assertIn("| <code>salt-call test.ping</code> | ✅ | 1.0s |", summary)
        self.assertIn(
            "| <code>salt-call state.apply fail</code> | ❌ exit 2 | 1.0s |", summary
        )
        self.assertIn("| <code>salt-call never.ran</code> | ⏭ skipped | — |", summary)
        self.assertIn("<summary>✅ <code>salt-call test.ping</code></summary>", summary)
        self.assertIn("ping", summary)
        # skipped commands get no details block
        self.assertNotIn("<summary>⏭", summary)
        self.assertEqual(summary.count("<details>"), 2)

    def test_output_ansi_stripped(self):
        log = b"\x1b[0;32mSucceeded: 1\x1b[0;0m"
        summary = run.format_summary([self.result("salt-call", 0, 0, len(log))], log)
        self.assertIn("Succeeded: 1", summary)
        self.assertNotIn("\x1b", summary)

    def test_tail_truncation(self):
        log = (b"x" * run.SUMMARY_LIMIT) + b"THE-END"
        summary = run.format_summary([self.result("salt-call", 0, 0, len(log))], log)
        self.assertIn("… (earlier output truncated)", summary)
        self.assertIn("THE-END", summary)

    def test_table_cells_escaped(self):
        summary = run.format_summary(
            [self.result("salt-call cmd.run 'a | b <x>'", None)], b""
        )
        self.assertIn("&#124;", summary)
        self.assertIn("&lt;x&gt;", summary)


class FakeResult:
    def __init__(self, returncode):
        self.returncode = returncode


class EnsureImageTest(unittest.TestCase):
    def fake_run(self, inspect_rc, pull_rc, calls):
        def runner(argv, **_kwargs):
            calls.append(argv[1])
            return FakeResult(inspect_rc if argv[1] == "image" else pull_rc)

        return runner

    def test_always_pulls(self):
        calls = []
        run.ensure_image("img", "always", run=self.fake_run(0, 0, calls))
        self.assertEqual(calls, ["pull"])

    def test_always_pull_failure_is_config_error(self):
        with self.assertRaises(run.ConfigError):
            run.ensure_image("img", "always", run=self.fake_run(0, 1, []))

    def test_missing_skips_pull_when_present(self):
        calls = []
        run.ensure_image("img", "missing", run=self.fake_run(0, 1, calls))
        self.assertEqual(calls, ["image"])

    def test_missing_pulls_when_absent(self):
        calls = []
        run.ensure_image("img", "missing", run=self.fake_run(1, 0, calls))
        self.assertEqual(calls, ["image", "pull"])

    def test_never_requires_local_image(self):
        run.ensure_image("img", "never", run=self.fake_run(0, 1, []))
        with self.assertRaises(run.ConfigError):
            run.ensure_image("img", "never", run=self.fake_run(1, 0, []))

    def test_invalid_policy_is_config_error(self):
        with self.assertRaises(run.ConfigError):
            run.ensure_image("img", "sometimes", run=self.fake_run(0, 0, []))


class AnsiStripTest(unittest.TestCase):
    def test_color_codes_stripped(self):
        self.assertEqual(
            run.ANSI_COLOR.sub("", "\x1b[0;32mSucceeded: 1\x1b[0;0m"), "Succeeded: 1"
        )


if __name__ == "__main__":
    unittest.main()
