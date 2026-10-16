#!/usr/bin/env python3
"""Pre-run resolver for the salt-push composite action.

Computes the effective cache directory, cache key and the list of paths
handed to actions/cache (the cache-paths whitelist, or the whole cache
directory) and writes them to GITHUB_OUTPUT for the other composite steps.
Pure logic lives in resolve() for unit testing (tests/test_setup.py).
"""

import os
import sys


class ConfigError(Exception):
    """Input problem — reported as ::error:: and exit code 2."""


def resolve(env):
    """Return (cache_dir, cache_key, cache_paths) from the SP_* inputs.

    A non-empty cache-paths input enables caching, so an empty path list is
    only valid when the input is empty too — the cache steps are skipped
    entirely then. '.' persists the whole cache dir.
    """
    cache_dir = env.get("SP_CACHE_DIR") or os.path.join(env["RUNNER_TEMP"], "salt-push-cache")
    key = env.get("SP_CACHE_KEY") or "salt-push-{}-{}".format(
        env["SP_REF_NAME"], env["SP_RUN_ID"]
    )
    raw = env.get("SP_CACHE_PATHS", "")
    paths = []
    for raw_line in raw.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if os.path.isabs(line) or ".." in line.split("/"):
            raise ConfigError(
                f"cache-paths entries must be relative to cache-dir, without '..': {line}"
            )
        paths.append(os.path.normpath(os.path.join(cache_dir, line)))
    if raw and not paths:
        raise ConfigError("cache-paths is set but contains no path entries")
    return cache_dir, key, paths


def main(env=os.environ):
    try:
        cache_dir, key, paths = resolve(env)
    except ConfigError as err:
        print(f"::error::salt-push: {err}", flush=True)
        return 2
    with open(env["GITHUB_OUTPUT"], "a", encoding="utf-8") as out:
        out.write(f"cache-dir={cache_dir}\n")
        out.write(f"key={key}\n")
        out.write("cache-paths<<__SP_EOF__\n")
        for path in paths:
            out.write(path + "\n")
        out.write("__SP_EOF__\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
