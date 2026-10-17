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

# 6b. stdout carries only Salt's output — upstream chatter (e.g. the UID
# mapping notice) goes to stderr, so piping into a JSON parser works
out="$(docker run --rm -e PUID=12345 -e PGID=12345 "${IMG}" salt-call --out json test.ping 2>/dev/null)"
if python3 -c 'import json,sys; json.load(sys.stdin)' <<<"${out}" >/dev/null 2>&1; then
	pass "salt-call: clean JSON on stdout with --out json"
else
	fail "salt-call: clean JSON on stdout with --out json"$'\n'"${out}"
fi

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

# 10. Bare salt-call behaves like the plain tool: usage error, non-zero exit
rc=0
out="$(docker run --rm "${IMG}" salt-call 2>&1)" || rc=$?
if [[ ${rc} -ne 0 ]] && grep -q 'Usage: salt-call' <<<"${out}"; then
	pass "salt-call: bare invocation prints usage, non-zero exit (rc=${rc})"
else
	fail "salt-call: bare invocation prints usage, non-zero exit (rc=${rc})"$'\n'"${out}"
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

# 12h. SALT_PILLAR provides pillar without any mount (unmask: this Salt
# masks pillar output by default — pillar_mask_output)
check "salt-call: SALT_PILLAR env pillar" 'pillar-env-works' \
	docker run --rm -e SALT_PILLAR='smoke_env: pillar-env-works' \
	"${IMG}" salt-call pillar.get smoke_env unmask=True

# 12i. SALT_PILLAR merges over mounted pillar; SALT_RESOURCES still wins
# for the resources: key (merged after SALT_PILLAR)
out="$(docker run --rm -v "${FIXTURES}/srv:/app/srv:ro" \
	-e SALT_PILLAR=$'common:\n  greeting: env-wins\nresources:\n  dummy: {resource_ids: [pillar-01]}' \
	-e SALT_RESOURCES='dummy: {resource_ids: [res-01]}' \
	"${IMG}" salt-call pillar.items unmask=True 2>&1)" || true
if grep -q 'env-wins' <<<"${out}" && grep -q 'res-01' <<<"${out}" && ! grep -q 'pillar-01' <<<"${out}"; then
	pass "salt-call: SALT_PILLAR overrides mounted pillar, SALT_RESOURCES wins resources key"
else
	fail "salt-call: SALT_PILLAR overrides mounted pillar, SALT_RESOURCES wins resources key"$'\n'"${out}"
fi

# 12j. Merged state runs render with the highstate outputter (patched Salt)
check "salt: state.apply renders highstate output" 'Succeeded:' \
	docker run --rm -v "${FIXTURES}/srv:/app/srv:ro" "${IMG}" salt '*' state.apply ok

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

# 14d. SALT_SSH_CONFIG sets master config inline — it wins over the generated
# config (the key is auto-generated at the overridden ssh_priv path)
ssh_dir="${HERE}/.smoke-ssh-inline"
rm -rf "${ssh_dir}" && mkdir -p "${ssh_dir}"
docker run --rm -v "${ssh_dir}:/app/ssh" \
	-e SALT_SSH_CONFIG='ssh_priv: /app/ssh/inline-key.rsa' \
	-e SALT_ROSTER=$'web1:\n  host: 127.0.0.1\n  port: 2' \
	"${IMG}" salt-ssh web1 test.ping >/dev/null 2>&1 || true
if [[ -f "${ssh_dir}/inline-key.rsa" ]]; then
	pass "salt-ssh: SALT_SSH_CONFIG overrides generated config"
else
	fail "salt-ssh: SALT_SSH_CONFIG overrides generated config"$'\n'"$(ls -la "${ssh_dir}")"
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

# 15b. SALT_MINION_CONFIG sets minion config inline, no mount needed
check "config: SALT_MINION_CONFIG overrides hardened default" 'True' \
	docker run --rm -e SALT_MINION_CONFIG='enable_fqdns_grains: True' \
	"${IMG}" salt-call config.get enable_fqdns_grains

# 15c. Inline config is included after default_include — it wins over drop-ins
check "config: SALT_MINION_CONFIG wins over drop-in" 'inline-wins' \
	docker run --rm \
	-v "${FIXTURES}/minion_config:/app/config/minion.d:ro" \
	-e SALT_MINION_CONFIG=$'grains:\n  smoke_dropin: inline-wins' \
	"${IMG}" salt-call grains.get smoke_dropin

# 16. SALT_RESULT_FILE: JSON job return written, no msgpack job cache
res_dir="${HERE}/.smoke-results"
rm -rf "${res_dir}" && mkdir -p "${res_dir}"
docker run --rm -v "${res_dir}:/app/cache" -e SALT_RESULT_FILE=/app/cache/result.json \
	"${IMG}" salt-call test.ping >/dev/null 2>&1 || true
if grep -q '"return": true' "${res_dir}/result.json" 2>/dev/null &&
	[[ -z "$(ls -A "${res_dir}/minion/minion_jobs" 2>/dev/null)" ]]; then
	pass "salt-call: SALT_RESULT_FILE captures return, no job cache entry"
else
	fail "salt-call: SALT_RESULT_FILE captures return, no job cache entry"$'\n'"$(cat "${res_dir}/result.json" 2>/dev/null)"
fi

# 16b. Failing state: exit code preserved, cached retcode in the result
rc=0
docker run --rm -v "${FIXTURES}/srv:/app/srv:ro" -v "${res_dir}:/app/cache" \
	-e SALT_RESULT_FILE=/app/cache/result.json \
	"${IMG}" salt-call state.apply fail >/dev/null 2>&1 || rc=$?
if [[ ${rc} -eq 2 ]] && grep -q '"retcode": 2' "${res_dir}/result.json" 2>/dev/null; then
	pass "salt-call: SALT_RESULT_FILE keeps retcode passthrough (rc=${rc})"
else
	fail "salt-call: SALT_RESULT_FILE keeps retcode passthrough (rc=${rc})"$'\n'"$(cat "${res_dir}/result.json" 2>/dev/null)"
fi

# 16c. salt-ssh: per-target returns via redirected master_job_cache —
# nothing lands in the msgpack job cache
docker run --rm -v "${res_dir}:/app/cache" -e SALT_RESULT_FILE=/app/cache/result.json \
	-e SALT_ROSTER=$'web1:\n  host: 127.0.0.1\n  port: 2' \
	"${IMG}" salt-ssh web1 test.ping >/dev/null 2>&1 || true
if grep -q '"web1"' "${res_dir}/result.json" 2>/dev/null &&
	[[ -z "$(find "${res_dir}/master/jobs" -name jid 2>/dev/null)" ]]; then
	pass "salt-ssh: SALT_RESULT_FILE captures per-target returns, no job cache"
else
	fail "salt-ssh: SALT_RESULT_FILE captures per-target returns, no job cache"$'\n'"$(cat "${res_dir}/result.json" 2>/dev/null)"
fi

# 16d. salt mode: dispatch honors the returner (patched Salt)
docker run --rm -v "${res_dir}:/app/cache" -e SALT_RESULT_FILE=/app/cache/result.json \
	"${IMG}" salt -L salt-push test.ping >/dev/null 2>&1 || true
if grep -q '"fun": "test.ping"' "${res_dir}/result.json" 2>/dev/null &&
	grep -q '"tgt": "salt-push"' "${res_dir}/result.json" 2>/dev/null &&
	[[ -z "$(ls -A "${res_dir}/minion/minion_jobs" 2>/dev/null)" ]]; then
	pass "salt: SALT_RESULT_FILE captures dispatch return via returner"
else
	fail "salt: SALT_RESULT_FILE captures dispatch return via returner"$'\n'"$(cat "${res_dir}/result.json" 2>/dev/null)"
fi
rm -rf "${res_dir}"

# 17. Build-arg-baked package is importable by the onedir interpreter
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
