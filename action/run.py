#!/usr/bin/env python3
"""Runner for the salt-push composite action.

All inputs arrive via SP_*/SALT_*/PYTHON_PACKAGES environment variables set
in action.yml. Everything up to the docker invocation is pure argument
construction, kept in small functions so it can be unit-tested without
Docker (tests/test_run.py).
"""

import html
import json
import os
import re
import secrets
import shlex
import shutil
import subprocess
import sys
import time

ENV_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
ANSI_COLOR = re.compile(r"\x1b\[[0-9;]*m")
# Container env passed through verbatim when set. Bare -e NAME: docker reads
# the value from its own environment, it never appears in the argument list.
PASSTHROUGH_VARS = (
    "SALT_PILLAR",
    "SALT_RESOURCES",
    "SALT_ROSTER",
    "SALT_MINION_CONFIG",
    "SALT_SSH_CONFIG",
    "SALT_LOG_LEVEL",
    "SALT_LOGFILE_LEVEL",
    "SALT_PUSH_USER",
    "PYTHON_PACKAGES",
)
LOG_LEVELS = (
    "all",
    "garbage",
    "trace",
    "debug",
    "profile",
    "info",
    "warning",
    "error",
    "critical",
    "quiet",
)
LOG_LEVEL_INPUTS = {
    "SALT_LOG_LEVEL": "log-level",
    "SALT_LOGFILE_LEVEL": "log-file-level",
}
SUMMARY_LIMIT = 100_000
# Where the container drops each command's job return (results input);
# lives in the always-mounted cache dir, read and removed after each command.
RESULT_FILE = ".salt-push-result.json"
# GitHub rejects step outputs above 1 MB
OUTPUT_LIMIT = 1_000_000


class ConfigError(Exception):
    """Input/environment problem — reported as ::error:: and exit code 2."""


def parse_commands(text):
    """Split the commands input into (line, argv) pairs.

    Lines are split with shell quoting rules but never evaluated: no
    variable expansion, command substitution or globbing. Blank lines and
    '#' comments are skipped.
    """
    commands = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        try:
            argv = shlex.split(line)
        except ValueError as err:
            raise ConfigError(f"cannot parse command line ({err}): {line}") from err
        commands.append((line, argv))
    return commands


def parse_env_names(value):
    """Split env-pass on whitespace/commas and validate each name."""
    names = [name for name in re.split(r"[\s,]+", value) if name]
    for name in names:
        if not ENV_NAME.match(name):
            raise ConfigError(f"invalid environment variable name in env-pass: '{name}'")
    return names


def validate_log_levels(env):
    """Fail fast on log level typos instead of leaving them to Salt."""
    for var, input_name in LOG_LEVEL_INPUTS.items():
        value = env.get(var)
        if value and value not in LOG_LEVELS:
            raise ConfigError(
                f"invalid {input_name} '{value}' (expected one of: {', '.join(LOG_LEVELS)})"
            )


def resolve_host_path(value, workspace):
    """Resolve an input path against the workspace; ':' would break -v syntax."""
    path = value if os.path.isabs(value) else os.path.join(workspace, value)
    if ":" in path:
        raise ConfigError(f"path '{value}' contains ':' and cannot be bind-mounted")
    return path


def build_docker_args(env, workspace, uid, gid):
    """Construct the docker arguments between 'run' and the image name.

    Creates the writable mount sources (ssh-dir, logs-dir, cache-dir) as a
    side effect; read-only sources must exist unless they are an unchanged,
    absent default tree. Returns (args, notices), where notices are
    human-readable remarks for the configuration log group.
    """
    args = ["run", "--rm", "-e", f"PUID={uid}", "-e", f"PGID={gid}"]
    notices = []
    if env.get("SP_FORCE_COLOR") == "true":
        args.extend(["-e", "SALT_FORCE_COLOR=true"])
    # A results-filter alone implies results collection (cache-paths style)
    if env.get("SP_RESULTS") == "true" or env.get("SP_RESULTS_FILTER"):
        args.extend(["-e", f"SALT_RESULT_FILE=/app/cache/{RESULT_FILE}"])
    if env.get("SP_SCRUB_CACHE") == "true":
        # defer: write-avoidance config per command (returner drop,
        # ssh_wipe), but the cache removal runs once after the last
        # command — main() invokes the entrypoint's `scrub` verb, which
        # also covers fail-fast exits before the final command.
        args.extend(["-e", "SALT_SCRUB_CACHE=defer"])
    for var in PASSTHROUGH_VARS:
        if env.get(var):
            args.extend(["-e", var])
    for name in parse_env_names(env.get("SP_ENV_PASS", "")):
        args.extend(["-e", name])

    def host_path(value):
        return resolve_host_path(value, workspace)

    def mount_ro(value, dest):
        path = host_path(value)
        if not os.path.exists(path):
            raise ConfigError(f"path '{value}' does not exist")
        args.extend(["-v", f"{path}:{dest}:ro"])

    def mount_tree(value, dest, default, label):
        # Trees are optional: the unchanged default is skipped when absent,
        # an explicitly set path must exist (defaults mirror action.yml).
        if not value:
            return
        if value == default and not os.path.exists(host_path(value)):
            notices.append(f"{label}: default '{value}' not present — skipped")
            return
        mount_ro(value, dest)

    mount_tree(env.get("SP_STATES", ""), "/app/srv/salt", "srv/salt", "states")
    mount_tree(env.get("SP_PILLARS", ""), "/app/srv/pillar", "srv/pillar", "pillars")
    for var, dest in (
        ("SP_ROSTER_FILE", "/app/roster"),
        ("SP_MINION_CONFIG_DIR", "/app/config/minion.d"),
        ("SP_SSH_CONFIG_DIR", "/app/config/ssh.d"),
    ):
        if env.get(var):
            mount_ro(env[var], dest)
    for var, dest in (("SP_SSH_DIR", "/app/ssh"), ("SP_LOGS_DIR", "/app/logs")):
        if env.get(var):
            path = host_path(env[var])
            os.makedirs(path, exist_ok=True)
            args.extend(["-v", f"{path}:{dest}"])
    cache = host_path(env["SP_CACHE_DIR"])
    os.makedirs(cache, exist_ok=True)
    args.extend(["-v", f"{cache}:/app/cache"])
    return args, notices


def ensure_image(image, mode, run=subprocess.run):
    """Apply the pull policy: always (default), missing or never."""

    def present():
        return (
            run(
                ["docker", "image", "inspect", image],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            ).returncode
            == 0
        )

    if mode == "always":
        if run(["docker", "pull", image]).returncode != 0:
            raise ConfigError(f"failed to pull image '{image}'")
    elif mode == "missing":
        if not present() and run(["docker", "pull", image]).returncode != 0:
            raise ConfigError(f"failed to pull image '{image}'")
    elif mode == "never":
        if not present():
            raise ConfigError(
                f"image '{image}' is not present locally and pull is 'never'"
            )
    else:
        raise ConfigError(
            f"invalid pull policy '{mode}' (expected always, missing or never)"
        )


def image_identity(image, run=subprocess.run):
    """Return the image's repo digest (preferred) or content id, for the
    configuration log — a forensic record of what actually ran."""
    # range instead of join: RepoDigests is []interface{} on some docker
    # versions, which join rejects
    proc = run(
        [
            "docker",
            "image",
            "inspect",
            "--format",
            "{{.Id}}{{range .RepoDigests}} {{.}}{{end}}",
            image,
        ],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        return "unknown"
    parts = proc.stdout.split()
    if len(parts) > 1:
        return parts[1]
    return parts[0] if parts else "unknown"


def describe_config(image, identity, pull, args, notices):
    """Human-readable resolved configuration. Contains env var *names* only
    — never forwarded values."""
    lines = [f"image: {image} ({identity})", f"pull policy: {pull}"]
    env_names = [
        args[i + 1].split("=", 1)[0] for i, arg in enumerate(args) if arg == "-e"
    ]
    lines.append("container env: " + " ".join(env_names))
    for i, arg in enumerate(args):
        if arg == "-v":
            lines.append(f"mount: {args[i + 1]}")
    lines.extend(notices)
    return lines


def format_duration(seconds):
    if seconds >= 60:
        minutes, secs = divmod(int(seconds), 60)
        return f"{minutes}m{secs:02d}s"
    return f"{seconds:.1f}s"


def format_summary(results, log_bytes):
    """Render the job summary: a per-command status table, then each
    executed command's output in a collapsible, tail-truncated block."""

    def code(line):
        return f"<code>{html.escape(line)}</code>".replace("|", "&#124;")

    def status(result):
        return "✅" if result["rc"] == 0 else f"❌ exit {result['rc']}"

    executed = [result for result in results if result["rc"] is not None]
    cap = SUMMARY_LIMIT // max(len(executed), 1)
    parts = ["## salt-push", "", "| Command | Result | Duration |", "|---|---|---|"]
    for result in results:
        if result["rc"] is None:
            parts.append(f"| {code(result['line'])} | ⏭ skipped | — |")
        else:
            parts.append(
                f"| {code(result['line'])} | {status(result)}"
                f" | {format_duration(result['duration'])} |"
            )
    for result in executed:
        text = ANSI_COLOR.sub(
            "", log_bytes[result["start"] : result["end"]].decode("utf-8", "replace")
        ).strip("\n")
        parts.extend(
            [
                "",
                "<details>",
                f"<summary>{status(result)} {code(result['line'])}</summary>",
                "",
            ]
        )
        parts.append("````")
        if len(text) > cap:
            parts.append("… (earlier output truncated)")
            text = text[-cap:]
        parts.append(text)
        parts.extend(["````", "</details>"])
    return "\n".join(parts) + "\n"


def validate_results_filter(expression, run=subprocess.run, which=shutil.which):
    """Fail fast on results-filter problems: jq missing or a jq compile
    error (exit 3), before any command runs. Runtime behavior against null
    input is not meaningful, so other exit codes pass."""
    if not expression:
        return
    if which("jq") is None:
        raise ConfigError("results-filter requires jq on the runner")
    proc = run(["jq", "-n", "-c", expression], capture_output=True, text=True)
    if proc.returncode == 3:
        raise ConfigError(f"invalid results-filter jq expression: {proc.stderr.strip()}")


def apply_results_filter(expression, result, run=subprocess.run):
    """Transform one command's result with the jq expression. A runtime
    error yields None with a warning — the command itself succeeded, a
    transform typo must not fail the run after states were applied."""
    proc = run(
        ["jq", "-c", expression],
        input=json.dumps(result),
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        print(
            f"::warning::salt-push: results-filter failed: {proc.stderr.strip()}",
            flush=True,
        )
        return None
    values = [json.loads(line) for line in proc.stdout.splitlines()]
    if len(values) == 1:
        return values[0]
    return values or None


def read_result(path):
    """Read and remove the result file the container wrote for one command
    (results input). None when the container never wrote it."""
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


def run_command(docker_args, image, argv, log):
    """Run one container, streaming output to stdout and the log file."""
    proc = subprocess.Popen(
        ["docker", *docker_args, image, *argv],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    for chunk in iter(lambda: proc.stdout.read(8192), b""):
        sys.stdout.buffer.write(chunk)
        sys.stdout.buffer.flush()
        log.write(chunk)
    return proc.wait()


def fail(message):
    print(f"::error::salt-push: {message}", flush=True)
    return 2


def main(env=os.environ):
    pull = env.get("SP_PULL") or "always"
    try:
        commands = parse_commands(env["SP_COMMANDS"])
        if shutil.which("docker") is None:
            raise ConfigError("a Linux runner with Docker is required")
        validate_log_levels(env)
        validate_results_filter(env.get("SP_RESULTS_FILTER", ""))
        docker_args, notices = build_docker_args(
            env, env["GITHUB_WORKSPACE"], os.getuid(), os.getgid()
        )
        ensure_image(env["SP_IMAGE"], pull)
    except ConfigError as err:
        return fail(str(err))

    print("::group::salt-push: configuration", flush=True)
    identity = image_identity(env["SP_IMAGE"])
    for line in describe_config(env["SP_IMAGE"], identity, pull, docker_args, notices):
        print(line, flush=True)
    print("::endgroup::", flush=True)

    rc = 0
    failed = ""
    results = [
        {"line": line, "rc": None, "start": 0, "end": 0, "duration": 0.0}
        for line, _ in commands
    ]
    results_filter = env.get("SP_RESULTS_FILTER", "")
    collect = env.get("SP_RESULTS") == "true" or bool(results_filter)
    command_results = []
    result_path = os.path.join(
        resolve_host_path(env["SP_CACHE_DIR"], env["GITHUB_WORKSPACE"]), RESULT_FILE
    )
    if collect:
        # A restored cache ('.') may carry a stale result file from an
        # earlier run; the container rewrites it, but not if it dies first.
        read_result(result_path)
    log_path = os.path.join(env["RUNNER_TEMP"], "salt-push-output.log")
    with open(log_path, "wb") as log:
        for result, (line, argv) in zip(results, commands, strict=True):
            print(f"::group::salt-push: {line}", flush=True)
            # Container output is untrusted: suspend workflow command
            # processing while it streams.
            guard = secrets.token_hex(16)
            print(f"::stop-commands::{guard}", flush=True)
            result["start"] = log.tell()
            started = time.monotonic()
            rc = run_command(docker_args, env["SP_IMAGE"], argv, log)
            result["duration"] = time.monotonic() - started
            result["end"] = log.tell()
            result["rc"] = rc
            print(f"::{guard}::", flush=True)
            print("::endgroup::", flush=True)
            if collect:
                result = read_result(result_path)
                if results_filter:
                    result = apply_results_filter(results_filter, result)
                command_results.append({"command": line, "result": result})
            if rc != 0:
                failed = line
                print(
                    f"::error::salt-push: command failed (exit {rc}): {line}",
                    flush=True,
                )
                break

    if env.get("SP_SCRUB_CACHE") == "true":
        # One scrub for the whole sequence (the commands ran with
        # SALT_SCRUB_CACHE=defer), before the cache save step.
        proc = subprocess.run(
            ["docker", *docker_args, env["SP_IMAGE"], "scrub"],
            check=False,
            capture_output=True,
            text=True,
        )
        if proc.returncode != 0:
            print(
                f"::warning::salt-push: cache scrub failed: {proc.stderr.strip()}",
                flush=True,
            )

    with open(env["GITHUB_OUTPUT"], "a", encoding="utf-8") as out:
        out.write(f"exit-code={rc}\nfailed-command={failed}\n")
        if collect:
            # Compact separators keep it small and single-line (json.dumps
            # escapes control characters inside strings).
            payload = json.dumps(command_results, separators=(",", ":"))
            if len(payload) > OUTPUT_LIMIT:
                print(
                    "::warning::salt-push: results output exceeds GitHub's"
                    " 1 MB step output limit and may be dropped",
                    flush=True,
                )
            out.write(f"results={payload}\n")
    if env.get("SP_SUMMARY") == "true":
        with open(log_path, "rb") as log:
            log_bytes = log.read()
        with open(env["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as summary:
            summary.write(format_summary(results, log_bytes))
    return rc


if __name__ == "__main__":
    sys.exit(main())
