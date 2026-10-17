#!/usr/bin/env bash

# Adds a one-shot interface on top of docker-salt-master's entrypoint:
#
#   docker run --rm <image> salt-call [args...]            # standalone (--local)
#   docker run --rm <image> salt [-ELGPCT] <target> [args] # resource dispatch (salt-call -r)
#   docker run --rm <image> salt-ssh <target> [args...]    # salt-ssh
#
# Anything else is handed to the upstream entrypoint unchanged.
# (`docker exec` bypasses this entrypoint and always runs the plain binaries.)

set -eo pipefail

print_help() {
	cat <<'EOF'
salt-push — one-shot Salt in push mode (on top of docker-salt-master)

Usage:
  salt-call [salt-call args...]
      Run salt-call --local --retcode-passthrough against the mounted
      state tree.
  salt [-E|-L|-G|-P|-C|-T] <target> [args...]
      Dispatch to managed resources (salt-call -r) with per-target
      output, like the salt CLI. Resources are declared under the
      'resources:' pillar key; inspect them via 'salt-call resource.list'.
  salt-ssh <target> [salt-ssh args...]
      Run salt-ssh using the roster at /app/roster.
  scrub
      Remove known sensitive cache paths and exit (see SALT_SCRUB_CACHE;
      pairs with SALT_SCRUB_CACHE=defer for multi-command sequences).

Common mounts:
  /app/srv/salt            state tree (file_roots)
  /app/srv/pillar          pillar tree
  /app/cache               persistent cache
  /app/config/minion.d/    minion config drop-ins (salt-call, salt)
  /app/config/ssh.d/       master config drop-ins (salt-ssh)
  /app/roster              salt-ssh roster
  /app/ssh/                salt-ssh client key + known_hosts (persist trust)

Anything else is passed to the upstream docker-salt-master entrypoint:
  app:start      run a salt-master (upstream's default)
  app:help       upstream help
  <command>      run an arbitrary command

Docs: https://github.com/lkubb/salt-push
EOF
}

# Known sensitive cache paths, removed by SALT_SCRUB_CACHE=true after the
# run and by the standalone `scrub` command:
# - job data: jobs/queues (master), minion_jobs/job_queue/req/
#   state_pause, proc files of crashed runs, bare-jid dirs of parallel
#   runs (minion; jids are exactly 20 digits — leave other numeric
#   dirs alone)
# - compiled state data with pillar rendered in: highstate.cache.p,
#   sls.p, accumulator (both caches)
# - cached grains/minion data: grains.cache.p (both), minions (master —
#   minion_data_cache; also receives e.g. saltext-vault data written for
#   salt-ssh targets)
# - credentials: vault (both — saltext-vault tokens), token (master)
scrub_cache() {
	rm -rf \
		"${SALT_PUSH_DIR}"/cache/master/{jobs,queues,minions,token} \
		"${SALT_PUSH_DIR}"/cache/minion/{minion_jobs,job_queue,req,proc,state_pause} \
		"${SALT_PUSH_DIR}"/cache/{minion,master}/{highstate.cache.p,sls.p,accumulator,grains.cache.p,vault}
	[[ -d "${SALT_PUSH_DIR}/cache/minion" ]] &&
		find "${SALT_PUSH_DIR}/cache/minion" -maxdepth 1 -type d -regextype posix-extended \
			-regex '.*/[0-9]{20}' -exec rm -rf {} +
	return 0
}

case "${1:-}" in
salt | salt-call | salt-ssh)
	mode="${1}"
	shift
	;;
scrub)
	# Standalone scrub, e.g. once after a multi-command sequence where
	# each command ran with SALT_SCRUB_CACHE=defer (the action does this)
	SALT_PUSH_DIR="${SALT_PUSH_DIR:-/app}"
	scrub_cache
	exit 0
	;;
help | -h | --help)
	print_help
	exit 0
	;;
"")
	# Fail loudly: a CI job that lost its command must not silently
	# do nothing (or worse, something implicit).
	print_help >&2
	exit 1
	;;
*) exec /sbin/entrypoint.sh "$@" ;;
esac

# env-defaults.sh (sourced below) pre-sets some SALT_* vars for upstream's
# purposes, so remember whether the user actually provided them.
user_minion_id="${SALT_MINION_ID:-}"
user_log_level="${SALT_LOG_LEVEL:-}"
user_level_logfile="${SALT_LOGFILE_LEVEL:-}"
user_resources="${SALT_RESOURCES:-}"
user_roster="${SALT_ROSTER:-}"
user_pillar="${SALT_PILLAR:-}"
user_minion_config="${SALT_MINION_CONFIG:-}"
user_ssh_config="${SALT_SSH_CONFIG:-}"
user_result_file="${SALT_RESULT_FILE:-}"
user_scrub="${SALT_SCRUB_CACHE:-}"
user_scrub="${user_scrub,,}"
[[ ${user_scrub} == true || ${user_scrub} == defer ]] || user_scrub=""

# Upstream helpers: logging, map_uidgid and
# install_python_additional_packages. Not nounset-safe, so no set -u here.
# shellcheck source=/dev/null
source "${SALT_RUNTIME_DIR}/functions.sh"

# Upstream logs info/debug chatter to stdout (warn/error already go to
# stderr). Keep stdout reserved for the tool's own output, so e.g.
# `docker run … salt-call --out json … | jq` works.
log_info() { echo >&2 "[INFO] $*"; }
# shellcheck disable=SC2329  # invoked by the sourced upstream helpers
log_debug() { if [[ ${DEBUG,,} == true ]]; then echo >&2 "[DEBUG] $*"; fi; }

DEBUG="${DEBUG:-}"
[[ ${DEBUG,,} == true ]] && set -o xtrace

SALT_MINION_ID="${user_minion_id:-salt-push}"
SALT_LOG_LEVEL="${user_log_level:-warning}"
SALT_LOGFILE_LEVEL="${user_level_logfile:-info}"
SALT_PUSH_DIR="${SALT_PUSH_DIR:-/app}"
SALT_PUSH_USER="${SALT_PUSH_USER:-${SALT_USER}}"

# Started with --user: no privileges to switch users, run as-is.
[[ ${EUID} -eq 0 ]] || SALT_PUSH_USER=""

[[ ${SALT_PUSH_USER} == "${SALT_USER}" ]] && map_uidgid

mkdir -p "${SALT_PUSH_DIR}/cache/minion" "${SALT_PUSH_DIR}/cache/master" \
	"${SALT_PUSH_DIR}/logs" "${SALT_PUSH_DIR}/config/minion.d" \
	"${SALT_PUSH_DIR}/config/ssh.d" "${SALT_PUSH_DIR}/ssh" /var/run/salt/minion

# salt-ssh only honors known_hosts_file when it already exists.
# Both guarded: /app/ssh may be a read-only mount with user-managed contents.
[[ -f "${SALT_PUSH_DIR}/ssh/known_hosts" ]] ||
	touch "${SALT_PUSH_DIR}/ssh/known_hosts" 2>/dev/null ||
	log_warn "Cannot create ${SALT_PUSH_DIR}/ssh/known_hosts (read-only mount?)"
[[ -d "${SALT_PUSH_DIR}/srv/salt" ]] || log_warn "No state tree mounted at ${SALT_PUSH_DIR}/srv/salt"

# SALT_PILLAR (YAML mapping) / SALT_RESOURCES (YAML mapping placed under the
# `resources:` pillar key): inline pillar. Served via ext_pillar instead of a
# generated pillar root: a second top.sls in the same env silently loses
# against a user-mounted one. SALT_RESOURCES is merged after SALT_PILLAR, so
# the dedicated variable wins for the `resources:` key.
ext_pillar_extra=""
if [[ -n ${user_pillar} ]]; then
	printf '%s\n' "${user_pillar}" >"${SALT_ROOT_DIR}/push_pillar.yaml"
	ext_pillar_extra+="
  - cmd_yaml: cat ${SALT_ROOT_DIR}/push_pillar.yaml"
fi
if [[ -n ${user_resources} ]]; then
	{
		echo "resources:"
		echo "  ${user_resources//$'\n'/$'\n'  }"
	} >"${SALT_ROOT_DIR}/push_resources.yaml"
	ext_pillar_extra+="
  - cmd_yaml: cat ${SALT_ROOT_DIR}/push_resources.yaml"
fi
[[ -n ${ext_pillar_extra} ]] && ext_pillar_extra="
ext_pillar:${ext_pillar_extra}"

# SALT_MINION_CONFIG / SALT_SSH_CONFIG: inline minion/master config, merged
# via `include` — Salt processes it after default_include, so it wins over
# mounted drop-ins.
minion_include_extra=""
if [[ -n ${user_minion_config} ]]; then
	printf '%s\n' "${user_minion_config}" >"${SALT_ROOT_DIR}/push_minion.conf"
	minion_include_extra="
include: ${SALT_ROOT_DIR}/push_minion.conf"
fi
ssh_include_extra=""
if [[ -n ${user_ssh_config} ]]; then
	printf '%s\n' "${user_ssh_config}" >"${SALT_ROOT_DIR}/push_ssh.conf"
	ssh_include_extra="
include: ${SALT_ROOT_DIR}/push_ssh.conf"
fi

# SALT_ROSTER: roster contents, written to a generated file that takes
# precedence over a mounted ${SALT_PUSH_DIR}/roster.
roster_file="${SALT_PUSH_DIR}/roster"
if [[ -n ${user_roster} ]]; then
	roster_file="${SALT_ROOT_DIR}/roster"
	[[ -f "${SALT_PUSH_DIR}/roster" ]] && log_warn "SALT_ROSTER overrides the mounted roster"
	printf '%s\n' "${user_roster}" >"${roster_file}"
fi

# SALT_RESULT_FILE: route the job return through the bundled push_result
# returner, which dumps it as JSON — the salt process writes the file
# itself, no job-cache post-processing. salt-call/salt get --return
# appended; salt-ssh writes returns through master_job_cache, redirected
# to the same returner (which also keeps job returns out of the msgpack
# cache under cache/master/jobs).
# SALT_SCRUB_CACHE: defense in depth, not a cure — salt-ssh job returns
# are discarded by the returner (unless SALT_RESULT_FILE captures them),
# the remote thin dir is wiped after each session (ssh_wipe: its
# salt_state.tgz contains rendered pillar), and job-return leftovers are
# removed from the cache after the run (see the run section below).
result_minion_extra=""
result_master_extra=""
result_args=()
if [[ -n ${user_result_file} ]]; then
	rm -f "${user_result_file}" 2>/dev/null || true
	result_minion_extra="
push_result.file: ${user_result_file}"
	result_master_extra="
push_result.file: ${user_result_file}
push_result.accumulate: True
master_job_cache: push_result"
	result_args=(--return push_result)
elif [[ -n ${user_scrub} ]]; then
	result_master_extra="
push_result.drop: True
master_job_cache: push_result"
fi
[[ -n ${user_scrub} ]] && result_master_extra+="
ssh_wipe: True"

cat >"${SALT_ROOT_DIR}/minion" <<EOF
id: ${SALT_MINION_ID}
file_client: local
file_roots:
  base:
    - ${SALT_PUSH_DIR}/srv/salt
pillar_roots:
  base:
    - ${SALT_PUSH_DIR}/srv/pillar${ext_pillar_extra}
cachedir: ${SALT_PUSH_DIR}/cache/minion
# Not derived from cachedir by Salt — defaults to /var/cache/salt/minion/extmods,
# which breaks under PUID remapping and wouldn't persist in the cache mount.
extension_modules: ${SALT_PUSH_DIR}/cache/minion/extmods
log_file: ${SALT_PUSH_DIR}/logs/minion
log_level_logfile: ${SALT_LOGFILE_LEVEL}${result_minion_extra}
# Reverse DNS of ephemeral container IPs yields nothing and stalls startup
# where resolvers are slow.
enable_fqdns_grains: False
# Custom modules/returners shipped with this image (e.g. resource.list,
# push_result)
module_dirs:
  - /opt/salt-push
default_include: ${SALT_PUSH_DIR}/config/minion.d/*.conf${minion_include_extra}
EOF

# salt-ssh reads the master config
cat >"${SALT_ROOT_DIR}/master" <<EOF
file_roots:
  base:
    - ${SALT_PUSH_DIR}/srv/salt
pillar_roots:
  base:
    - ${SALT_PUSH_DIR}/srv/pillar
cachedir: ${SALT_PUSH_DIR}/cache/master
# NOTE: salt-ssh persists job returns under cachedir/jobs regardless of
# config — it calls the master_job_cache returner unconditionally and
# ignores job_cache/minion_data_cache. Don't persist cache/master blindly.
roster_file: ${roster_file}
ssh_priv: ${SALT_PUSH_DIR}/ssh/salt-ssh.rsa
known_hosts_file: ${SALT_PUSH_DIR}/ssh/known_hosts
log_file: ${SALT_PUSH_DIR}/logs/ssh
ssh_log_file: ${SALT_PUSH_DIR}/logs/ssh
log_level_logfile: ${SALT_LOGFILE_LEVEL}
# Custom modules/returners shipped with this image (e.g. push_result)
module_dirs:
  - /opt/salt-push${result_master_extra}
default_include: ${SALT_PUSH_DIR}/config/ssh.d/*.conf${ssh_include_extra}
EOF

install_python_additional_packages 1>&2

SALT_FORCE_COLOR="${SALT_FORCE_COLOR:-}"
color_args=()
# No TTY in CI, but e.g. GitHub Actions renders ANSI colors in its logs.
[[ ${SALT_FORCE_COLOR,,} == true ]] && color_args=(--force-color)

case "${mode}" in
salt-call)
	set -- salt-call --local --retcode-passthrough "${result_args[@]}" "$@"
	;;
salt)
	# Mirror the `salt` CLI: optional targeting shorthand, then the target
	# expression, dispatched to managed resources via salt-call -r.
	# -T targets by resource type (compound T@ term, excludes the managing
	# minion) — upstream's -T (--make-token) is meaningless without a master.
	tgt_args=()
	have_tgt=""
	case "${1:-}" in
	-E | --pcre)
		tgt_args=(--tgt-type pcre)
		shift
		;;
	-L | --list)
		tgt_args=(--tgt-type list)
		shift
		;;
	-G | --grain)
		tgt_args=(--tgt-type grain)
		shift
		;;
	-P | --grain-pcre)
		tgt_args=(--tgt-type grain_pcre)
		shift
		;;
	-C | --compound)
		tgt_args=(--tgt-type compound)
		shift
		;;
	-T | --type)
		if [[ -z ${2:-} || ${2} == -* ]]; then
			log_error "-T/--type requires a resource type expression (e.g. github or github:owner/repo)"
			exit 1
		fi
		tgt_args=(--tgt "T@${2}" --tgt-type compound)
		have_tgt=1
		shift 2
		;;
	esac
	if [[ -z ${have_tgt} ]]; then
		if (($#)) && [[ ${1} != -* ]]; then
			tgt_args+=(--tgt "${1}")
			shift
		elif ((${#tgt_args[@]})); then
			log_error "A target type was given without a target expression"
			exit 1
		fi
	fi
	set -- salt-call --local --retcode-passthrough -r "${tgt_args[@]}" "${result_args[@]}" "$@"
	;;
salt-ssh)
	[[ -f ${roster_file} ]] || log_warn "No roster at ${roster_file} (mount one or set SALT_ROSTER)"
	set -- salt-ssh "$@"
	;;
esac
set -- "${1}" --log-level="${SALT_LOG_LEVEL}" "${color_args[@]}" "${@:2}"

if [[ -n ${SALT_PUSH_USER} && ${SALT_PUSH_USER} != root ]]; then
	# Top-level chown only: makes fresh (CI-runner-owned) mounts writable, while
	# files below were created by this same user on previous runs.
	chown "${SALT_PUSH_USER}:" \
		"${SALT_PUSH_DIR}/cache" "${SALT_PUSH_DIR}/cache/minion" \
		"${SALT_PUSH_DIR}/cache/master" "${SALT_PUSH_DIR}/logs" /var/run/salt/minion
	chown -R "${SALT_PUSH_USER}:" "${SALT_PUSH_DIR}/ssh" 2>/dev/null ||
		log_info "${SALT_PUSH_DIR}/ssh not writable, assuming user-managed contents"
	chown -R "${SALT_PUSH_USER}:" "${SALT_ROOT_DIR}"
	set -- sudo -HEu "${SALT_PUSH_USER}" "$@"
fi
[[ ${user_scrub} == true ]] || exec "$@"

# SALT_SCRUB_CACHE=true: run the tool as a child so the known sensitive
# cache paths (see scrub_cache above) can be removed afterwards,
# regardless of what wrote them. `defer` skips this — a later `scrub`
# invocation cleans up once, e.g. after a multi-command sequence.
rc=0
"$@" || rc=$?
scrub_cache
exit "${rc}"
