#!/usr/bin/env bash
# tests/check-ssh-copy-bw.sh — workbench-ssh
# ssh-copy-bw (shell/ssh.sh) against a fake ssh-add and a fake ssh that runs
# the remote command locally in a scratch "remote" HOME: the first argument
# is the destination whatever its form, the key pattern is plain text (even
# when it starts with "-"), and a re-run doesn't duplicate keys in
# authorized_keys. Plain bash, numbered OK:/FAIL: checks, no framework.
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
export REMOTE_HOME="${TMP_HOME}/remote"
mkdir -p "${HOME}/fakebin" "${REMOTE_HOME}"

# workbench-core's functions, as the loader provides them.
log_info()  { echo "[INFO] $*"; }
log_warn()  { echo "[WARN] $*"; }
log_error() { echo "[ERROR] $*"; }
_wb_declare_availability() { :; }
# shellcheck source=shell/ssh.sh
source "${REPO_ROOT}/shell/ssh.sh"

# Three keys in the "agent". The third one's comment starts with "-".
cat > "${HOME}/fakebin/ssh-add" <<'FAKE'
#!/bin/sh
[ "$1" = "-L" ] || exit 2
echo "ssh-ed25519 AAAAone My Key"
echo "ssh-ed25519 AAAAtwo work-2025-01-30"
echo "ssh-rsa AAAAthree -dash.key"
FAKE
# ssh <destination> <command>: records the destination, then runs the
# command with sh in the remote HOME, stdin passed through.
cat > "${HOME}/fakebin/ssh" <<'FAKE'
#!/bin/sh
printf '%s\n' "$1" > "${REMOTE_HOME}/destination"
HOME="${REMOTE_HOME}" exec sh -c "$2"
FAKE
chmod +x "${HOME}/fakebin/ssh-add" "${HOME}/fakebin/ssh"
export PATH="${HOME}/fakebin:${PATH}"

AK="${REMOTE_HOME}/.ssh/authorized_keys"
# Portable octal mode: GNU stat, then BSD stat.
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }
count() { grep -cxF -- "$1" "${AK}" 2>/dev/null || true; }

# 1–3. An ssh_config alias and a key pattern with a space: the alias is the
# destination (the old two-word form made it "myhost@My Key").
out="$(ssh-copy-bw myhost "My Key" 2>&1)"; rc=$?
[[ "${rc}" -eq 0 && "$(cat "${REMOTE_HOME}/destination")" == "myhost" ]] \
    && ok "alias + pattern: ssh gets 'myhost' as the destination" \
    || fail "alias + pattern: rc ${rc}, dest '$(cat "${REMOTE_HOME}/destination" 2>/dev/null)', ${out}"
[[ "$(count "ssh-ed25519 AAAAone My Key")" -eq 1 && "$(wc -l < "${AK}" | tr -d ' ')" -eq 1 ]] \
    && ok "only the matching key is added" \
    || fail "authorized_keys after first run: $(cat "${AK}" 2>/dev/null)"
[[ "$(mode_of "${REMOTE_HOME}/.ssh")" == "700" && "$(mode_of "${AK}")" == "600" ]] \
    && ok "remote ~/.ssh is 700, authorized_keys 600" \
    || fail "modes: $(mode_of "${REMOTE_HOME}/.ssh") $(mode_of "${AK}")"

# 4. A re-run adds nothing.
ssh-copy-bw myhost "My Key" >/dev/null 2>&1
[[ "$(count "ssh-ed25519 AAAAone My Key")" -eq 1 && "$(wc -l < "${AK}" | tr -d ' ')" -eq 1 ]] \
    && ok "re-run: no duplicate key" \
    || fail "re-run duplicated: $(cat "${AK}")"

# 5. A pattern starting with "-" is a pattern, not a grep option.
out="$(ssh-copy-bw user@server.example "-dash" 2>&1)"; rc=$?
[[ "${rc}" -eq 0 && "$(count "ssh-rsa AAAAthree -dash.key")" -eq 1 \
    && "$(cat "${REMOTE_HOME}/destination")" == "user@server.example" ]] \
    && ok "pattern '-dash' matches the key whose comment has it" \
    || fail "pattern '-dash': rc ${rc}, ${out}"

# 6. The pattern is plain text, not a regex: "AAAA.ne" matches nothing.
out="$(ssh-copy-bw myhost "AAAA.ne" 2>&1)"; rc=$?
[[ "${rc}" -ne 0 && "${out}" == *"No keys matching"* ]] \
    && ok "pattern 'AAAA.ne' isn't a regex: no match, error" \
    || fail "regex pattern: rc ${rc}, ${out}"

# 7. A third positional argument is an error, not part of the destination.
out="$(ssh-copy-bw user server.example "My Key" 2>&1)"; rc=$?
[[ "${rc}" -ne 0 && "${out}" == *"Too many arguments"* ]] \
    && ok "three positional arguments: 'Too many arguments'" \
    || fail "three positional arguments: rc ${rc}, ${out}"

# 8. --all adds the rest once, keeps what was there, duplicates nothing.
ssh-copy-bw --all myhost >/dev/null 2>&1
ssh-copy-bw --all myhost >/dev/null 2>&1
[[ "$(wc -l < "${AK}" | tr -d ' ')" -eq 3 && "$(count "ssh-ed25519 AAAAtwo work-2025-01-30")" -eq 1 ]] \
    && ok "--all twice: three keys, each once" \
    || fail "--all twice: $(cat "${AK}")"

# A failed append on the remote is a failure, not "copied successfully".
rm -f "${AK}"; mkdir -p "${AK}"
out="$(ssh-copy-bw myhost "My Key" 2>&1)"; rc=$?
[[ "${rc}" -ne 0 ]] && ! grep -q "copied successfully" <<<"${out}" \
    && ok "remote append fails: ssh-copy-bw returns non-zero" \
    || fail "remote append failed but rc ${rc}: ${out}"
rmdir "${AK}"

# 9. In zsh, which sources shell/ssh.sh too.
if ! command -v zsh >/dev/null 2>&1; then
    echo "SKIP: zsh not installed — zsh check skipped"
else
    rm -f "${AK}"
    out="$(zsh -fc '
        log_info()  { echo "[INFO] $*"; }
        log_warn()  { echo "[WARN] $*"; }
        log_error() { echo "[ERROR] $*"; }
        _wb_declare_availability() { :; }
        source "$1" && ssh-copy-bw myhost "work-2025"
    ' zsh "${REPO_ROOT}/shell/ssh.sh" 2>&1)"; rc=$?
    [[ "${rc}" -eq 0 && "$(cat "${REMOTE_HOME}/destination")" == "myhost" \
        && "$(count "ssh-ed25519 AAAAtwo work-2025-01-30")" -eq 1 && "$(wc -l < "${AK}" | tr -d ' ')" -eq 1 ]] \
        && ok "zsh: alias + pattern copies the one matching key" \
        || fail "zsh: rc ${rc}, ${out}"
fi

echo
echo "==============================="
echo "Total OK/FAIL checks: ${check_no}, failed: ${FAILED}"
echo "==============================="
[[ "${FAILED}" -eq 0 ]]
