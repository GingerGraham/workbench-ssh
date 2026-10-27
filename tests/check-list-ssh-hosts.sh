#!/usr/bin/env bash
# tests/check-list-ssh-hosts.sh — workbench-ssh
# list-ssh-hosts (shell/ssh.sh) against a throwaway HOME, in bash and zsh:
# an empty ~/.ssh/config.d isn't an error (it was a "no matches" glob error
# in zsh), files are listed in sorted order, dotfiles are skipped and a
# symlink to a file counts. Plain bash, numbered OK:/FAIL: checks, no
# framework.
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
mkdir -p "${HOME}/.ssh/config.d"
printf 'Host main.example\n    User me\n' > "${HOME}/.ssh/config"

# run_list <shell>: list-ssh-hosts in a fresh bash or zsh against this HOME.
run_list() {
    # SC2016: the script is expanded by the inner shell, not here.
    # shellcheck disable=SC2016
    "$1" -c '
        [ -n "${ZSH_VERSION:-}" ] && emulate -R zsh
        log_info()  { echo "[INFO] $*"; }
        log_warn()  { echo "[WARN] $*"; }
        log_error() { echo "[ERROR] $*"; }
        _wb_declare_availability() { :; }
        source "$1" && list-ssh-hosts
    ' "$1" "${REPO_ROOT}/shell/ssh.sh" 2>&1
}

shells="bash"
if command -v zsh >/dev/null 2>&1; then
    shells="bash zsh"
else
    echo "SKIP: zsh not installed — zsh checks skipped"
fi

for sh in ${shells}; do
    rm -rf "${HOME}/.ssh/config.d" "${HOME}/elsewhere.conf"
    mkdir -p "${HOME}/.ssh/config.d"

    out="$(run_list "${sh}")"; rc=$?
    [[ "${rc}" -eq 0 && "${out}" == *"main.example"* && "${out}" != *"no matches"* && "${out}" != *"==="*".conf"* ]] \
        && ok "${sh}: empty config.d — main config listed, no error" \
        || fail "${sh}: empty config.d: rc ${rc}, ${out}"

    printf 'Host b.example\n' > "${HOME}/.ssh/config.d/20-b.conf"
    printf 'Host a.example\n' > "${HOME}/.ssh/config.d/10-a.conf"
    printf 'Host hidden.example\n' > "${HOME}/.ssh/config.d/.swap.conf"
    printf 'Host linked.example\n' > "${HOME}/elsewhere.conf"
    ln -s "${HOME}/elsewhere.conf" "${HOME}/.ssh/config.d/30-linked.conf"
    mkdir "${HOME}/.ssh/config.d/sub.d"
    out="$(run_list "${sh}")"; rc=$?
    headers="$(printf '%s\n' "${out}" | grep '^===' | tr '\n' ' ')"
    [[ "${rc}" -eq 0 && "${headers}" == "=== Main Config === === 10-a.conf === === 20-b.conf === === 30-linked.conf === " ]] \
        && ok "${sh}: files in sorted order, symlink included, dotfile and directory skipped" \
        || fail "${sh}: headers '${headers}', rc ${rc}, ${out}"
    [[ "${out}" == *"linked.example"* && "${out}" != *"hidden.example"* ]] \
        && ok "${sh}: hosts from the listed files only" \
        || fail "${sh}: hosts: ${out}"
done

echo
echo "==============================="
echo "Total OK/FAIL checks: ${check_no}, failed: ${FAILED}"
echo "==============================="
[[ "${FAILED}" -eq 0 ]]
