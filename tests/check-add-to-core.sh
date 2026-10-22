#!/usr/bin/env bash
# tests/check-add-to-core.sh — workbench-ssh
# Run by workbench-core's module CI ("add to core", step 8) with WB,
# MODULE_NAME, MODULE_URL, MODULE_BRANCH and MODULE_ROOT set. Builds its own
# scratch HOME seeded with a user's ~/.ssh/config — including the block the
# pre-D82 post-deploy hook appended — then adds this branch of the module
# the way the shared check does, and proves the ssh_config layers
# (workbench-core docs/decisions-log.md D82): the user's settings win, the
# module's defaults apply underneath, the pinned forge keys are in use, and
# the old hook block is gone.
#
# ssh reads ~ from the passwd entry, not $HOME: every ssh call names the
# scratch config with -F, and paths ssh expands from ~ are matched by their
# suffix.
#
# SC2015: '[[ cond ]] && ok || fail' is this suite's assertion idiom.
# shellcheck disable=SC2015
set -uo pipefail

# Module CI's structural-tests job also runs every tests/check-*.sh on its
# own, without a core checkout: nothing to add the module to there.
if [[ -z "${WB:-}" || -z "${MODULE_NAME:-}" || -z "${MODULE_URL:-}" || -z "${MODULE_BRANCH:-}" ]]; then
    echo "SKIP: needs WB, MODULE_NAME, MODULE_URL and MODULE_BRANCH — run by workbench-core's module CI ('add to core', step 8)"
    exit 0
fi
if ! command -v ssh &>/dev/null; then
    echo "SKIP: ssh not installed"
    exit 0
fi

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
export HOME="${WORK}/home"
export XDG_CONFIG_HOME="${HOME}/.config"
export XDG_DATA_HOME="${HOME}/.local/share"
mkdir -p "${HOME}/.ssh"
chmod 700 "${HOME}/.ssh"

# A user's own ~/.ssh/config, as the old hook left it: its Include on the
# first line, the user's settings, its defaults block appended at the end.
cat > "${HOME}/.ssh/config" <<'CONFIG'
Include ~/.ssh/config.d/*.conf
Host *
    ServerAliveInterval 15

# workbench-ssh defaults: keep last so your own settings above win.
Match all
Include ~/.ssh/workbench-defaults.conf
CONFIG
chmod 600 "${HOME}/.ssh/config"

run() { "$@" >"${WORK}/out.log" 2>&1 || { echo "--- $* failed:"; cat "${WORK}/out.log"; return 1; }; }
run "${WB}" add "${MODULE_NAME}" "${MODULE_URL}" --keep-files </dev/null || fail "wb add"
run "${WB}" track "${MODULE_NAME}" --branch "${MODULE_BRANCH}" </dev/null || fail "wb track"
run "${WB}" update "${MODULE_NAME}" </dev/null || fail "wb update"

C="${HOME}/.ssh/config"
gval() { ssh -F "${C}" -G example.invalid 2>/dev/null | grep -i "^$1 " | head -n 1; }

[[ "$(gval serveraliveinterval)" == "serveraliveinterval 15" ]] \
    && ok "your ServerAliveInterval (15) wins over the module's default" \
    || { fail "serveraliveinterval: '$(gval serveraliveinterval)'"; cat "${C}"; }
[[ "$(gval hashknownhosts)" == "hashknownhosts yes" ]] \
    && ok "the module's HashKnownHosts applies where you set none" \
    || fail "hashknownhosts: '$(gval hashknownhosts)'"
[[ "$(gval userknownhostsfile)" == *"/.local/share/workbench/modules/ssh/files/known_hosts.forges" ]] \
    && ok "the pinned forge keys are the second known-hosts file" \
    || fail "userknownhostsfile: '$(gval userknownhostsfile)'"
[[ -f "${XDG_DATA_HOME}/workbench/modules/ssh/files/known_hosts.forges" ]] \
    && ok "known_hosts.forges is deployed" \
    || fail "known_hosts.forges not deployed"

if grep -q 'workbench-defaults.conf' "${C}"; then
    fail "the old hook's defaults block is still in ~/.ssh/config:"; cat "${C}"
else
    ok "the old hook's defaults block is gone"
fi
grep -qxF 'Include ~/.ssh/config.d/*.conf' "${C}" && grep -qxF '    ServerAliveInterval 15' "${C}" \
    && ok "your own lines are untouched" \
    || { fail "user lines changed"; cat "${C}"; }
[[ "$(head -n 1 "${C}")" == "# >>> workbench ${MODULE_NAME}/ssh_config over >>>" \
    && "$(tail -n 1 "${C}")" == "# <<< workbench ${MODULE_NAME}/ssh_config under <<<" ]] \
    && ok "config.d block at the top, defaults block at the end" \
    || { fail "block positions"; cat "${C}"; }
[[ ! -e "${HOME}/.ssh/config.d/01-agent.conf" ]] \
    && ok "01-agent.conf isn't created on install (ssh-agent-scaffold does that)" \
    || fail "01-agent.conf was created on install"

echo
echo "==============================="
echo "Total OK/FAIL checks: ${check_no}, failed: ${FAILED}"
echo "==============================="
[[ "${FAILED}" -eq 0 ]]
