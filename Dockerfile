FROM ghcr.io/cdalvaro/docker-salt-master:3008.5@sha256:982a754fe15b5dbabc13a4889f8cd5d51417a3aff68cad04aa7c8562e6e4eb73

# Space-separated pip specs baked into the Salt onedir at build time.
# Same name/semantics as the runtime env var honored by the entrypoints;
# ARG values don't persist into the image, so there is no runtime clash.
ARG PYTHON_PACKAGES=""
# hadolint ignore=SC2086
RUN if [ -n "${PYTHON_PACKAGES}" ]; then salt-pip install --no-cache-dir ${PYTHON_PACKAGES}; fi

# Patches to the bundled Salt, candidates for upstreaming (job caching +
# highstate output for resource dispatch). git apply: the image ships git,
# but no GNU patch.
COPY assets/patches/ /tmp/salt-patches/
# hadolint ignore=DL3003
RUN sp="$(/opt/saltstack/salt/bin/python3 -c 'import pathlib, salt; print(pathlib.Path(salt.__file__).parents[1])')" && \
    cd "${sp}" && \
    for p in /tmp/salt-patches/*.patch; do git apply --verbose "${p}"; done && \
    rm -rf /tmp/salt-patches

COPY --chmod=0755 assets/push-entrypoint.sh /sbin/push-entrypoint.sh
# Custom execution modules and the push_result returner (SALT_RESULT_FILE),
# loaded via module_dirs in the generated configs
COPY assets/modules/ /opt/salt-push/modules/
COPY assets/returners/ /opt/salt-push/returners/

LABEL org.opencontainers.image.source="https://github.com/lkubb/salt-push" \
      org.opencontainers.image.description="docker-salt-master + one-shot push mode: manage remote resources via salt-call, salt or salt-ssh" \
      org.opencontainers.image.licenses="MIT"

ENTRYPOINT ["/sbin/push-entrypoint.sh"]
# No default command: print push-workflow help and fail (upstream's
# master needs an explicit app:start)
CMD []
