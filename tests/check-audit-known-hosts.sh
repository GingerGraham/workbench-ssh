#!/usr/bin/env bash
# tests/check-audit-known-hosts.sh — workbench-ssh
# ssh-audit-known-hosts (shell/ssh.sh) against a throwaway HOME: it reports
# a forge key in ~/.ssh/known_hosts that isn't pinned, stays quiet about a
# pinned one, never calls ssh-keyscan and never writes known_hosts
# (security review H2). Plain bash, numbered OK:/FAIL: checks, no framework.
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

if ! command -v ssh-keygen >/dev/null 2>&1; then
    echo "SKIP: ssh-keygen not installed"
    exit 0
fi

TMP_HOME="$(mktemp -d)"
trap 'rm -rf "${TMP_HOME}"' EXIT
export HOME="${TMP_HOME}"

# workbench-core's log functions, as the loader provides them.
log_info()  { echo "[INFO] $*"; }
log_warn()  { echo "[WARN] $*"; }
log_error() { echo "[ERROR] $*"; }
# shellcheck source=shell/ssh.sh
source "${REPO_ROOT}/shell/ssh.sh"

# Fake ssh-keyscan first on PATH: records that it was called.
mkdir -p "${HOME}/fakebin" "${HOME}/.ssh"
cat > "${HOME}/fakebin/ssh-keyscan" <<'FAKE'
#!/usr/bin/env bash
: > "${HOME}/keyscan-called"
exit 0
FAKE
chmod +x "${HOME}/fakebin/ssh-keyscan"
export PATH="${HOME}/fakebin:${PATH}"

PINNED_DIR="${HOME}/.local/share/workbench/modules/ssh/files"

# 1. Not deployed yet: an error naming the fix.
out="$(ssh-audit-known-hosts 2>&1)"; rc=$?
[[ "${rc}" -ne 0 && "${out}" == *"wb update ssh"* ]] \
    && ok "no pinned file: errors and says to run 'wb update ssh'" \
    || fail "no pinned file: rc ${rc}, ${out}"

mkdir -p "${PINNED_DIR}"
cp "${REPO_ROOT}/files/known_hosts.forges" "${PINNED_DIR}/known_hosts.forges"

# 2. No known_hosts: nothing to audit.
out="$(ssh-audit-known-hosts 2>&1)"; rc=$?
[[ "${rc}" -eq 0 && "${out}" == *"nothing to audit"* ]] \
    && ok "no ~/.ssh/known_hosts: nothing to audit" \
    || fail "no known_hosts: rc ${rc}, ${out}"

# A pinned github.com key, and an unpinned one.
pinned_line="$(grep -m 1 '^github.com ' "${REPO_ROOT}/files/known_hosts.forges")"
ssh-keygen -q -t ed25519 -f "${HOME}/fake" -N '' >/dev/null
fake_blob="$(awk '{print $2}' "${HOME}/fake.pub")"

# 3. Only pinned keys: a clean summary, no warning.
printf '%s\n' "${pinned_line}" > "${HOME}/.ssh/known_hosts"
out="$(ssh-audit-known-hosts 2>&1)"; rc=$?
[[ "${rc}" -eq 0 && "${out}" != *"[WARN]"* && "${out}" == *"in the pinned set"* ]] \
    && ok "pinned key only: no warning, clean summary" \
    || fail "pinned key only: rc ${rc}, ${out}"

# 4–6. An unpinned key: one warning naming the forge, and a count.
printf 'github.com ssh-ed25519 %s\n' "${fake_blob}" >> "${HOME}/.ssh/known_hosts"
cp "${HOME}/.ssh/known_hosts" "${HOME}/known_hosts.before"
out="$(ssh-audit-known-hosts 2>&1)"; rc=$?
[[ "${rc}" -eq 0 ]] && ok "audit exits 0" || fail "audit exited ${rc}: ${out}"
[[ "$(printf '%s\n' "${out}" | grep -c '^\[WARN\].*github.com.*not in the pinned set')" -eq 1 ]] \
    && ok "exactly one [WARN] line, for the unpinned github.com key" \
    || fail "warnings: ${out}"
[[ "${out}" == *"1 forge key(s)"* && "${out}" == *"ssh-keygen -R github.com"* ]] \
    && ok "summary counts it and names the fix" \
    || fail "summary: ${out}"

# 7–8. Read-only.
[[ ! -e "${HOME}/keyscan-called" ]] && ok "ssh-keyscan was never called" || fail "ssh-keyscan was called"
cmp -s "${HOME}/.ssh/known_hosts" "${HOME}/known_hosts.before" \
    && ok "the user's known_hosts is byte-identical to before" \
    || fail "the user's known_hosts was modified"

# 9–10. The same fixtures in zsh, which sources shell/ssh.sh too. An
# unquoted "${forges}" loop didn't word-split there, so the audit ran once
# over the whole string and reported a false all-clear.
# zsh_audit: runs ssh-audit-known-hosts in a fresh zsh against this HOME.
zsh_audit() {
    zsh -fc '
        log_info()  { echo "[INFO] $*"; }
        log_warn()  { echo "[WARN] $*"; }
        log_error() { echo "[ERROR] $*"; }
        source "$1" && ssh-audit-known-hosts
    ' zsh "${REPO_ROOT}/shell/ssh.sh" 2>&1
}
if ! command -v zsh >/dev/null 2>&1; then
    echo "SKIP: zsh not installed — zsh checks skipped"
else
    out="$(zsh_audit)"
    [[ "$(printf '%s\n' "${out}" | grep -c '^\[WARN\].*github.com.*not in the pinned set')" -eq 1 \
        && "${out}" == *"1 forge key(s)"* ]] \
        && ok "zsh: the unpinned github.com key is flagged" \
        || fail "zsh: unpinned key: ${out}"
    printf '%s\n' "${pinned_line}" > "${HOME}/.ssh/known_hosts"
    out="$(zsh_audit)"
    [[ "${out}" != *"[WARN]"* && "${out}" == *"every forge key"* ]] \
        && ok "zsh: pinned key only: no warning, clean summary" \
        || fail "zsh: pinned key only: ${out}"
fi

echo
echo "==============================="
echo "Total OK/FAIL checks: ${check_no}, failed: ${FAILED}"
echo "==============================="
[[ "${FAILED}" -eq 0 ]]
