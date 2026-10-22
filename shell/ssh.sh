#!/usr/bin/env bash
# shell/ssh.sh — workbench-ssh
# SSH helpers — listing hosts, key management, the agent-routing scaffold
# and a known_hosts audit. Registered at tier: tools (workbench.yml),
# sourced unconditionally. list-ssh-hosts and ssh-copy-bw are ported from
# workbench-precursor's core/ssh.sh, unchanged.

# ── List SSH hosts ─────────────────────────────────────────────────────────────
list-ssh-hosts() {
    local config_dir="${HOME}/.ssh/config.d"
    local main_config="${HOME}/.ssh/config"

    if [[ -f "${main_config}" ]]; then
        echo "=== Main Config ==="
        grep -E "^Host[[:space:]]" "${main_config}" | sed 's/Host //'
        echo
    fi

    if [[ -d "${config_dir}" ]]; then
        for config_file in "${config_dir}"/*; do
            [[ -f "${config_file}" ]] || continue
            echo "=== $(basename "${config_file}") ==="
            grep -E "^Host[[:space:]]" "${config_file}" | sed 's/Host //'
            echo
        done
    fi
}

# ── Copy SSH keys from agent to a remote host ─────────────────────────────────
ssh-copy-bw() {
    local usage="Usage: ssh-copy-bw [--all] <user@host|user host> [key_pattern]

Examples:
  ssh-copy-bw user@server.example.com \"My Key\"
  ssh-copy-bw user server.example.com \"2025-01-30\"
  ssh-copy-bw --all user@server.example.com"

    local copy_all=false user_host="" key_pattern=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            --all)   copy_all=true; shift ;;
            -h|--help) echo "${usage}"; return 0 ;;
            *)
                if [[ -z "${user_host}" ]]; then
                    user_host="$1"
                elif [[ "${user_host}" != *"@"* && -z "${key_pattern}" ]]; then
                    user_host="${user_host}@$1"
                elif [[ -z "${key_pattern}" ]]; then
                    key_pattern="$1"
                else
                    log_error "Too many arguments"; echo "${usage}"; return 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "${user_host}" ]]; then
        log_error "user@host is required"; echo "${usage}"; return 1
    fi

    if [[ "${copy_all}" == false && -z "${key_pattern}" ]]; then
        log_error "key pattern is required unless --all is specified"
        echo "${usage}"; return 1
    fi

    local available_keys
    available_keys="$(ssh-add -L 2>/dev/null)" || {
        log_error "No SSH keys found in agent"; return 1
    }

    if [[ -z "${available_keys}" ]]; then
        log_error "No SSH keys available in agent"; return 1
    fi

    local keys_to_copy
    if [[ "${copy_all}" == true ]]; then
        keys_to_copy="${available_keys}"
        log_info "Copying all $(echo "${available_keys}" | wc -l) key(s) to ${user_host}..."
    else
        keys_to_copy="$(echo "${available_keys}" | grep "${key_pattern}")"
        if [[ -z "${keys_to_copy}" ]]; then
            log_error "No keys matching '${key_pattern}'"
            log_info "Available keys:"; echo "${available_keys}"; return 1
        fi
        log_info "Copying $(echo "${keys_to_copy}" | wc -l) key(s) to ${user_host}..."
    fi

    if echo "${keys_to_copy}" | ssh "${user_host}" \
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && echo 'Keys added'"; then
        log_info "SSH keys copied successfully"
    else
        log_error "Failed to copy SSH keys to ${user_host}"; return 1
    fi
}

# ── Agent-routing scaffold ────────────────────────────────────────────────────
# ssh-agent-scaffold
# Creates ~/.ssh/config.d/01-agent.conf from workbench-ssh's template if you
# don't have one. Use it to route hosts to different SSH agents (see the
# file's own comments). Never overwrites an existing file.
ssh-agent-scaffold() {
    local template="${HOME}/.local/share/workbench/modules/ssh/files/01-agent.conf"
    local config_d="${HOME}/.ssh/config.d"
    local target="${config_d}/01-agent.conf"
    if [[ -e "${target}" ]]; then
        log_info "ssh: ${target} already exists — left unchanged"
        return 0
    fi
    if [[ ! -f "${template}" ]]; then
        log_error "ssh: template not found at ${template} — run: wb update ssh"
        return 1
    fi
    mkdir -p "${config_d}" && chmod 700 "${config_d}" || return 1
    cp "${template}" "${target}" && chmod 600 "${target}" || return 1
    log_info "ssh: created ${target} — edit it to route hosts to SSH agents"
}

# ── Audit forge keys in ~/.ssh/known_hosts ────────────────────────────────────
# ssh-audit-known-hosts
# Earlier versions of workbench-ssh appended ssh-keyscan output to
# ~/.ssh/known_hosts. Reports — never deletes — any key there for a Git
# forge that isn't in the pinned set this module ships: it is either a
# stale rotated key or was intercepted when it was scanned (security
# review H2). Read-only: nothing is fetched and no file is written.
ssh-audit-known-hosts() {
    local known_hosts="${HOME}/.ssh/known_hosts"
    local pinned="${HOME}/.local/share/workbench/modules/ssh/files/known_hosts.forges"
    local forges="github.com gitlab.com bitbucket.org"
    local forge line key_type key_blob fingerprint found=0
    if [[ ! -f "${pinned}" ]]; then
        log_error "ssh: pinned host keys not found at ${pinned} — run: wb update ssh"
        return 1
    fi
    if [[ ! -f "${known_hosts}" ]]; then
        log_info "ssh: no ${known_hosts} — nothing to audit"
        return 0
    fi
    for forge in ${forges}; do
        while IFS= read -r line; do
            [[ -z "${line}" || "${line}" == \#* ]] && continue
            key_type="$(printf '%s\n' "${line}" | awk '{print $2}')"
            key_blob="$(printf '%s\n' "${line}" | awk '{print $3}')"
            if ! grep -qF "${key_type} ${key_blob}" "${pinned}"; then
                fingerprint="$(printf '%s %s\n' "${key_type}" "${key_blob}" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')"
                log_warn "ssh: ${known_hosts} trusts a ${key_type} key for ${forge} (${fingerprint:-unknown fingerprint}) that is not in the pinned set. Check it against the vendor's published fingerprints; to rely on the pinned keys only, run: ssh-keygen -R ${forge}"
                found=$((found + 1))
            fi
        done < <(ssh-keygen -F "${forge}" -f "${known_hosts}" 2>/dev/null)
    done
    if [[ "${found}" -eq 0 ]]; then
        log_info "ssh: every forge key in ${known_hosts} is in the pinned set"
    else
        log_info "ssh: ${found} forge key(s) in ${known_hosts} not in the pinned set — see above"
    fi
}

get-ssh-functions() {
    local _f="${BASH_SOURCE[0]}"
    _get_functions_in "SSH functions" "" "${_f}"
}
