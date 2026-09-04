# workbench-ssh

Opinionated SSH client layer for the
[`workbench`](https://github.com/GingerGraham/workbench-core) ecosystem.

An **ecosystem module** (`workbench-core` ARCHITECTURE.md §2) — meaningless
standalone. Requires `workbench-core` installed first:

```sh
wb add ssh
# or, as part of a bundle:
wb install --bundle workstation
```

## What this module does

1. **Creates directories** — `~/.ssh` (0700), `~/.ssh/config.d` (0700),
   `~/.ssh/cm_sockets` (0700).
2. **Ensures the `Include` directive** is the first line of `~/.ssh/config`
   (`Include ~/.ssh/config.d/*.conf`) — idempotent.
3. **Adds known host keys** for Git forges (GitHub, GitLab, Bitbucket) by
   running `ssh-keyscan` on every sync where this module updated. This
   means it automatically picks up rotated host keys without any manual step.
4. **Deploys `config.d/00-defaults.conf`** — hardened client settings that
   apply to all connections: keepalive, ControlMaster multiplexing, modern
   key algorithm preferences, and safe defaults for `ForwardAgent`/`ForwardX11`.
5. **Deploys an empty `config.d/01-agent.conf` scaffold** (created once,
   never overwritten) for local `IdentityAgent` routing.

All of this happens via `hooks/post-deploy.sh` (`run_on: changed` — fires on
first sync and whenever this module updates, not on every automatic timer
tick), **not** manifest `deploy:` entries — `~/.ssh/` is on
`workbench-core`'s deploy dest denylist (a trust-boundary property, not an
oversight: SSH config is security-sensitive and not something a manifest
should be able to target declaratively). This is the same escape valve
`workbench-core`'s own `lib/ssh/bootstrap.sh` uses for the
bootstrap-critical deploy-key case (ARCHITECTURE.md D1).

## What this module does NOT do

- Generate SSH keys (personal or deploy). Personal key generation is your
  own responsibility. Deploy keys for private modules/tools are generated
  by `workbench-core` itself (`wb install`/`wb apply`, `lib/ssh/bootstrap.sh`).
- Touch `~/.ssh/config.d/10-workbench.conf`. That file is owned by
  `workbench-core` and holds the SSH host aliases for deploy keys
  (`workbench-<module-name>`). This module will not overwrite or remove it.
- Prescribe or configure a specific SSH agent (Bitwarden, gnome-keyring,
  1Password, etc.). This module deploys an empty `01-agent.conf` scaffold
  for `IdentityAgent` routing, but which agent(s) a machine actually runs
  is a local decision. Agent helper functions live in `shell/ssh.sh`.
- Install or configure `ssh-agent`/`ssh-add` automation.

## `config.d` load order

| File | Owner | Purpose |
|------|-------|---------|
| `00-defaults.conf` | workbench-ssh (re-copied every hook run) | Global `Host *` hardened defaults |
| `01-agent.conf` | workbench-ssh (created once) → you | Local `IdentityAgent` routing — see below |
| `10-workbench.conf` | `workbench-core` (`lib/ssh/bootstrap.sh`) | Deploy-key host aliases (`workbench-<module>`) |
| `20-*.conf` and beyond | You | Per-host or per-employer overrides |

## SSH agent routing (`01-agent.conf`)

`config.d/01-agent.conf` is placed on this module's first sync and never
overwritten thereafter. It ships empty (commented scaffold only): this
module makes no assumption about which SSH agent is running on a given
machine.

It loads right after `00-defaults.conf` and before `10-workbench.conf`, so
agent routing is settled before any per-repo or per-host override is
considered.

Fill it in by hand when a machine runs more than one SSH agent and
different hosts need different keys — for example, routing personal/work
logins through a password-manager agent (Bitwarden, 1Password) while
deploy keys added via `ssh-add` (`workbench-*`) stay on the desktop
session's own agent (gnome-keyring, KDE Wallet, etc.).

If a machine only ever runs one agent, leave this file empty — SSH will
just use `$SSH_AUTH_SOCK` as normal and no further config is needed.

See the comments in the deployed file for the exact syntax and common
agent socket paths.

## Extending client defaults

`00-defaults.conf` is fully managed by this module and re-copied on every
update. To add per-host overrides, create `~/.ssh/config.d/20-personal.conf`
(or any `2x-` name) on the machine directly — it is never touched by this
module.

## Shell functions

```sh
list-ssh-hosts          # tabular list of Host entries across ~/.ssh/config
                         # and every ~/.ssh/config.d/*.conf file
ssh-copy-bw [--all] <user@host|user host> [key_pattern]
                         # copy key(s) from the SSH agent to a remote host's
                         # authorized_keys
```

## Requires

`ssh-keyscan` (part of `openssh-client`, already a `workbench-core`
required prerequisite).
