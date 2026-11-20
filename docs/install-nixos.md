# Installing on NixOS

Import the module through the flake (`nixosModules.default`, also exported as `nixosModules.tmux-share`), then set `services.tmux-share.enable = true`. The module mirrors the unit files in `systemd/` and the environment contract documented in [`operations.md`](operations.md).

## Module options

All options live under `services.tmux-share`. Every value is also checked by an evaluation-time assertion that mirrors the run-time validators in `core/lib/validate.sh`.

| Name | Type | Default | Meaning |
| --- | --- | --- | --- |
| `services.tmux-share.enable` | bool | `false` | Enable the dedicated server, transcript tap, watchdog and trimmer. |
| `services.tmux-share.sessionName` | string | `"tmux-hermes"` | Name of the monitored tmux session; must match `^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`. |
| `services.tmux-share.readerGroup` | string | `"tmux-share"` | Group that may read the transcript and traverse the runtime directory; the module creates it. Traverse and read only, never write. |
| `services.tmux-share.readerUser` | string or null | `null` | An existing account to add to `readerGroup`. The module does not create the account; `null` adds nobody, and `root` is forbidden. |
| `services.tmux-share.directory` | string | `"/run/tmux-share"` | Runtime directory for the socket, transcript and markers; absolute, no `..`, no trailing slash. |
| `services.tmux-share.socketName` | string | `"tmux.sock"` | Socket file name inside `directory`. |
| `services.tmux-share.transcriptName` | string | `"transcript.log"` | Transcript file name inside `directory`. |
| `services.tmux-share.maxBytes` | int | `2097152` | Transcript size bound in bytes; the trimmer keeps the newest `maxBytes` bytes. Must be positive and below 10^12. |
| `services.tmux-share.shell` | string or null | `"${pkgs.fish}/bin/fish"` | The operator's `default-shell` inside the session; `null` leaves tmux's default (root's login shell). Must be an absolute path. |
| `services.tmux-share.package` | package | the flake's `self.packages.${pkgs.stdenv.hostPlatform.system}.default` | The tmux-share scripts; installs the attach, verify and render commands on PATH. |

## Complete minimal example

This is a whole host configuration fragment; it assumes the flake is an input named `tmux-share` and the module is imported as `tmux-share.nixosModules.default`.

```nix
{ ... }:
{
  services.tmux-share = {
    enable = true;
  };
}
```

To name a reader at configuration time, use a real, pre-existing account:

```nix example
{ ... }:
{
  services.tmux-share = {
    enable = true;
    readerUser = "<reader>";
  };
}
```

## What the module creates

- Puts the package in `environment.systemPackages`, so `tmux-share-attach`, `tmux-share-verify` and `tmux-share-render` are on PATH. The wrappers in the package source `/etc/tmux-share/env` when it exists.
- Creates the reader group through `users.groups`, named after `readerGroup`, and adds `readerUser` to it through `extraGroups` when set. It never creates the reader account.
- Writes `/etc/tmux-share/tmux.conf` (`exit-empty on`, optional `default-shell`, and `new-session -d`) and `/etc/tmux-share/env` (the `TMUX_SHARE_*` contract) through `environment.etc`.
- Adds tmpfiles rules: `directory` mode 0710 root:readerGroup, transcript mode 0640 root:readerGroup, and a sibling `directory.lock` mode 0600 root:root. There is deliberately no rule for the socket; tmux creates it itself, owner-only.
- Declares `tmux-share-server.service`, `tmux-share-tap.service`, `tmux-share-trim.service` and the `tmux-share-tap.timer` (20 seconds) and `tmux-share-trim.timer` (5 minutes) timers, both with `AccuracySec=1s`. The server sets no `UMask` and no `RuntimeDirectory`.

After adding the module, apply the configuration with `nixos-rebuild switch` from a shell outside the monitored session.

## Verifying the install

`tmux-share-verify` is read-only. Run it as root, then again while logged in as the reader account, because the socket-connect check is skipped for root (root can connect to any socket whatever its mode).

```sh
tmux-share-verify
```

A zero exit status means no check failed; individual checks that do not apply to the host are reported as `SKIP`. The checks cover the directory and transcript modes and owners, the socket being root-only, a failed reader connect, no `pipe-pane -o` in the scripts, unit properties, the stamp filter's byte-for-byte behaviour, and reader group membership. When run as the reader account, the connect attempt from that account should be refused with `EACCES`/`EPERM`.

## Adding the reader account to the group

The declarative way is `services.tmux-share.readerUser`, as shown above; the account must already exist. To grant access to an extra account without another rebuild, add it to the group once as root:

```sh example
usermod -aG tmux-share <reader>
```

Group membership applies only to new processes: the account must start a new login session before it can read the transcript, and a running agent must be restarted. To revoke access, remove the account from the group with `gpasswd -d`.

## Rebuilds drop the operator's session

The tmux server owns the monitored session. A `nixos-rebuild` that changes `tmux-share-server.service` restarts that unit, which tears down the operator's attached session and any panes in it. Run rebuilds from a different terminal or shell, outside the session you want to keep. See operations.md for the day-to-day consequences and security-model.md for the full limits.
