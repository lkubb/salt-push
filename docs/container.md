# The container

`ghcr.io/lkubb/salt-push` is a thin derivative of
[`cdalvaro/docker-salt-master`](https://github.com/cdalvaro/docker-salt-master).
It adds a **one-shot mode** on top of the upstream image: run a single
`salt-call`, `salt` or `salt-ssh` command against a mounted state
tree, then exit with the tool's return code. No master, no daemons, no
leftovers.

## Usage

```
docker run [docker options] <image> salt-call [salt-call args...]
docker run [docker options] <image> salt [-E|-L|-G|-P|-C|-T] <target> [args...]
docker run [docker options] <image> salt-ssh <target> [salt-ssh args...]
```

The first argument selects the mode. Everything after it is passed to
the tool verbatim — the command line reads just like running the tool
directly.

Three more rules govern the entrypoint:

- **No command** prints the usage help and exits non-zero, so a CI job
  that lost its command fails loudly. `help`/`-h`/`--help` print it
  with exit 0.
- **Any other first argument** falls through to the
  [upstream entrypoint](https://github.com/cdalvaro/docker-salt-master#usage)
  unchanged (`app:help`, arbitrary commands, …). Unlike upstream,
  starting a salt-master requires an explicit `app:start` — it is no
  longer the default command.
- **`docker exec`** into a running container bypasses the entrypoint
  entirely and always runs the plain binaries (as in upstream's
  examples).

All modes run as the **`salt` user** (like upstream's salt-master),
remapped to `PUID`/`PGID` when set. Set `SALT_PUSH_USER=root` for
operations that need root inside the container.

## Modes

### `salt-call` — the local minion

```console
$ docker run --rm -it \
    -v "$PWD/srv:/app/srv:ro" \
    ghcr.io/lkubb/salt-push:3008.3 salt-call state.apply test=True
```

`salt-call` always runs with `--local --retcode-passthrough`, so
failed states yield a non-zero container exit code (`2` for failed
states, `1` for errors). With no further arguments, it runs
`state.highstate`.

### `salt` — managed resources

```console
$ docker run --rm -it \
    -v "$PWD/srv:/app/srv:ro" \
    ghcr.io/lkubb/salt-push:3008.3 salt 'myorg/*' state.apply repo_config
```

`salt` dispatches to **managed resources** via `salt-call -r`. Targets
are whatever is declared under the `resources:` pillar key — e.g.
repositories exposed by
[saltext-github](https://github.com/salt-extensions/saltext-github) —
plus the managing minion itself. Output is keyed per target, like the
real `salt` CLI.

The familiar targeting shorthands are translated when they lead the
target expression:

| Shorthand            | `--tgt-type`                                                                                                                                                                                                              |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `-E`, `--pcre`       | `pcre`                                                                                                                                                                                                                    |
| `-L`, `--list`       | `list`                                                                                                                                                                                                                    |
| `-G`, `--grain`      | `grain`                                                                                                                                                                                                                   |
| `-P`, `--grain-pcre` | `grain_pcre`                                                                                                                                                                                                              |
| `-C`, `--compound`   | `compound`                                                                                                                                                                                                                |
| `-T`, `--type`       | by resource type: `-T <type>[:<id>]` becomes `--tgt 'T@<type>[:<id>]' --tgt-type compound`, targeting only resources (not the managing minion). Replaces upstream's `--make-token`, which is meaningless without a master |

```console
$ docker run ... <image> salt '*' test.ping
$ docker run ... <image> salt -L repo1,repo2 state.apply repo_config
$ docker run ... <image> salt -T github state.apply repo_config
$ docker run ... <image> salt -T github:myorg/myrepo test.ping
```

Target types without `-r` support (nodegroup, ipcidr, pillar, range)
are not translated. When only a single target matches, the result is
printed bare instead of keyed per target — `salt-call -r` semantics.

#### Inspecting resources

To inspect what is targetable, use the bundled `resource` execution
module — the minion-side counterpart to Salt's `resource` runner.
Where the runner would read the master's grains cache, these functions
render live:

```console
$ docker run ... <image> salt-call resource.list             # {type: [ids]}
$ docker run ... <image> salt-call resource.list type=github
$ docker run ... <image> salt-call resource.types
$ docker run ... <image> salt-call resource.list_grains      # {type:id: grains summary}
$ docker run ... <image> salt-call resource.show_grains type=github id=myorg/myrepo
```

### `salt-ssh` — remote hosts

```console
$ docker run --rm -it \
    -v "$PWD/srv:/app/srv:ro" \
    -v "$PWD/roster:/app/roster:ro" \
    ghcr.io/lkubb/salt-push:3008.3 salt-ssh web1 test.ping
```

`salt-ssh` gets a generated master config pointing at the mounted
state/pillar trees and the roster at `/app/roster` (or inline via
`SALT_ROSTER`).

The client key (`/app/ssh/salt-ssh.rsa`, auto-generated on first use)
and `/app/ssh/known_hosts` live in `/app/ssh` — mount it (writable) to
keep a stable identity and host trust across runs. Treat it as a
secret: it holds a private key.

Override anything (`ssh_priv`, `roster_file`, …) via master config
drop-ins in `/app/config/ssh.d/*.conf`, inline via `SALT_SSH_CONFIG`,
or CLI flags.

## Mounts

| Container path                | Purpose                                                                                                                                          |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `/app/srv/salt`               | `file_roots` base (state tree); read-only is fine                                                                                                |
| `/app/srv/pillar`             | `pillar_roots` base; read-only is fine                                                                                                           |
| `/app/config/minion.d/*.conf` | minion config drop-ins (`salt-call`/`salt` modes) — override anything the generated config sets                                                  |
| `/app/config/ssh.d/*.conf`    | master config drop-ins (`salt-ssh` mode)                                                                                                         |
| `/app/roster`                 | salt-ssh roster                                                                                                                                  |
| `/app/ssh`                    | salt-ssh client key (`salt-ssh.rsa`, auto-generated) + `known_hosts` — mount writable to persist identity and host trust; contains a private key |
| `/app/cache`                  | caches, kept separate per tool (`minion/` incl. `extension_modules`, `master/` for salt-ssh) — mount to persist across runs                      |
| `/app/logs`                   | optional: file logs (`logs/{minion,ssh}`) for debugging                                                                                          |

## Environment variables

| Variable                                   | Default     | Purpose                                                                                                                                                                                                                             |
| ------------------------------------------ | ----------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `SALT_PUSH_USER`                           | `salt`      | user the tool runs as; set `root` to skip dropping privileges                                                                                                                                                                       |
| `PUID` / `PGID`                            | `1000`      | remap the `salt` user's UID/GID (e.g. to match a CI runner's workspace ownership)                                                                                                                                                   |
| `SALT_MINION_ID`                           | `salt-push` | minion `id` (stable by default so cache keys don't churn with container hostnames)                                                                                                                                                  |
| `SALT_LOG_LEVEL`                           | `warning`   | console log level (what CI captures)                                                                                                                                                                                                |
| `SALT_LOGFILE_LEVEL`                       | `info`      | file log level                                                                                                                                                                                                                      |
| `SALT_FORCE_COLOR`                         | unset       | `true` passes `--force-color` — colored output without a TTY (CI log viewers render ANSI). Locally, `docker run -t` suffices                                                                                                        |
| `SALT_PUSH_DIR`                            | `/app`      | base directory for the whole mount tree above (srv, cache, config, ssh, logs)                                                                                                                                                       |
| `SALT_PILLAR`                              | unset       | inline pillar for the local minion (`salt-call`/`salt` modes): a YAML mapping served via `ext_pillar` — recursively merged over mounted pillar by default, but list-type keys are replaced                                          |
| `SALT_RESOURCES`                           | unset       | inline resource declarations: YAML placed under the `resources:` pillar key — same `ext_pillar` mechanism as `SALT_PILLAR`, merged after it, so it wins for that key. E.g. `SALT_RESOURCES='github: {resource_ids: [myorg/repo1]}'` |
| `SALT_ROSTER`                              | unset       | inline roster contents for `salt-ssh`; takes precedence over a mounted `/app/roster`                                                                                                                                                |
| `SALT_MINION_CONFIG`                       | unset       | inline minion config (YAML, `salt-call`/`salt` modes), merged over the generated config *and* any `/app/config/minion.d` drop-ins                                                                                                   |
| `SALT_SSH_CONFIG`                          | unset       | inline master config for `salt-ssh` (YAML), merged over the generated config *and* any `/app/config/ssh.d` drop-ins                                                                                                                 |
| `PYTHON_PACKAGES` / `PYTHON_PACKAGES_FILE` | unset       | extra pip packages installed via `salt-pip` at container start (upstream mechanism)                                                                                                                                                 |
| `DEBUG`                                    | unset       | `true` enables shell tracing                                                                                                                                                                                                        |

## Hardened config defaults

The generated minion config sets `enable_fqdns_grains: False`: reverse
DNS of ephemeral container IPs yields nothing and stalls startup where
resolvers are slow. Override it via a drop-in in
`/app/config/minion.d/` when needed.

No equivalent exists for salt-ssh's job returns: it writes them (full
state results, including diffs) under `/app/cache/master/jobs`
unconditionally — Salt offers no config switch. Mount `/app/cache`
accordingly, or persist only selected subpaths.

## Baking Python packages at build time

For CI, installing packages on every container start is slow. Bake
them instead:

```console
$ docker build --build-arg PYTHON_PACKAGES="saltext-github" \
    -t my-salt-image github.com/lkubb/salt-push
```

or in a derived Dockerfile:

```dockerfile
FROM ghcr.io/lkubb/salt-push:3008.3
RUN salt-pip install --no-cache-dir saltext-github
```

## Caveats

- **The one-shot modes are for one-shot containers.** They generate
  `/etc/salt/minion` and `/etc/salt/master` on start; don't
  `docker run` them against a data dir that a long-running master
  container is using — upstream's own config management would fight
  it. (`docker exec` into a running upstream-style container is
  unaffected, since it bypasses the entrypoint.)
- **The container still starts as root** (initial setup needs it: UID
  remapping, directory ownership, runtime `PYTHON_PACKAGES` installs),
  then drops to `salt` for the tool run. Managing things *inside* the
  container (installing OS packages, writing root-owned files) is not
  the target use case — this image manages *remote* resources; use
  `SALT_PUSH_USER=root` if you need to anyway.
- **Config drop-ins win.** They are merged on top of the generated
  configs via `default_include`, so `file_roots`, `cachedir`,
  `roster_file`, etc. can all be overridden without rebuilding.
  `SALT_MINION_CONFIG`/`SALT_SSH_CONFIG` are merged after the drop-ins
  and win over both.

## Tags

Images track the upstream LTS lineage only and are published to
`ghcr.io/lkubb/salt-push` as:

- `<salt version>` (e.g. `3008.3`) — matches the pinned upstream base
- `latest`
- `sha-<short commit>` — immutable per-commit reference

Architectures: `linux/amd64`, `linux/arm64`.
