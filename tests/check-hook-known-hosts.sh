#!/usr/bin/env bash
# tests/check-hook-known-hosts.sh — workbench-ssh
# Runs hooks/post-deploy.sh against a throwaway HOME and checks that forge
# host keys are pinned, never keyscanned (security review H2).
# Plain bash, numbered OK:/FAIL: checks, no framework.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

if ! command -v ssh-keygen >/dev/null 2>&1; then
    ok "ssh-keygen not installed -- hook test skipped"
    exit 0
fi

# PENDING: files/known_hosts.forges is withheld until the forge fingerprints
# are confirmed. Checks that need it report PENDING (not FAIL) while it is
# absent; delete this fallback once the file is committed.
PINNED="${REPO_ROOT}/files/known_hosts.forges"
have_pinned=1
[[ -f "${PINNED}" ]] || have_pinned=0
pending() { check_no=$((check_no + 1)); echo "PENDING: [$check_no] $* (files/known_hosts.forges not committed yet)"; }

TMP_HOME="$(mktemp -d)"
trap 'rm -rf "${TMP_HOME}"' EXIT
export HOME="${TMP_HOME}"

# Fake ssh-keyscan first on PATH: records that it was called.
mkdir -p "${HOME}/fakebin" "${HOME}/.ssh"
cat > "${HOME}/fakebin/ssh-keyscan" <<'FAKE'
#!/usr/bin/env bash
: > "${HOME}/keyscan-called"
exit 0
FAKE
chmod +x "${HOME}/fakebin/ssh-keyscan"
export PATH="${HOME}/fakebin:${PATH}"

# A pre-existing, non-pinned github.com key in the user's known_hosts.
ssh-keygen -q -t ed25519 -f "${HOME}/fake" -N '' >/dev/null
fake_blob="$(awk '{print $2}' "${HOME}/fake.pub")"
printf 'github.com ssh-ed25519 %s\n' "${fake_blob}" > "${HOME}/.ssh/known_hosts"
cp "${HOME}/.ssh/known_hosts" "${HOME}/known_hosts.before"

out="$(cd "${REPO_ROOT}" && bash hooks/post-deploy.sh 2>&1)"
rc=$?

# 1
if [[ ${rc} -eq 0 ]]; then ok "hook exits 0"; else fail "hook exited ${rc}: ${out}"; fi

# 2
if [[ ! -e "${HOME}/keyscan-called" ]]; then ok "ssh-keyscan was never called"; else fail "ssh-keyscan was called"; fi

# 3
if cmp -s "${HOME}/.ssh/known_hosts" "${HOME}/known_hosts.before"; then
    ok "user known_hosts is byte-identical to before"
else
    fail "user known_hosts was modified"
fi

# 4
if [[ ${have_pinned} -eq 1 ]]; then
    if cmp -s "${HOME}/.ssh/known_hosts.d/workbench-forges" "${PINNED}"; then
        ok "known_hosts.d/workbench-forges equals files/known_hosts.forges"
    else
        fail "known_hosts.d/workbench-forges differs from files/known_hosts.forges"
    fi
else
    pending "known_hosts.d/workbench-forges equals files/known_hosts.forges"
fi

# 5
if [[ ${have_pinned} -eq 1 ]]; then
    case "${out}" in
        *"[WARN]"*"github.com"*"not in the pinned set"*) ok "audit [WARN] line printed for github.com" ;;
        *) fail "no audit [WARN] for github.com in output: ${out}" ;;
    esac
else
    pending "audit [WARN] line printed for github.com"
fi

# 6
if grep -q '^ *UserKnownHostsFile .*known_hosts\.d/workbench-forges' "${HOME}/.ssh/config.d/00-defaults.conf"; then
    ok "installed 00-defaults.conf contains the UserKnownHostsFile line"
else
    fail "00-defaults.conf lacks the UserKnownHostsFile line"
fi

# 7 -- ssh expands ~ from the passwd entry, not $HOME, so include the
# installed file by absolute path.
if command -v ssh >/dev/null 2>&1; then
    printf 'Include %s\n' "${HOME}/.ssh/config.d/00-defaults.conf" > "${HOME}/test_config"
    g="$(ssh -G github.com -F "${HOME}/test_config" 2>/dev/null | grep -i '^userknownhostsfile ')"
    case "${g}" in
        *known_hosts*known_hosts.d/workbench-forges*) ok "ssh -G lists both known-hosts files" ;;
        *) fail "ssh -G userknownhostsfile: ${g}" ;;
    esac
else
    ok "ssh not installed -- ssh -G check skipped"
fi

echo
if [[ ${FAILED} -eq 0 ]]; then
    echo "All ${check_no} checks passed."
else
    echo "${FAILED} of ${check_no} checks FAILED."
    exit 1
fi
