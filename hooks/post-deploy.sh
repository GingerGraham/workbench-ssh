#!/usr/bin/env bash
# hooks/post-deploy.sh — workbench-ssh
# Runs on this module's first sync and whenever it updates (run_on: changed,
# per .dotfiles-sync.yml), gated by the machine having registered this
# module with --allow-hooks (docs/module-authoring.md#hooks, in
# workbench-core). WORKBENCH_MODULE_DIR is already this hook's cwd, so
# files/00-defaults.conf and files/01-agent.conf below resolve relative to
# this module's own fetched snapshot.
#
# Replaces workbench-precursor's Ansible ssh role (tasks/main.yml,
# client-defaults.yml, known-hosts.yml): directory setup, the ~/.ssh/config
# Include directive, hardened client defaults, agent-routing scaffold, and
# multi-forge known_hosts pre-trust. This all happens via a hook rather than
# manifest deploy: entries because ~/.ssh/ is on the deploy dest denylist
# (contracts/manifest-spec.md) — the same escape valve workbench-core's own
# lib/ssh/bootstrap.sh uses for the bootstrap-critical deploy-key case (D1).
set -uo pipefail

SSH_DIR="${HOME}/.ssh"
CONFIG_D_DIR="${SSH_DIR}/config.d"
CM_SOCKETS_DIR="${SSH_DIR}/cm_sockets"
CONFIG_PATH="${SSH_DIR}/config"
KNOWN_HOSTS_PATH="${SSH_DIR}/known_hosts"
KEYSCAN_TIMEOUT=10
FORGES="github.com gitlab.com bitbucket.org"

# ── 1. Directories ────────────────────────────────────────────────────────
mkdir -p "${SSH_DIR}" "${CONFIG_D_DIR}" "${CM_SOCKETS_DIR}"
chmod 700 "${SSH_DIR}" "${CONFIG_D_DIR}" "${CM_SOCKETS_DIR}"

# ── 2. ~/.ssh/config Include directive ───────────────────────────────────
[[ -f "${CONFIG_PATH}" ]] || { touch "${CONFIG_PATH}"; chmod 600 "${CONFIG_PATH}"; }
if ! grep -qxF 'Include ~/.ssh/config.d/*.conf' "${CONFIG_PATH}" 2>/dev/null; then
    tmp="$(mktemp)"
    { printf 'Include ~/.ssh/config.d/*.conf\n'; cat "${CONFIG_PATH}"; } > "${tmp}"
    mv "${tmp}" "${CONFIG_PATH}"
    chmod 600 "${CONFIG_PATH}"
    echo "[INFO] workbench-ssh: added Include directive to ${CONFIG_PATH}"
fi

# ── 3. Hardened client defaults — re-copied every run (this file is fully
#      workbench-ssh-managed; per-host overrides belong in a higher-numbered
#      config.d file instead, never in this one). ─────────────────────────
cp "files/00-defaults.conf" "${CONFIG_D_DIR}/00-defaults.conf"
chmod 600 "${CONFIG_D_DIR}/00-defaults.conf"

# ── 4. Agent-routing scaffold — created once, never overwritten. ─────────
if [[ ! -f "${CONFIG_D_DIR}/01-agent.conf" ]]; then
    cp "files/01-agent.conf" "${CONFIG_D_DIR}/01-agent.conf"
    chmod 600 "${CONFIG_D_DIR}/01-agent.conf"
    echo "[INFO] workbench-ssh: created ${CONFIG_D_DIR}/01-agent.conf (edit to route SSH agents per host)"
fi

# ── 5. Known hosts for Git forges ─────────────────────────────────────────
# Best-effort, non-fatal per forge — a network blip or corporate egress
# block on one forge must not abort the others, matching the donor
# Ansible role's ignore_errors: true.
touch "${KNOWN_HOSTS_PATH}"
chmod 600 "${KNOWN_HOSTS_PATH}"
_failed=""
for forge in ${FORGES}; do
    scan_out="$(ssh-keyscan -T "${KEYSCAN_TIMEOUT}" "${forge}" 2>/dev/null)"
    if [[ -z "${scan_out}" ]]; then
        _failed="${_failed}${forge} "
        continue
    fi
    # Drop any existing entries for this host before appending fresh ones,
    # so a rotated host key replaces the stale one rather than accumulating
    # alongside it.
    if grep -q "^${forge}[, ]" "${KNOWN_HOSTS_PATH}" 2>/dev/null; then
        tmp="$(mktemp)"
        grep -v "^${forge}[, ]" "${KNOWN_HOSTS_PATH}" > "${tmp}"
        mv "${tmp}" "${KNOWN_HOSTS_PATH}"
        chmod 600 "${KNOWN_HOSTS_PATH}"
    fi
    printf '%s\n' "${scan_out}" | grep -v '^#' >> "${KNOWN_HOSTS_PATH}"
done

if [[ -n "${_failed}" ]]; then
    echo "[WARN] workbench-ssh: ssh-keyscan could not reach: ${_failed}— these hosts were NOT added to known_hosts. The first SSH connection to them may prompt for host-key verification, which will hang in non-interactive contexts."
else
    echo "[INFO] workbench-ssh: known_hosts pre-trusted for: ${FORGES}"
fi

exit 0
