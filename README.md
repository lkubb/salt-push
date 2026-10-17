# salt-push

Run one-shot Salt commands and states against remote resources — **no
master required**.

Think Ansible-style push: run it from anywhere — CI, your laptop — and
it pushes changes out to the targets, then exits. Nothing is
long-running on either end. Targets can be:

- **remote hosts** over SSH (`salt-ssh`)
- **API-backed resources** — a GitHub org via
  [saltext-github](https://github.com/salt-extensions/saltext-github),
  cloud providers, DNS, … (`salt`, powered by `salt-call -r`)
- **the local minion** itself (`salt-call`)

## One repo, two deliverables

This repository ships both a container image and a GitHub Action that
wraps it:

1. **The container** — a thin derivative of
   [`cdalvaro/docker-salt-master`](https://github.com/cdalvaro/docker-salt-master)
   that adds a one-shot mode: run a single `salt-call`, `salt` or
   `salt-ssh` command against a mounted state tree, exit with its
   return code. → [`docs/container.md`](docs/container.md)
1. **The GitHub Action** — `uses: lkubb/salt-push@v1` mounts paths
   from the checked-out repository into the container and runs one or
   more commands sequentially (fail-fast), applying a highstate by
   default. → [`docs/action.md`](docs/action.md)

Use the container directly anywhere Docker runs; use the action when
the state tree lives in a GitHub repository and CI should apply it.

## Quick start: container

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

The first argument selects the mode; everything after it is passed to
the tool verbatim. See [`docs/container.md`](docs/container.md) for
the three modes, mounts, environment variables and image tags.

## Quick start: GitHub Action

```yaml
steps:
  - uses: actions/checkout@v7
  - uses: lkubb/salt-push@v1  # highstate from ./srv/{salt,pillar}
```

See [`docs/action.md`](docs/action.md) for inputs, outputs, full
examples and the security considerations — read those before enabling
caching on a public repository.

## Development

```console
$ docker build -t salt-push:dev .
$ docker build --build-arg PYTHON_PACKAGES=saltext-github -t salt-push:dev-baked .
$ tests/smoke.sh salt-push:dev salt-push:dev-baked
$ python3 -m unittest discover -s tests  # action logic, no Docker needed
```

## License

MIT, matching upstream
[docker-salt-master](https://github.com/cdalvaro/docker-salt-master).
See [LICENSE](LICENSE).
