# Changelog

All notable changes to `workbench-ssh` are documented here.

## [Unreleased]

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

