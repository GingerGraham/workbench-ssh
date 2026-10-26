#!/usr/bin/env bash
# tests/check-agent-scaffold.sh — workbench-ssh
# ssh-agent-scaffold (shell/ssh.sh) against a throwaway HOME: it creates
# ~/.ssh/config.d/01-agent.conf from the deployed template with modes
# 700/600, never overwrites a file that's already there, and errors when
# the template hasn't been deployed. Plain bash, numbered OK:/FAIL: checks,
# no framework.
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

TMP_HOME="$(mktemp -d)"
trap 'rm -rf "${TMP_HOME}"' EXIT
export HOME="${TMP_HOME}"

# workbench-core's log functions, as the loader provides them.
log_info()  { echo "[INFO] $*"; }
log_warn()  { echo "[WARN] $*"; }
log_error() { echo "[ERROR] $*"; }
_wb_declare_availability() { :; }
# shellcheck source=shell/ssh.sh
source "${REPO_ROOT}/shell/ssh.sh"

TEMPLATE_DIR="${HOME}/.local/share/workbench/modules/ssh/files"
TARGET="${HOME}/.ssh/config.d/01-agent.conf"

# Portable octal mode: GNU stat, then BSD stat.
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

# 1–2. Template not deployed: an error naming the fix, nothing created.
out="$(ssh-agent-scaffold 2>&1)"; rc=$?
[[ "${rc}" -ne 0 && "${out}" == *"wb update ssh"* ]] \
    && ok "no template: errors and says to run 'wb update ssh'" \
    || fail "no template: rc ${rc}, ${out}"
[[ ! -e "${TARGET}" ]] && ok "no template: nothing created" || fail "no template: ${TARGET} was created"

mkdir -p "${TEMPLATE_DIR}"
cp "${REPO_ROOT}/files/01-agent.conf" "${TEMPLATE_DIR}/01-agent.conf"

# 3–5. First run: the template, copied, with private modes.
out="$(ssh-agent-scaffold 2>&1)"; rc=$?
[[ "${rc}" -eq 0 ]] && cmp -s "${TARGET}" "${REPO_ROOT}/files/01-agent.conf" \
    && ok "creates config.d/01-agent.conf from the template" \
    || fail "create: rc ${rc}, ${out}"
[[ "$(mode_of "${HOME}/.ssh/config.d")" == "700" ]] \
    && ok "config.d is mode 700" || fail "config.d mode $(mode_of "${HOME}/.ssh/config.d")"
[[ "$(mode_of "${TARGET}")" == "600" ]] \
    && ok "01-agent.conf is mode 600" || fail "01-agent.conf mode $(mode_of "${TARGET}")"

# 6–7. An existing file — the user's edits — is left exactly as it is.
printf 'Host *\n    IdentityAgent ~/my.sock\n' > "${TARGET}"
cp "${TARGET}" "${HOME}/before"
out="$(ssh-agent-scaffold 2>&1)"; rc=$?
[[ "${rc}" -eq 0 && "${out}" == *"already exists"* ]] \
    && ok "existing file: exits 0 and says it's left unchanged" \
    || fail "existing file: rc ${rc}, ${out}"
cmp -s "${TARGET}" "${HOME}/before" \
    && ok "existing file is byte-identical to before" \
    || fail "existing file was overwritten"

echo
echo "==============================="
echo "Total OK/FAIL checks: ${check_no}, failed: ${FAILED}"
echo "==============================="
[[ "${FAILED}" -eq 0 ]]
