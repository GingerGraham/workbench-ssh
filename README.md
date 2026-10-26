# workbench-ssh

Opinionated SSH client layer for the
[`workbench`](https://github.com/GingerGraham/workbench-core) ecosystem.

An **ecosystem module** (`workbench-core` ARCHITECTURE.md §2). Requires
`workbench-core` only — it works without any other workbench module (see
"Using workbench-ssh on its own" below):

```sh
wb add ssh
# or, as part of a bundle:
wb install --bundle workstation
```

## What this module puts on your machine

1. **Two marked blocks in `~/.ssh/config`**, written by `workbench-core`
   (`docs/decisions-log.md` D82). Everything outside them is yours and is
   never changed:

   ```
   # >>> workbench ssh/ssh_config over >>>       top: your config.d/*.conf files
   Include ".../modules/ssh/current/files/ssh_config-confd"
   # <<< workbench ssh/ssh_config over <<<
   ...                                           your own ~/.ssh/config
   # >>> workbench ssh/ssh_config under >>>      end: hardened defaults
   Match all
   Include ".../modules/ssh/current/files/00-defaults.conf"
   # <<< workbench ssh/ssh_config under <<<
   ```

   `ssh_config-confd` includes `~/.ssh/config.d/*.conf`. `00-defaults.conf`
   holds the hardened client settings: keepalive, `ControlMaster`
   multiplexing for the Git forges only, modern key algorithm preferences
   (including FIDO2 `sk-` keys), and safe defaults for
   `ForwardAgent`/`ForwardX11`. Both files are read straight from the
   module's current snapshot, so an update takes effect with nothing
   copied. If `~/.ssh/config` doesn't exist, it is created (and `~/.ssh`,
   mode 700).
2. **Pinned host keys for the Git forges** (GitHub, GitLab, Bitbucket),
   deployed to `~/.local/share/workbench/modules/ssh/files/known_hosts.forges`
   from `files/known_hosts.forges`, which ships in this repo. GitHub and
   GitLab keys are taken from each vendor's docs and match their published
   fingerprints; Bitbucket's come from `bitbucket.org/site/ssh` and were
   checked by the maintainer against Atlassian's published fingerprints
   (provenance is in the file's header). The defaults list it as a second
   `UserKnownHostsFile`; your own `~/.ssh/known_hosts` is never written.
   Nothing is fetched from the network (no `ssh-keyscan`, which
   authenticates nothing). A forge key rotation arrives as a module
   release.
3. **A template for `config.d/01-agent.conf`**, next to the pinned keys.
   Nothing is created in `~/.ssh/config.d/` until you run
   `ssh-agent-scaffold` (below).

There is no hook: `wb add ssh` needs no `--allow-hooks`.

`wb files status ssh` shows all of it. To leave out the defaults:
`wb files policy ssh ssh_config skip` (or `wb add ssh --skip-layer
ssh_config`); the `config.d` include is `ssh_config:over`.

## Using workbench-ssh on its own

- **Needs `workbench-core` only.** No other workbench module, and no
  `--allow-hooks`.
- **Your `~/.ssh/config` stays yours.** The two blocks are the only lines
  workbench writes; anything you set outside them wins.
- **`config.d/`** is optional. With no `~/.ssh/config.d/`, the top block's
  `Include` matches nothing and ssh carries on.
- **`ssh-keygen`** (part of `openssh-client`) is needed only for
  `ssh-audit-known-hosts`.

## What this module does NOT do

- Generate SSH keys (personal or deploy). Personal key generation is your
  own responsibility. Deploy keys for private modules/tools are generated
  by `workbench-core` itself (`wb install`/`wb apply`, `lib/ssh/bootstrap.sh`).
- Touch `~/.ssh/config.d/10-workbench.conf`. That file is owned by
  `workbench-core` and holds the SSH host aliases for deploy keys
  (`workbench-<module-name>`).
- Prescribe or configure a specific SSH agent (Bitwarden, gnome-keyring,
  1Password, etc.). Which agent(s) a machine runs is a local decision;
  `ssh-agent-scaffold` gives you a commented file to route hosts between
  them.
- Install or configure `ssh-agent`/`ssh-add` automation.

## `config.d` load order

| File | Owner | Purpose |
|------|-------|---------|
| `01-agent.conf` | You, created by `ssh-agent-scaffold` | Local `IdentityAgent` routing — see below |
| `10-workbench.conf` | `workbench-core` (`lib/ssh/bootstrap.sh`) | Deploy-key host aliases (`workbench-<module>`) |
| `20-*.conf` and beyond | You | Per-host or per-employer overrides |

## SSH agent routing (`01-agent.conf`)

Run `ssh-agent-scaffold` to create `~/.ssh/config.d/01-agent.conf` from
the module's template. It never overwrites a file that's already there.
The file is a commented scaffold only: this module makes no assumption
about which SSH agent a machine runs.

It loads first in `config.d/` and before `10-workbench.conf`, so agent
routing is settled before any per-repo or per-host override is
considered.

Fill it in when a machine runs more than one SSH agent and different
hosts need different keys — for example, routing personal/work logins
through a password-manager agent (Bitwarden, 1Password) while deploy keys
added via `ssh-add` (`workbench-*`) stay on the desktop session's own
agent (gnome-keyring, KDE Wallet, etc.). With only one agent, you don't
need the file: ssh uses `$SSH_AUTH_SOCK` as normal.

See the comments in the file for the exact syntax and common agent socket
paths.

## Extending client defaults

`00-defaults.conf` belongs to the module and is replaced on every update —
don't edit it. Add per-host settings to `~/.ssh/config.d/20-personal.conf`
(or any `2x-` name), or to `~/.ssh/config` itself outside the blocks.
Either wins over the defaults.

## Connection multiplexing

The defaults enable `ControlMaster auto` / `ControlPersist 10m` only for
github.com, gitlab.com and bitbucket.org, where fast repeated git
operations benefit most, with sockets at `~/.ssh/cm-%C`. It is
deliberately not enabled for every host: while a master connection is
open, any process running as your user can open new sessions over its
socket without re-authenticating, which bypasses FIDO2 touch,
`ssh-add -c` confirmation and bastion MFA. The trade-off for opting a
host in is faster repeated connections versus that ten-minute window.

To opt a host in, add a block to a later file such as
`~/.ssh/config.d/20-personal.conf`:

```
Host myhost
    ControlMaster auto
    ControlPath ~/.ssh/cm-%C
    ControlPersist 10m
```

## Ordering: your settings win

ssh uses the first value it finds for each keyword. The `config.d` block
is at the top of `~/.ssh/config` and the defaults block at the end, under
`Match all`, so the defaults only fill in what nothing above has set. A
per-host `ForwardAgent yes`, `ServerAliveInterval`, `ControlMaster` and so
on, in any of your files, takes effect.

## Upgrading from 0.2.x

Earlier releases ran a post-deploy hook. On the first update to this
release, `workbench-core` finds the block that hook appended to
`~/.ssh/config`:

```
# workbench-ssh defaults: keep last so your own settings above win.
Match all
Include ~/.ssh/workbench-defaults.conf
```

and replaces it with the defaults block above. The bare
`Include ~/.ssh/config.d/*.conf` the hook added as the first line stays
(`workbench-core`'s deploy-key setup may own it too); the top block
includes the same files again, which is harmless because ssh keeps the
first value.

These are no longer used, and nothing deletes them. Remove them when
you're ready:

- `~/.ssh/workbench-defaults.conf`
- `~/.ssh/known_hosts.d/workbench-forges` (and `~/.ssh/known_hosts.d/` if
  it is empty)
- `~/.ssh/cm_sockets/` — close any open forge connections first
  (`ssh -O exit github.com`), or let them time out after ten minutes
- `~/.ssh/config.d/00-defaults.conf`, if a release before 0.2.2 left one
  there

## Shell functions

```sh
list-ssh-hosts          # Host entries across ~/.ssh/config and every
                        # ~/.ssh/config.d/*.conf file
ssh-copy-bw [--all] <user@host|user host> [key_pattern]
                        # copy key(s) from the SSH agent to a remote
                        # host's authorized_keys
ssh-agent-scaffold      # create ~/.ssh/config.d/01-agent.conf from the
                        # template, if you don't have one
ssh-audit-known-hosts   # report forge keys in ~/.ssh/known_hosts that
                        # aren't in the pinned set (read-only)
```

`ssh-audit-known-hosts` exists because releases before 0.2.1 appended
`ssh-keyscan` output to `~/.ssh/known_hosts`. Any forge key there that
isn't pinned is either a stale rotated key or was intercepted when it was
scanned. It prints each one with its fingerprint and never deletes
anything: check it against the vendor's published fingerprints, and
remove it with `ssh-keygen -R <host>` if it's stale.

## Requires

- `workbench-core` with Core API 1.8 or later.
- `ssh-keygen` (part of `openssh-client`, already a `workbench-core`
  required prerequisite) — used only by `ssh-audit-known-hosts`.
