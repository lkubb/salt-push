#!/usr/bin/env bash

# Smoke tests for the salt-push image.
#
#   tests/smoke.sh <image> [baked-image]
#
# <image>        the plain build
# [baked-image]  optional: a build with --build-arg PYTHON_PACKAGES=saltext-github

set -euo pipefail

IMG="${1:?usage: smoke.sh <image> [baked-image]}"
BAKED="${2:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES="${HERE}/fixtures"

failures=0
fail() {
	echo "FAIL: $*" >&2
	failures=$((failures + 1))
}
pass() { echo "ok: $*"; }

# Capture first, grep after: piping into grep -q under pipefail makes docker run
# fail with SIGPIPE when grep exits on an early match.
check() {
	local desc="$1" pattern="$2"
	shift 2
	local out
	out="$("$@" 2>&1)" || out="${out}"$'\n'"<nonzero exit>"
	if grep -qE "${pattern}" <<<"${out}"; then
		pass "${desc}"
	else
		fail "${desc}"$'\n'"${out}"
	fi
}

# 1. Arbitrary-command fall-through to the upstream entrypoint
check "fall-through: salt-run --version" '^salt-run 3' \
	docker run --rm "${IMG}" salt-run --version

# 1b. No command prints usage help and fails (CI safety)
rc=0
out="$(docker run --rm "${IMG}" 2>&1)" || rc=$?
if [[ ${rc} -ne 0 ]] && grep -q 'Usage:' <<<"${out}"; then
	pass "no command: help on stderr, non-zero exit (rc=${rc})"
else
	fail "no command: help on stderr, non-zero exit (rc=${rc})"$'\n'"${out}"
fi

# 1c. Explicit help exits zero
rc=0
out="$(docker run --rm "${IMG}" help 2>&1)" || rc=$?
if [[ ${rc} -eq 0 ]] && grep -q 'Usage:' <<<"${out}"; then
	pass "help: usage text, zero exit"
else
	fail "help: usage text, zero exit (rc=${rc})"$'\n'"${out}"
fi

# 2. Upstream entrypoint verbs still reachable
check "upstream verb: app:help" 'app:start' \
	docker run --rm "${IMG}" app:help

# 3. salt-call mode without any mounts
check "salt-call: test.ping without mounts" 'True' \
	docker run --rm "${IMG}" salt-call test.ping

# 4. salt-call runs as the salt user by default
check "salt-call: runs as the salt user" '^ +salt$' \
	docker run --rm "${IMG}" salt-call cmd.run whoami

# 5. SALT_PUSH_USER=root opts out of dropping privileges
check "salt-call: SALT_PUSH_USER=root" '^ +root$' \
	docker run --rm -e SALT_PUSH_USER=root "${IMG}" salt-call cmd.run whoami

# 6. SALT_FORCE_COLOR=true emits ANSI escapes without a TTY
check "salt-call: SALT_FORCE_COLOR=true" $'\x1b\[' \
	docker run --rm -e SALT_FORCE_COLOR=true "${IMG}" salt-call test.ping

# 7. state.apply with mounted state/pillar trees renders pillar data
check "salt-call: state.apply ok renders pillar" 'hello-from-pillar' \
	docker run --rm -v "${FIXTURES}/srv:/app/srv:ro" "${IMG}" salt-call state.apply ok

# 8. Failing state exits non-zero (retcode passthrough)
rc=0
docker run --rm -v "${FIXTURES}/srv:/app/srv:ro" "${IMG}" salt-call state.apply fail >/dev/null 2>&1 || rc=$?
if [[ ${rc} -ne 0 ]]; then
	pass "salt-call: failing state exits non-zero (rc=${rc})"
else
	fail "salt-call: failing state exited zero"
fi

# 9. Minion config drop-ins are included (absolute-glob default_include)
check "salt-call: minion_config drop-in applied" 'dropin-works' \
	docker run --rm -v "${FIXTURES}/minion_config:/app/config/minion.d:ro" "${IMG}" \
	salt-call grains.get smoke_dropin

# 10. No arguments defaults to highstate
if docker run --rm -v "${FIXTURES}/srv:/app/srv:ro" "${IMG}" salt-call >/dev/null 2>&1; then
	pass "salt-call: default highstate"
else
	fail "salt-call: default highstate"
fi

# 11. salt mode fans out to pillar-configured resources (per-target keys)
check "salt: dispatches to pillar resources" 'dummy-01:' \
	docker run --rm -v "${FIXTURES}/srv:/app/srv:ro" "${IMG}" salt '*' test.ping

# 12. salt mode translates targeting shorthands to --tgt-type
check "salt: -L shorthand targets by list" '^ +True$' \
	docker run --rm "${IMG}" salt -L salt-push test.ping

# 12b. -T targets by resource type and excludes the managing minion
out="$(docker run --rm -v "${FIXTURES}/srv:/app/srv:ro" "${IMG}" salt -T dummy test.ping 2>&1)" || true
if grep -q 'dummy-02:' <<<"${out}" && ! grep -q 'salt-push' <<<"${out}"; then
	pass "salt: -T targets by resource type, minion excluded"
else
	fail "salt: -T targets by resource type, minion excluded"$'\n'"${out}"
fi

# 12c. Image-shipped resource module lists configured resources
check "salt-call: resource.list" 'dummy-02' \
	docker run --rm -v "${FIXTURES}/srv:/app/srv:ro" "${IMG}" salt-call resource.list

# 12d. resource.list_grains renders live per-resource grains
check "salt-call: resource.list_grains" 'dummy:dummy-01:' \
	docker run --rm -v "${FIXTURES}/srv:/app/srv:ro" "${IMG}" salt-call resource.list_grains

# 12e. resource.show_grains renders one resource's grains
check "salt-call: resource.show_grains" 'resource_id:' \
	docker run --rm -v "${FIXTURES}/srv:/app/srv:ro" "${IMG}" \
	salt-call resource.show_grains type=dummy id=dummy-01

# 12f. SALT_RESOURCES declares resources without any pillar mount
check "salt: SALT_RESOURCES env declaration" 'env-02:' \
	docker run --rm -e SALT_RESOURCES='dummy: {resource_ids: [env-01, env-02]}' \
	"${IMG}" salt -T dummy test.ping

# 12g. SALT_RESOURCES merges over mounted pillar (same type: list replaced)
check "salt: SALT_RESOURCES overrides same-type pillar list" 'env-01:' \
	docker run --rm -v "${FIXTURES}/srv:/app/srv:ro" \
	-e SALT_RESOURCES='dummy: {resource_ids: [env-01]}' \
	"${IMG}" salt '*' test.ping

# 13. Failing state under -r dispatch still exits non-zero
rc=0
docker run --rm -v "${FIXTURES}/srv:/app/srv:ro" "${IMG}" salt '*' state.apply fail >/dev/null 2>&1 || rc=$?
if [[ ${rc} -ne 0 ]]; then
	pass "salt: failing state exits non-zero (rc=${rc})"
else
	fail "salt: failing state exited zero"
fi

# 14. salt-ssh mode starts up and reads the roster from the generated config
check "salt-ssh: reads mounted roster" 'No matching targets' \
	docker run --rm -v "${FIXTURES}/roster:/app/roster:ro" "${IMG}" \
	salt-ssh '*' test.ping

# 14b. SALT_ROSTER provides the roster without a mount (target is consumed)
check "salt-ssh: SALT_ROSTER env roster" '^web1:' \
	docker run --rm -e SALT_ROSTER=$'web1:\n  host: 127.0.0.1\n  port: 2' \
	"${IMG}" salt-ssh web1 test.ping

# 14c. Client key + known_hosts persist in a mounted /app/ssh
ssh_dir="${HERE}/.smoke-ssh"
rm -rf "${ssh_dir}" && mkdir -p "${ssh_dir}"
docker run --rm -v "${ssh_dir}:/app/ssh" \
	-e SALT_ROSTER=$'web1:\n  host: 127.0.0.1\n  port: 2' \
	"${IMG}" salt-ssh web1 test.ping >/dev/null 2>&1 || true
if [[ -f "${ssh_dir}/salt-ssh.rsa" && -f "${ssh_dir}/known_hosts" ]]; then
	pass "salt-ssh: key and known_hosts persist in /app/ssh mount"
else
	fail "salt-ssh: key and known_hosts persist in /app/ssh mount"$'\n'"$(ls -la "${ssh_dir}")"
fi
rm -rf "${ssh_dir}"

# 15. Hardened config defaults: no fqdns grain stalls — and drop-ins still
# override them
check "config: fqdns grains disabled" 'False' \
	docker run --rm "${IMG}" salt-call config.get enable_fqdns_grains

check "config: drop-in overrides hardened default" 'True' \
	docker run --rm \
	-v "${FIXTURES}/minion_config:/app/config/minion.d:ro" \
	"${IMG}" salt-call config.get enable_fqdns_grains

# 16. Build-arg-baked package is importable by the onedir interpreter
if [[ -n ${BAKED} ]]; then
	if docker run --rm "${BAKED}" /opt/saltstack/salt/bin/python3 -c "import saltext.github" 2>&1; then
		pass "baked: import saltext.github"
	else
		fail "baked: import saltext.github"
	fi
fi

if [[ ${failures} -gt 0 ]]; then
	echo "${failures} smoke test(s) failed" >&2
	exit 1
fi
echo "all smoke tests passed"
