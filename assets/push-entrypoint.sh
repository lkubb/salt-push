#!/usr/bin/env bash

# Adds a one-shot interface on top of docker-salt-master's entrypoint:
#
#   docker run --rm <image> salt-call [args...]            # standalone (--local)
#   docker run --rm <image> salt [-ELGPCT] <target> [args] # resource dispatch (salt-call -r)
#   docker run --rm <image> salt-ssh <target> [args...]    # salt-ssh
#
# `salt-call` defaults to `state.highstate` when no further arguments are given.
# Anything else is handed to the upstream entrypoint unchanged.
# (`docker exec` bypasses this entrypoint and always runs the plain binaries.)

set -eo pipefail

print_help() {
	cat <<'EOF'
salt-push — one-shot Salt in push mode (on top of docker-salt-master)

Usage:
  salt-call [salt-call args...]
      Run salt-call --local --retcode-passthrough against the mounted
      state tree. Defaults to state.highstate.
  salt [-E|-L|-G|-P|-C|-T] <target> [args...]
      Dispatch to managed resources (salt-call -r) with per-target
      output, like the salt CLI. Resources are declared under the
      'resources:' pillar key; inspect them via 'salt-call resource.list'.
  salt-ssh <target> [salt-ssh args...]
      Run salt-ssh using the roster at /app/roster.

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

case "${1:-}" in
salt | salt-call | salt-ssh)
	mode="${1}"
	shift
	;;
help | -h | --help)
	print_help
	exit 0
	;;
"")
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

# Upstream helpers: logging, map_uidgid and
# install_python_additional_packages. Not nounset-safe, so no set -u here.
# shellcheck source=/dev/null
source "${SALT_RUNTIME_DIR}/functions.sh"

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

# SALT_RESOURCES: YAML mapping placed under the `resources:` pillar key.
# Served via ext_pillar instead of a generated pillar root: a second top.sls
# in the same env silently loses against a user-mounted one.
ext_pillar_extra=""
if [[ -n ${user_resources} ]]; then
	{
		echo "resources:"
		echo "  ${user_resources//$'\n'/$'\n'  }"
	} >"${SALT_ROOT_DIR}/push_resources.yaml"
	ext_pillar_extra="
ext_pillar:
  - cmd_yaml: cat ${SALT_ROOT_DIR}/push_resources.yaml"
fi

# SALT_ROSTER: roster contents, written to a generated file that takes
# precedence over a mounted ${SALT_PUSH_DIR}/roster.
roster_file="${SALT_PUSH_DIR}/roster"
if [[ -n ${user_roster} ]]; then
	roster_file="${SALT_ROOT_DIR}/roster"
	[[ -f "${SALT_PUSH_DIR}/roster" ]] && log_warn "SALT_ROSTER overrides the mounted roster"
	printf '%s\n' "${user_roster}" >"${roster_file}"
fi

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
log_level_logfile: ${SALT_LOGFILE_LEVEL}
# Reverse DNS of ephemeral container IPs yields nothing and stalls startup
# where resolvers are slow.
enable_fqdns_grains: False
# Custom modules shipped with this image (e.g. resource.list)
module_dirs:
  - /opt/salt-push
default_include: ${SALT_PUSH_DIR}/config/minion.d/*.conf
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
default_include: ${SALT_PUSH_DIR}/config/ssh.d/*.conf
EOF

install_python_additional_packages

SALT_FORCE_COLOR="${SALT_FORCE_COLOR:-}"
color_args=()
# No TTY in CI, but e.g. GitHub Actions renders ANSI colors in its logs.
[[ ${SALT_FORCE_COLOR,,} == true ]] && color_args=(--force-color)

case "${mode}" in
salt-call)
	(($#)) || set -- state.highstate
	set -- salt-call --local --retcode-passthrough "$@"
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
	set -- salt-call --local --retcode-passthrough -r "${tgt_args[@]}" "$@"
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
	exec sudo -HEu "${SALT_PUSH_USER}" "$@"
fi
exec "$@"
