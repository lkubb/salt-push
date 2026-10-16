# salt-push

A thin derivative of [`cdalvaro/docker-salt-master`](https://github.com/cdalvaro/docker-salt-master)
for running Salt **in push mode** — think Ansible-style: run it from anywhere (CI, your
laptop), it pushes changes out to targets, nothing long-running anywhere. Targets can be
remote hosts (`salt-ssh`) or API-backed resources such as a GitHub org through
[saltext-github](https://github.com/salt-extensions/saltext-github), cloud providers, DNS, …

It adds a **one-shot mode** on top of the upstream image: run `salt-call`, `salt` or
`salt-ssh` against a mounted state tree and exit with a meaningful return code. Built for CI
(e.g. applying declarative configuration from a git repo via GitHub Actions), while the image
remains a drop-in replacement for upstream — the master/API functionality is untouched.

```console
$ docker run --rm -it \
    -v "$PWD/srv:/app/srv:ro" \
    ghcr.io/lkubb/salt-push:3008.3 salt-call state.apply test=True

$ docker run --rm -it \
    -v "$PWD/srv:/app/srv:ro" \
    ghcr.io/lkubb/salt-push:3008.3 salt 'myorg/*' state.apply repo_config

$ docker run --rm -it \
    -v "$PWD/srv:/app/srv:ro" \
    -v "$PWD/roster:/app/roster:ro" \
    ghcr.io/lkubb/salt-push:3008.3 salt-ssh web1 test.ping
```

## Usage

```
docker run [docker options] <image> salt-call [salt-call args...]
docker run [docker options] <image> salt [-E|-L|-G|-P|-C|-T] <target> [args...]
docker run [docker options] <image> salt-ssh <target> [salt-ssh args...]
```

The first argument selects the mode; everything after it is passed to the tool verbatim —
the command line reads just like running the tool directly.

- **`salt-call`** always runs with `--local --retcode-passthrough`, so failed states yield a
  non-zero container exit code (`2` for failed states, `1` for errors) — CI goes red when
  the apply breaks. With no further arguments, it runs `state.highstate`.
- **`salt`** dispatches to **managed resources** (`salt-call -r`): targets declared under
  the `resources:` pillar key — e.g. repositories exposed by
  [saltext-github](https://github.com/salt-extensions/saltext-github) — plus the managing
  minion itself, with per-target output like the real `salt` CLI. The familiar targeting
  shorthands are translated when leading the target expression:

  | Shorthand | `--tgt-type` |
  |---|---|
  | `-E`, `--pcre` | `pcre` |
  | `-L`, `--list` | `list` |
  | `-G`, `--grain` | `grain` |
  | `-P`, `--grain-pcre` | `grain_pcre` |
  | `-C`, `--compound` | `compound` |
  | `-T`, `--type` | by resource type: `-T <type>[:<id>]` becomes `--tgt 'T@<type>[:<id>]' --tgt-type compound`, targeting only resources (not the managing minion). Replaces upstream's `--make-token`, which is meaningless without a master |

  ```console
  $ docker run ... <image> salt '*' test.ping
  $ docker run ... <image> salt -L repo1,repo2 state.apply repo_config
  $ docker run ... <image> salt -T github state.apply repo_config
  $ docker run ... <image> salt -T github:myorg/myrepo test.ping
  ```

  Target types without `-r` support (nodegroup, ipcidr, pillar, range) are not translated.
  Note that when only a single target matches, the result is printed bare instead of keyed
  per target (matching `salt-call -r` semantics).

  To inspect what is targetable, the image ships a small `resource` execution module —
  the minion-side counterpart to Salt's `resource` runner (candidate for upstreaming).
  Where the runner reads the master's grains cache, these render live:

  ```console
  $ docker run ... <image> salt-call resource.list             # {type: [ids]}
  $ docker run ... <image> salt-call resource.list type=github
  $ docker run ... <image> salt-call resource.types
  $ docker run ... <image> salt-call resource.list_grains      # {type:id: grains summary}
  $ docker run ... <image> salt-call resource.show_grains type=github id=myorg/myrepo
  ```

- **`salt-ssh`** gets a generated master config pointing at the mounted state/pillar trees
  and the roster at `/app/roster` (or inline via `SALT_ROSTER`). The client key
  (`/app/ssh/salt-ssh.rsa`, auto-generated on first use) and `/app/ssh/known_hosts` live in
  `/app/ssh` — mount it (writable) to keep a stable identity and host trust across runs;
  treat it as a secret, it holds a private key. Everything (`ssh_priv`, `roster_file`, …)
  can be overridden via master config drop-ins in `/app/config/ssh.d/*.conf` or CLI flags.
- All modes run as the **`salt` user** (like upstream's salt-master), remapped to
  `PUID`/`PGID` when set. Set `SALT_PUSH_USER=root` for operations that need root inside
  the container.
- Running the image **without a command** prints this usage help and exits non-zero (so a
  CI job that lost its command fails loudly); `help`/`-h`/`--help` print it with exit 0.
- Any other first argument falls through to the
  [upstream entrypoint](https://github.com/cdalvaro/docker-salt-master#usage)
  unchanged (`app:help`, arbitrary commands, …). Unlike upstream, starting a salt-master
  requires an explicit `app:start` — it is no longer the default command.
  Note that `docker exec` into a running container bypasses the entrypoint entirely and
  always runs the plain binaries (as in upstream's examples).

### Mounts

| Container path | Purpose |
|---|---|
| `/app/srv/salt` | `file_roots` base (state tree); read-only is fine |
| `/app/srv/pillar` | `pillar_roots` base; read-only is fine |
| `/app/config/minion.d/*.conf` | minion config drop-ins (`salt-call`/`salt` modes) — override anything the generated config sets |
| `/app/config/ssh.d/*.conf` | master config drop-ins (`salt-ssh` mode) |
| `/app/roster` | salt-ssh roster |
| `/app/ssh` | salt-ssh client key (`salt-ssh.rsa`, auto-generated) + `known_hosts` — mount writable to persist identity and host trust; contains a private key |
| `/app/cache` | caches, kept separate per tool (`minion/` incl. `extension_modules`, `master/` for salt-ssh) — mount to persist across runs |
| `/app/logs` | optional: file logs (`logs/{minion,ssh}`) for debugging |

### Environment variables (one-shot modes)

| Variable | Default | Purpose |
|---|---|---|
| `SALT_PUSH_USER` | `salt` | user the tool runs as; set `root` to skip dropping privileges |
| `PUID` / `PGID` | `1000` | remap the `salt` user's UID/GID (e.g. to match a CI runner's workspace ownership) |
| `SALT_MINION_ID` | `salt-push` | minion `id` (stable by default so cache keys don't churn with container hostnames) |
| `SALT_LOG_LEVEL` | `warning` | console log level (what CI captures) |
| `SALT_LEVEL_LOGFILE` | `info` | file log level |
| `SALT_FORCE_COLOR` | unset | `true` passes `--force-color` — colored output without a TTY (CI log viewers render ANSI). Locally, `docker run -t` suffices |
| `SALT_PUSH_DIR` | `/app` | base directory for the whole mount tree above (srv, cache, config, ssh, logs) |
| `SALT_RESOURCES` | unset | inline resource declarations: YAML placed under the `resources:` pillar key (served via `ext_pillar`, merged over mounted pillar — a type declared in both has its `resource_ids` replaced by this). E.g. `SALT_RESOURCES='github: {resource_ids: [myorg/repo1]}'` |
| `SALT_ROSTER` | unset | inline roster contents for `salt-ssh`; takes precedence over a mounted `/app/roster` |
| `PYTHON_PACKAGES` / `PYTHON_PACKAGES_FILE` | unset | extra pip packages installed via `salt-pip` at container start (upstream mechanism) |
| `DEBUG` | unset | `true` enables shell tracing |

### Baking Python packages at build time

For CI, installing packages on every container start is slow. Bake them instead:

```console
$ docker build --build-arg PYTHON_PACKAGES="saltext-github" \
    -t my-salt-image github.com/lkubb/salt-push
```

or in a derived Dockerfile:

```dockerfile
FROM ghcr.io/lkubb/salt-push:3008.3
RUN salt-pip install --no-cache-dir saltext-github
```

### GitHub Actions example

Applying an org-config repo (states + pillar in `srv/`) with
[saltext-github](https://github.com/salt-extensions/saltext-github):

```yaml
jobs:
  apply:
    runs-on: ubuntu-24.04
    concurrency: org-apply  # never run two applies at once
    steps:
      - uses: actions/checkout@v7

      - uses: actions/create-github-app-token@v2
        id: app-token
        with:
          app-id: ${{ vars.ORG_APP_ID }}
          private-key: ${{ secrets.ORG_APP_KEY }}
          owner: ${{ github.repository_owner }}

      - uses: actions/cache@v4
        with:
          path: .salt-cache
          key: salt-cache-${{ github.run_id }}
          restore-keys: salt-cache-

      - name: Apply org configuration
        env:
          GH_TOKEN: ${{ steps.app-token.outputs.token }}
        run: |
          docker run --rm \
            -v "$PWD/srv:/app/srv:ro" \
            -v "$PWD/.salt-cache:/app/cache" \
            -e GH_TOKEN \
            -e SALT_FORCE_COLOR=true \
            ghcr.io/lkubb/salt-push:3008.3 \
            salt-call state.highstate
```

On pull requests, run `salt-call state.highstate test=True` instead to surface the
predicted changes for review.

## Notes

- **The one-shot modes are for one-shot containers.** They generate `/etc/salt/minion` and
  `/etc/salt/master` on start; don't `docker run` them against a data dir that a
  long-running master container is using — upstream's own config management would fight it.
  (`docker exec` into a running upstream-style container is unaffected, since it bypasses
  the entrypoint.)
- The container still starts as root (initial setup needs it: UID remapping, directory
  ownership, runtime `PYTHON_PACKAGES` installs), then drops to `salt` for the tool run.
  Managing things *inside* the container (installing OS packages, writing root-owned files)
  is not the target use case — this image manages *remote* resources; use
  `SALT_PUSH_USER=root` if you need to anyway.
- Config drop-ins are merged on top of the generated configs via `default_include`, so
  `file_roots`, `cachedir`, `roster_file`, etc. can all be overridden without rebuilding.

## Tags

Images track the upstream LTS lineage only and are published to
`ghcr.io/lkubb/salt-push` as:

- `<salt version>` (e.g. `3008.3`) — matches the pinned upstream base
- `latest`
- `sha-<short commit>` — immutable per-commit reference

Architectures: `linux/amd64`, `linux/arm64`.

## Development

```console
$ docker build -t salt-push:dev .
$ docker build --build-arg PYTHON_PACKAGES=saltext-github -t salt-push:dev-baked .
$ tests/smoke.sh salt-push:dev salt-push:dev-baked
```

## License

MIT, matching upstream [docker-salt-master](https://github.com/cdalvaro/docker-salt-master).
See [LICENSE](LICENSE).
