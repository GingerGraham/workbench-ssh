# Changelog

All notable changes to `workbench-ssh` are documented here.

## [Unreleased]

### Fixed

- **`ssh-audit-known-hosts` flags unpinned forge keys in zsh.** The
  forge loop didn't word-split there, so it checked nothing and reported
  every forge key as pinned.
- **`get-ssh-functions` lists the functions in zsh.** It is now the
  getter workbench-core generates from the manifest (workbench-core
  D89); the hand-written one printed `(none)` in zsh. The header now
  reads `SSH agent and host-listing helpers — functions`.
- **`ssh-copy-bw` no longer duplicates keys on the remote.** Only keys
  not already in `~/.ssh/authorized_keys` are appended.
- **`ssh-copy-bw`'s key pattern is plain text.** It was a regex, and a
  pattern starting with `-` was taken as a `grep` option.
- **The hardened defaults apply on OpenSSH before 8.5** (e.g. RHEL 8).
  `PubkeyAcceptedAlgorithms` is new in 8.5; older versions rejected the
  whole defaults layer. It is now listed in `IgnoreUnknown` first. If
  your own `~/.ssh/config` sets `IgnoreUnknown` above the defaults block,
  add `PubkeyAcceptedAlgorithms` to it: ssh uses the first
  `IgnoreUnknown` it reads.
- **`list-ssh-hosts` works in zsh with an empty `~/.ssh/config.d`.** It
  stopped with a "no matches found" error.

### Changed

- **`ssh-copy-bw <user> <host>` is gone.** The first argument is the
  destination — `user@host` or a `Host` alias from your ssh config — and
  the second is the key pattern, so `ssh-copy-bw myhost "My Key"` now
  copies to `myhost` rather than `myhost@My Key`. Write
  `ssh-copy-bw user@host …` where you used `ssh-copy-bw user host …`.
- `ssh-copy-bw` is listed by `wb functions` and `get-ssh-functions` only
  when `ssh-add` is installed.
- Needs Core API 1.8 (`core_api: ">=1.8 <2.0"`).

## [0.3.0] - 2026-10-22

### Changed

- **No hook: `~/.ssh/config` gets two marked blocks written by
  workbench-core** (workbench-core D82; needs Core API 1.6,
  `core_api: ">=1.6 <2.0"`). One at the top includes your
  `~/.ssh/config.d/*.conf`; one at the end, under `Match all`, includes
  the hardened defaults straight from the module. Your settings outside
  the blocks win, as before. `wb add ssh` no longer needs
  `--allow-hooks`, and `wb files status ssh` shows both blocks. On
  update, the defaults block the old hook appended is replaced by the
  new one; the hook's top `Include` line is left in place.
- **Pinned forge keys move to
  `~/.local/share/workbench/modules/ssh/files/known_hosts.forges`**,
  deployed by workbench-core; the defaults' `UserKnownHostsFile` points
  there.
- **Forge multiplexing sockets are `~/.ssh/cm-%C`**, not
  `~/.ssh/cm_sockets/%C`: no directory to create first.
- **`config.d/01-agent.conf` is created on request**, by the new
  `ssh-agent-scaffold`, not on install. An existing one is never
  touched.
- **The known_hosts audit is a command**, `ssh-audit-known-hosts`,
  instead of running on every update. Still read-only.

### Removed

- `hooks/post-deploy.sh`. Left on existing hosts and no longer used —
  safe to delete, nothing deletes them automatically:
  `~/.ssh/workbench-defaults.conf`, `~/.ssh/known_hosts.d/workbench-forges`,
  `~/.ssh/cm_sockets/`. See the README's "Upgrading from 0.2.x".

## [0.2.2] - 2026-10-10

### Fixed

- **Module defaults no longer shadow your own SSH settings.** ssh uses the
  first value it finds per keyword, and `config.d/00-defaults.conf` loaded
  before everything else, so its `Host *` block (`ForwardAgent no`,
  `ServerAliveInterval`, `LogLevel`, ...) silently overrode per-host values in
  your later `config.d` files and `~/.ssh/config`. The defaults now install
  to `~/.ssh/workbench-defaults.conf` and are included at the end of
  `~/.ssh/config` under `Match all`, so they only fill in what you have not
  set. Behaviour is unchanged for anyone who set nothing; a per-host override
  that was previously ignored will now take effect. The hook removes the old
  `config.d/00-defaults.conf` (only if it is the managed one) and adds the
  trailing `Include` idempotently. `Match all` alone would not have fixed
  this (it is equivalent to `Host *`); the include position is what matters.

## [0.2.1] - 2026-10-10

### Security

- **Connection multiplexing is scoped to the Git forges** (security review
  M8, L10). `ControlMaster`/`ControlPersist` moved out of `Host *` into a
  `Host github.com gitlab.com bitbucket.org` block, so other hosts no longer
  expose a ten-minute socket that bypasses FIDO2 touch, `ssh-add -c` and MFA.
  Hosts can be opted back in from a later `config.d` file (see the README).
  The `00-defaults.conf` header no longer wrongly claims per-host blocks
  always win over `Host *`.

- **Forge host keys are now pinned, not keyscanned** (security review H2).
  `hooks/post-deploy.sh` no longer runs `ssh-keyscan` or rewrites
  `~/.ssh/known_hosts`. The GitHub, GitLab and Bitbucket keys ship as
  `files/known_hosts.forges` and are installed to
  `~/.ssh/known_hosts.d/workbench-forges`, which `00-defaults.conf` lists as
  a second `UserKnownHostsFile` (with `UpdateHostKeys yes`). The hook now
  reports, and never deletes, forge keys already in `~/.ssh/known_hosts`
  that are not in the pinned set.
- `PubkeyAcceptedAlgorithms` now includes the FIDO2 `sk-` key types.

## [0.2.0] - 2026-09-23

### Added

- **Manual `workflow_dispatch` release override.** `release.yml` now
  accepts a `bump_type` (patch/minor/major) input to force a release
  through `workbench-core`'s reusable `module-release.yml`, regardless of
  what Conventional Commits since the last tag would compute — a floor,
  never a downgrade of a higher severity already pending. Manual dispatch
  only runs from `main`. See `workbench-core`'s `docs/decisions-log.md` D67.

- **Agent-instruction files** (`AGENTS.md`, `CLAUDE.md`,
  `.github/copilot-instructions.md`,
  `.claude/skills/conventional-commits/SKILL.md`) — ports
  `workbench-core`'s D32 agent-instruction topology to this repo. See
  `workbench-core`'s `docs/decisions-log.md` D58.
- **Repo governance files** (`.github/PULL_REQUEST_TEMPLATE.md`,
  `.github/ISSUE_TEMPLATE/{bug_report,feature_request,config}.yml`,
  `.github/CODEOWNERS`, `CONTRIBUTING.md`, `SECURITY.md`) — ports
  `workbench-core`'s D31 governance-file topology to this repo,
  piloted on `workbench-git` first. See `workbench-core`'s
  `docs/decisions-log.md` D60.

## [0.1.0] - 2026-09-09

### Added

- Initial decomposition from `workbench-precursor` (Wave C): `shell/ssh.sh`
  (`list-ssh-hosts`, `ssh-copy-bw`), hardened `config.d/00-defaults.conf`
  client defaults, an empty `config.d/01-agent.conf` scaffold, and
  multi-forge (GitHub/GitLab/Bitbucket) `known_hosts` pre-trust via
  `ssh-keyscan`.

### Changed

- All SSH config file placement moved from Ansible templates to
  `hooks/post-deploy.sh` (`run_on: changed`) — `~/.ssh/` is on
  `workbench-core`'s deploy `dest` denylist, so manifest `deploy:` entries
  cannot target it at all. This is a structural requirement, not a style
  choice.
- `Host dotfiles-*` (the no-ControlMaster carve-out for deploy-key aliases)
  renamed to `Host workbench-*`, matching `workbench-core`'s own
  `lib/ssh/bootstrap.sh` alias convention (`workbench-<module-name>`).
- Config.d load-order table updated: `10-dotfiles.conf` → `10-workbench.conf`
  (owned by `workbench-core`, not this module).
- `ControlMaster`/`ControlPath`/`ControlPersist` in `00-defaults.conf` are
  now actually enabled (were left commented out in the precursor's own
  template) — the README, `hooks/post-deploy.sh`'s `~/.ssh/cm_sockets`
  creation, and the `Host workbench-*` no-multiplexing carve-out all
  assumed multiplexing was active, so leaving it disabled by default was
  an inconsistency, not an intentional opt-in.

