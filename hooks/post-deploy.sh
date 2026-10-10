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
# pinned forge host keys (no keyscan — security review H2). This all happens
# via a hook rather than manifest deploy: entries because ~/.ssh/ is on the deploy dest denylist
# (contracts/manifest-spec.md) — the same escape valve workbench-core's own
# lib/ssh/bootstrap.sh uses for the bootstrap-critical deploy-key case (D1).
set -uo pipefail

SSH_DIR="${HOME}/.ssh"
CONFIG_D_DIR="${SSH_DIR}/config.d"
CM_SOCKETS_DIR="${SSH_DIR}/cm_sockets"
CONFIG_PATH="${SSH_DIR}/config"
KNOWN_HOSTS_PATH="${SSH_DIR}/known_hosts"
KNOWN_HOSTS_D="${SSH_DIR}/known_hosts.d"
FORGES_KNOWN_HOSTS="${KNOWN_HOSTS_D}/workbench-forges"
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

# ── 5. Known hosts for Git forges — pinned, never keyscanned ──────────────
# Security review H2. ssh-keyscan authenticates nothing: run on a hostile
# network it pins the attacker's key. The forge keys ship with this module
# (files/known_hosts.forges, verified against each vendor's published
# fingerprints) and are installed to a module-owned file that
# 00-defaults.conf lists as a second UserKnownHostsFile. The user's own
# ~/.ssh/known_hosts is never written by this hook.
mkdir -p "${KNOWN_HOSTS_D}"
chmod 700 "${KNOWN_HOSTS_D}"
cp "files/known_hosts.forges" "${FORGES_KNOWN_HOSTS}"
chmod 644 "${FORGES_KNOWN_HOSTS}"
echo "[INFO] workbench-ssh: pinned host keys installed for: ${FORGES}"

# ── 6. Audit forge keys already in ~/.ssh/known_hosts ────────────────────
# Earlier versions of this hook appended ssh-keyscan output here. Report —
# never delete — any key for a forge that is not in the pinned set: it is
# either a stale rotated key or was intercepted when it was scanned.
if [[ -f "${KNOWN_HOSTS_PATH}" ]]; then
    for forge in ${FORGES}; do
        while IFS= read -r line; do
            [[ -z "${line}" || "${line}" == \#* ]] && continue
            key_type="$(printf '%s\n' "${line}" | awk '{print $2}')"
            key_blob="$(printf '%s\n' "${line}" | awk '{print $3}')"
            if ! grep -qF "${key_type} ${key_blob}" "files/known_hosts.forges"; then
                fingerprint="$(printf '%s %s\n' "${key_type}" "${key_blob}" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')"
                echo "[WARN] workbench-ssh: ${KNOWN_HOSTS_PATH} trusts a ${key_type} key for ${forge} (${fingerprint:-unknown fingerprint}) that is not in the pinned set. Check it against the vendor's published fingerprints; to rely on the pinned keys only, run: ssh-keygen -R ${forge}"
            fi
        done < <(ssh-keygen -F "${forge}" -f "${KNOWN_HOSTS_PATH}" 2>/dev/null)
    done
fi

exit 0
