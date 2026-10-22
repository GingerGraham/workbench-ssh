#!/usr/bin/env bash
# tests/check-layer-files.sh — workbench-ssh
# The files workbench-core layers into ~/.ssh/config (workbench-core
# docs/decisions-log.md D82), checked with real 'ssh -G' against a config
# shaped as core writes it: the config.d block at the top, the user's own
# settings, the defaults block at the end under 'Match all'. Proves the
# user's settings win and the module's defaults fill in the rest.
# Plain bash, numbered OK:/FAIL: checks, no framework.
#
# SC2015: '[[ cond ]] && ok || fail' is this suite's assertion idiom.
# shellcheck disable=SC2015
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

if grep -q 'Include ~/.ssh/config.d/\*.conf' "${REPO_ROOT}/files/ssh_config-confd"; then
    ok "files/ssh_config-confd includes ~/.ssh/config.d/*.conf"
else
    fail "files/ssh_config-confd lost its Include"
fi
if grep -Eq '(cm_sockets|known_hosts\.d)' "${REPO_ROOT}/files/00-defaults.conf"; then
    fail "files/00-defaults.conf still names cm_sockets or known_hosts.d"
else
    ok "files/00-defaults.conf names no pre-D82 path"
fi

if ! command -v ssh &>/dev/null; then
    echo "SKIP: ssh not installed — 'ssh -G' checks skipped"
    exit "$([[ "${FAILED}" -eq 0 ]] && echo 0 || echo 1)"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/.ssh/config.d" "${WORK}/files"

# ssh expands ~ from the passwd entry, not $HOME: give the copies absolute
# paths into the scratch directory.
for f in 00-defaults.conf ssh_config-confd; do
    sed "s#~/#${WORK}/#g" "${REPO_ROOT}/files/${f}" > "${WORK}/files/${f}"
done

cat > "${WORK}/.ssh/config.d/20-user.conf" <<'USER'
Host override.example
    ForwardAgent yes
    ServerAliveInterval 5
Host github.com
    ControlMaster no
Host optin.example
    ControlMaster auto
USER
printf 'Host star.example\n    ForwardAgent yes\n' > "${WORK}/.ssh/config.d/30-star.conf"

cat > "${WORK}/.ssh/config" <<CONFIG
# >>> workbench ssh/ssh_config over >>>
Include "${WORK}/files/ssh_config-confd"
# <<< workbench ssh/ssh_config over <<<
Host mine.example
    User someone
# >>> workbench ssh/ssh_config under >>>
Match all
Include "${WORK}/files/00-defaults.conf"
# <<< workbench ssh/ssh_config under <<<
CONFIG

gval() { ssh -G "$1" -F "${WORK}/.ssh/config" 2>/dev/null | grep -i "^$2 " | head -n 1; }
# expect <description> <host> <keyword> <expected value>
expect() {
    local got
    got="$(gval "$2" "$3")"
    if [[ "${got}" == "$3 $4" ]]; then ok "$1"; else fail "$1 (got: ${got})"; fi
}

ssh -G example.com -F "${WORK}/.ssh/config" >/dev/null 2>&1 \
    && ok "ssh parses the layered config" \
    || fail "ssh rejects the layered config: $(ssh -G example.com -F "${WORK}/.ssh/config" 2>&1 | head -n 1)"

expect "pinned forge keys are the second known-hosts file" github.com userknownhostsfile \
    "${WORK}/.ssh/known_hosts ${WORK}/.local/share/workbench/modules/ssh/files/known_hosts.forges"
# ssh -G prints %C expanded: a hash of the connection.
[[ "$(gval gitlab.com controlpath)" =~ ^controlpath\ ${WORK}/\.ssh/cm-[0-9a-f]+$ ]] \
    && ok "forge control path is ~/.ssh/cm-%C" \
    || fail "forge control path: $(gval gitlab.com controlpath)"

# multiplexing is scoped to the forges (security review M8)
expect "example.com: controlmaster false" example.com controlmaster false
expect "gitlab.com: controlmaster auto" gitlab.com controlmaster auto

# user settings win over module defaults, wherever they live
expect "per-host ForwardAgent yes in config.d beats the module default" override.example forwardagent yes
expect "per-host ServerAliveInterval beats the module default" override.example serveraliveinterval 5
expect "user can opt a forge out of ControlMaster" github.com controlmaster false
expect "user can opt a host in to ControlMaster" optin.example controlmaster auto
expect "later config.d file beats the module default" star.example forwardagent yes
expect "a Host block in ~/.ssh/config itself still applies" mine.example user someone

# defaults still apply where the user set nothing — 'Match all' closes the
# user's own Host block above the defaults
expect "unset host still gets ForwardAgent no" other.example forwardagent no
expect "unset host still gets ServerAliveInterval 60" other.example serveraliveinterval 60
expect "unset host still gets HashKnownHosts yes" other.example hashknownhosts yes

echo
echo "==============================="
echo "Total OK/FAIL checks: ${check_no}, failed: ${FAILED}"
echo "==============================="
[[ "${FAILED}" -eq 0 ]]
