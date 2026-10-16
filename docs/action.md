# The GitHub Action

`uses: lkubb/salt-push@v1` is a composite action wrapping the
[container](container.md). It mounts paths from the checked-out repository into
the container and runs one or more commands sequentially (fail-fast), applying
a highstate by default.

**Prerequisites**: a Linux runner with Docker (e.g. `ubuntu-24.04`) and a prior
`actions/checkout` step — paths are resolved relative to the workspace
(absolute paths are allowed too).

## Examples

The minimal case — apply a highstate from `./srv/{salt,pillar}`:

```yaml
steps:
  - uses: actions/checkout@v7
  - uses: lkubb/salt-push@v1
```

A fuller example — applying an org-config repo (states + pillar in `srv/`)
with [saltext-github](https://github.com/salt-extensions/saltext-github):

```yaml
jobs:
  apply:
    runs-on: ubuntu-24.04
    concurrency: org-apply  # never run two applies at once
    steps:
      - uses: actions/checkout@v7

      - name: Apply org configuration
        uses: lkubb/salt-push@v1
        env:
          APP_CLID: ${{ vars.ORG_CLID }}
          APP_PRIV: ${{ secrets.ORG_APP_KEY }}
        with:
          env-pass: APP_CLID APP_PRIV
          # setting cache-paths enables caching; whitelist what persists —
          # cached data is restorable by fork PR workflows on public repos
          # (see Security considerations)
          cache-paths: |
            minion/extmods
          summary: 'true'
```

On pull requests, surface the predicted changes for review instead:

```yaml
        with:
          env-pass: APP_CLID APP_PRIV
          commands: salt-call state.highstate test=True
```

## Inputs

| Input | Default | Purpose |
|---|---|---|
| `image` | `ghcr.io/lkubb/salt-push:latest` | container image (full reference) |
| `pull` | `always` | image pull policy: `always`, `missing` or `never` |
| `commands` | `salt-call` | one command per line, sequential, fail-fast; blank lines and `#` comments skipped; shell-style quoting, but no evaluation |
| `states` | `srv/salt` | state tree → `/app/srv/salt` (ro); the default is skipped if absent, a set path must exist, `''` disables |
| `pillar` | `srv/pillar` | pillar tree → `/app/srv/pillar` (ro); same semantics as `states` |
| `roster` | — | roster file → `/app/roster` (ro) |
| `ssh-dir` | — | directory → `/app/ssh` (rw, created if missing); holds the salt-ssh private key |
| `minion-config` | — | drop-in directory → `/app/config/minion.d` (ro) |
| `ssh-config` | — | drop-in directory → `/app/config/ssh.d` (ro) |
| `cache-dir` | `<runner temp>/salt-push-cache` | host directory → `/app/cache` (rw, always mounted, created if missing); defaults to outside the checked-out repo so cache contents stay clear of the workspace |
| `cache-paths` | — | **enables caching when set**: whitelist of paths persisted via `actions/cache` (one per line, relative to `cache-dir`, globs allowed; restored before, saved after the commands — even on failure); `'.'` persists the whole `cache-dir` |
| `cache-key` | `salt-push-<ref>-<run id>` | cache entries are immutable, hence a per-run default key |
| `cache-restore-keys` | `salt-push-` | prefix fallback(s) for restore; `''` restores exact `cache-key` matches only |
| `env-pass` | — | whitespace/comma-separated env var **names** forwarded into the container (set the values on the step's `env:`) |
| `salt-resources` | — | → `SALT_RESOURCES` (inline resource declarations) |
| `salt-roster` | — | → `SALT_ROSTER` (inline roster) |
| `log-level` | — | → `SALT_LOG_LEVEL` (console; container default `warning`) |
| `log-file-level` | — | → `SALT_LOGFILE_LEVEL` (file logs in `logs-dir`; container default `info`) |
| `logs-dir` | — | directory → `/app/logs` (rw, created if missing): Salt's file logs, e.g. for artifact upload on failure |
| `force-color` | `'true'` | → `SALT_FORCE_COLOR` |
| `user` | — | → `SALT_PUSH_USER` (e.g. `root`) |
| `python-packages` | — | → `PYTHON_PACKAGES` (runtime install — slow; prefer [baking](container.md#baking-python-packages-at-build-time)) |
| `summary` | `'false'` | `'true'` appends a per-command status table (result, duration) with collapsible, tail-truncated ANSI-stripped output (~100 KB total) to the job summary |

## Outputs

| Output | Purpose |
|---|---|
| `exit-code` | exit code of the failing command, `0` if all succeeded |
| `failed-command` | the command line that failed (empty on success) |

Outputs are written even when the action fails, so they are readable with
`continue-on-error: true` on the step. Salt's human-readable output is not
parsed any further — use `--out=json` in your command if you need structured
results.

## Behavior notes

- `commands:` lines are split with shell quoting rules, so quoted arguments
  work (`salt-call cmd.run 'echo hi'`) — but they are **never evaluated**: no
  variable expansion, command substitution or globbing, and nothing runs on
  the runner itself. All lines are parsed up front, so a quoting error fails
  the run before any command executes.
- Secrets travel as environment variables: set them on the step's `env:` and
  list the names in `env-pass`. Only the names appear in the docker argv.
  Names are validated; values (`NAME=value`) are rejected.
- Both trees are optional. A run without them — salt-ssh-only, or resources
  declared via `salt-resources` — needs no extra configuration: the default
  paths are simply skipped when they don't exist.

## Security considerations

- **Caches are readable across the repo.** GitHub restores cache entries by
  branch scope (current branch → base branch → default branch) — the cache
  *key* is not an access boundary, and on public repos even fork PR workflows
  can restore entries saved on the base/default branch, using any key they
  like. Environments don't change this: they gate secrets, not caches. The
  salt-push cache can contain sensitive rendered data (salt-ssh in
  particular stores state archives and job returns with pillar values
  substituted in under `master/`, with no config switch to prevent it), so
  leave caching disabled (the default) on public repos unless the cached
  content is harmless. The same scoping also prevents the reverse: a PR
  cannot poison the default branch's cache.
- **`cache-mode` does not restrict who can read your caches.** The
  workflow-level [`cache-mode`](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#cache-mode)
  setting governs a run's *own* cache I/O and only exists as workflow syntax
  — a fork PR's workflow is the attacker's own file declaring its own mode,
  so it cannot serve as an access control on your entries. It is still good
  hygiene: set `cache-mode: none` on jobs that don't cache, and note that
  low-trust triggers (`pull_request_target`, `workflow_run`, …) now default
  to read-only. Beware that under `cache-mode: read`/`none` this action's
  cache restore/save steps are silently skipped by the runner even when
  `cache-paths` is set.
- **Caching is opt-in and whitelisted by design.** Enabling it means naming
  paths in `cache-paths` — there is no cache-everything default, and `'.'`
  (whole `cache-dir`) is an explicit choice best reserved for private repos.
  Treat every listed path as *published*: the whitelist is a filter, not a
  scanner — a state that writes secrets into a whitelisted path still
  publishes them, so keep the list narrow and auditable. Combine with
  `cache-restore-keys: ''` so secret-bearing runs only ever restore their
  own exact per-run entry, never a stale one. The cache save tolerates
  missing whitelisted paths (a run that produces none saves nothing, with a
  warning instead of a failure).
- **Salt output can leak secrets.** State `changes:` diffs print rendered
  content — a state writing a token into a file shows it in the log, and
  `summary: 'true'` copies it into the job summary. The same goes for
  Salt's file logs captured via `logs-dir`: at `debug` level they include
  rendered states and pillar values, so treat uploaded log artifacts as
  sensitive. GitHub only masks
  *registered* secret values, not data derived inside the container. For
  states that handle sensitive data, set e.g. `show_changes: False` on
  `file.managed` or keep secret-bearing values out of diffs. Values from the
  `secrets` context (and tokens minted by `create-github-app-token`) are
  already runner-masked. Register a known-sensitive value from elsewhere
  explicitly before the action runs:
  `echo "::add-mask::${VALUE}"`. The action deliberately does *not*
  auto-mask pillar values — masking is exact-string only (reformatted or
  multiline secrets slip through regardless), and registering
  attacker-influenced pillar strings as masks would let a malicious PR
  censor the very preview logs a reviewer inspects.
- **Container output cannot issue workflow commands.** It is streamed inside
  a `::stop-commands::` guard, so state/pillar content can't fake
  annotations or mask log lines.
- The default pull policy `always` matters on **self-hosted runners** with a
  persistent Docker daemon: with `missing`, any earlier job could pre-seed a
  malicious image under the expected tag. Only use `missing`/`never` with
  locally built images you control.
- The default `cache-dir` lives under the runner's temp dir rather than the
  workspace.
- `ssh-dir` holds the auto-generated salt-ssh **private key**. Prefer
  pre-provisioning a key from a secret over caching this directory — and
  better yet, mint short-lived SSH certificates on demand.
- For reproducible runs, pin both layers: `uses: lkubb/salt-push@<commit sha>`
  and `image:` with a digest (`ghcr.io/lkubb/salt-push@sha256:…`).
