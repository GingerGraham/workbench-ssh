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

PINNED="${REPO_ROOT}/files/known_hosts.forges"

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
if cmp -s "${HOME}/.ssh/known_hosts.d/workbench-forges" "${PINNED}"; then
    ok "known_hosts.d/workbench-forges equals files/known_hosts.forges"
else
    fail "known_hosts.d/workbench-forges differs from files/known_hosts.forges"
fi

# 5
case "${out}" in
    *"[WARN]"*"github.com"*"not in the pinned set"*) ok "audit [WARN] line printed for github.com" ;;
    *) fail "no audit [WARN] for github.com in output: ${out}" ;;
esac

# 6
if grep -q '^ *UserKnownHostsFile .*known_hosts\.d/workbench-forges' "${HOME}/.ssh/workbench-defaults.conf"; then
    ok "installed workbench-defaults.conf contains the UserKnownHostsFile line"
else
    fail "workbench-defaults.conf lacks the UserKnownHostsFile line"
fi

# 7 -- defaults are included last, under Match all, and not from config.d/
if [[ ! -e "${HOME}/.ssh/config.d/00-defaults.conf" ]] \
    && [[ "$(tail -n 2 "${HOME}/.ssh/config")" == "Match all
Include ~/.ssh/workbench-defaults.conf" ]]; then
    ok "defaults included at the end of ~/.ssh/config under Match all"
else
    fail "defaults Include is not the last thing in ~/.ssh/config"
fi

# 8 -- idempotent: a second run adds no second Include
(cd "${REPO_ROOT}" && bash hooks/post-deploy.sh >/dev/null 2>&1)
if [[ "$(grep -c 'workbench-defaults.conf' "${HOME}/.ssh/config")" -eq 1 ]]; then
    ok "second hook run does not duplicate the defaults Include"
else
    fail "defaults Include duplicated after a second hook run"
fi

# 9 -- legacy managed config.d/00-defaults.conf is removed; a foreign one is not
printf '# managed by workbench-ssh\n' > "${HOME}/.ssh/config.d/00-defaults.conf"
(cd "${REPO_ROOT}" && bash hooks/post-deploy.sh >/dev/null 2>&1)
if [[ ! -e "${HOME}/.ssh/config.d/00-defaults.conf" ]]; then
    ok "legacy managed config.d/00-defaults.conf removed"
else
    fail "legacy config.d/00-defaults.conf still present"
fi
printf '# my own file\n' > "${HOME}/.ssh/config.d/00-defaults.conf"
(cd "${REPO_ROOT}" && bash hooks/post-deploy.sh >/dev/null 2>&1)
if [[ -e "${HOME}/.ssh/config.d/00-defaults.conf" ]]; then
    ok "user-owned config.d/00-defaults.conf left alone"
else
    fail "user-owned config.d/00-defaults.conf was deleted"
fi
rm -f "${HOME}/.ssh/config.d/00-defaults.conf"

# 10+ -- real ssh -G behaviour. ssh expands ~ from the passwd entry, not
# $HOME, so rewrite the tilde paths in the generated config to absolute ones.
if command -v ssh >/dev/null 2>&1; then
    cat > "${HOME}/.ssh/config.d/20-user.conf" <<'USER'
Host override.example
    ForwardAgent yes
    ServerAliveInterval 5
Host github.com
    ControlMaster no
Host optin.example
    ControlMaster auto
USER
    printf 'Host star.example\n    ForwardAgent yes\n' > "${HOME}/.ssh/config.d/30-star.conf"
    sed "s#~/.ssh/#${HOME}/.ssh/#g" "${HOME}/.ssh/config" > "${HOME}/test_config"
    gval() { ssh -G "$1" -F "${HOME}/test_config" 2>/dev/null | grep -i "^$2 " | head -n 1; }

    g="$(gval github.com userknownhostsfile)"
    case "${g}" in
        *known_hosts*known_hosts.d/workbench-forges*) ok "ssh -G lists both known-hosts files" ;;
        *) fail "ssh -G userknownhostsfile: ${g}" ;;
    esac

    # expect <description> <host> <keyword> <expected value>
    expect() {
        local got
        got="$(gval "$2" "$3")"
        if [[ "${got}" == "$3 $4" ]]; then ok "$1"; else fail "$1 (got: ${got})"; fi
    }

    # multiplexing is scoped to the forges (security review M8)
    expect "ssh -G example.com: controlmaster false" example.com controlmaster false
    expect "ssh -G gitlab.com: controlmaster auto" gitlab.com controlmaster auto

    # user settings win over module defaults, wherever they live
    expect "per-host ForwardAgent yes in config.d beats the module default" override.example forwardagent yes
    expect "per-host ServerAliveInterval beats the module default" override.example serveraliveinterval 5
    expect "user can opt a forge out of ControlMaster" github.com controlmaster false
    expect "user can opt a host in to ControlMaster" optin.example controlmaster auto
    expect "later config.d file beats the module default" star.example forwardagent yes

    # defaults still apply where the user set nothing
    expect "unset host still gets ForwardAgent no" other.example forwardagent no
    expect "unset host still gets ServerAliveInterval 60" other.example serveraliveinterval 60
else
    ok "ssh not installed -- ssh -G checks skipped"
fi

echo
if [[ ${FAILED} -eq 0 ]]; then
    echo "All ${check_no} checks passed."
else
    echo "${FAILED} of ${check_no} checks FAILED."
    exit 1
fi
