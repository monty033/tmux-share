# Installing on NixOS

Import the module through the flake (`nixosModules.default`, also exported as `nixosModules.tmux-share`), then set `services.tmux-share.enable = true`. The module mirrors the unit files in `systemd/` and the environment contract documented in [`operations.md`](operations.md).

## Module options

All options live under `services.tmux-share`. Every value is also checked by an evaluation-time assertion that mirrors the run-time validators in `core/lib/validate.sh`.

| Name | Type | Default | Meaning |
| --- | --- | --- | --- |
| `services.tmux-share.enable` | bool | `false` | Enable the dedicated server, transcript tap, watchdog and trimmer. |
| `services.tmux-share.unitPrefix` | string | `"tmux-share"` | Prefix of the names of the five systemd units: `<prefix>-server.service`, `<prefix>-tap.service`, `<prefix>-tap.timer`, `<prefix>-trim.service` and `<prefix>-trim.timer`. The default keeps the names the templates in `systemd/` use, so a host that sets nothing renders the units it rendered before; a host whose deployment already runs the feature under another name (the live host uses `"tmux-admin"`) sets this to keep its own names. The software is tmux-share whatever the units are called. A plain name. |
| `services.tmux-share.sessionName` | string | `"tmux-hermes"` | Name of the monitored tmux session; must match `^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`. |
| `services.tmux-share.user` | string | `"root"` | The account that owns the server, socket, transcript, lock and markers, and that the server, tap and trimmer units run as. Must be `root` or an account declared in `users.users`: the module does not create it, and units for an account the host lacks fail at boot, so evaluation refuses it. Its primary group (`users.users.<user>.group`, `users` for a normal user) must be set: the lock is owned `user:<primary group>`. Same name rules as `readerUser`; it must not be `readerUser`. |
| `services.tmux-share.readerGroup` | string | `"tmux-share"` | Group that may read the transcript and traverse the runtime directory; the module creates it. Traverse and read only, never write. |
| `services.tmux-share.readerUser` | string or null | `null` | An existing account to add to `readerGroup`. The module does not create the account; `null` adds nobody. `root` and `user` are forbidden. |
| `services.tmux-share.directory` | string | `"/run/tmux-share"` | Runtime directory for the socket, transcript and markers; absolute, no `..`, no trailing slash. |
| `services.tmux-share.socketName` | string | `"tmux.sock"` | Socket file name inside `directory`. |
| `services.tmux-share.transcriptName` | string | `"transcript.log"` | Transcript file name inside `directory`. |
| `services.tmux-share.maxBytes` | int | `2097152` | Transcript size bound in bytes; the trimmer keeps the newest `maxBytes` bytes. Must be positive and below 10^12. |
| `services.tmux-share.shell` | string or null | `"${pkgs.fish}/bin/fish"` | The operator's `default-shell` inside the session; `null` leaves tmux's default (the login shell of the account that runs the server). Must be an absolute path. |
| `services.tmux-share.terminal` | string or null | `null` | Terminal type the shells inside the session announce (tmux `default-terminal`), for example `"tmux-256color"`. `null` writes nothing, so tmux keeps its own default: the module has never written a `default-terminal`, and writing one now would change the rendered file of every deployment that exists. The live host sets `"tmux-256color"`. A plain name. |
| `services.tmux-share.historyLimit` | int or null | `null` | Number of lines the session's scroll-back buffer keeps (tmux `history-limit`). `null` writes nothing, so tmux keeps its own default of 2000 lines, for the same reason: the module has never written a `history-limit`. The live host sets 2000, which is that same default. A positive integer: the option names a bound, and zero is not a bound. |
| `services.tmux-share.sessionPath` | list of strings or null | `null` | PATH the shells inside the session get, as absolute directories, for example `[ "/usr/local/bin" "/usr/bin" "/bin" ]`. The module writes them joined by `":"` as `set-environment -g PATH`, so the session's shells get exactly that PATH and not the one the account running the server happens to have. `null` writes nothing, and the shells inherit the server's PATH as they do today. Every entry must be an absolute path with only A-Z a-z 0-9 _ . / - characters: the value is written into the tmux configuration, where a `;` would start another tmux command. |
| `services.tmux-share.serverAccessReadOnly` | string or null | `null` | An account tmux's server-access list gets read-only access to: the module writes `server-access -a -r <account>` into the tmux configuration. Defence in depth and nothing more — while the socket is owner-only the entry cannot be reached, and it does not stop `send-keys` from an account that can already connect to the socket. It says what the server would allow if the socket's mode were ever widened; it is not a second boundary and it does not replace the socket's mode. `null` writes no entry at all. A plain account name, and not the account that owns the server. |
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

To run as an account other than root, name it. The account must already exist:

```nix example
{ ... }:
{
  services.tmux-share = {
    enable = true;
    user = "<operator>";
  };
}
```

With `user` left at `"root"` the rendered units, rules and tmux config are exactly what they were before the option existed. With another account the three services gain `User=`, the tmux session starts in that account's declared home directory (or `/` when the declaration has none), and the environment file names the account as `TMUX_SHARE_USER`.

The account must be declared in `users.users` (`isNormalUser = true;` is enough). Evaluation fails with a message saying why if it is not, rather than letting the units fail at boot. The lock file is owned by the account's primary group, not by a group named after the account, which a normal NixOS account does not have.

`/etc/tmux-share/tmux.conf` and `/etc/tmux-share/env` are read by the tmux server, so with a non-root `user` they are owned by that account with the reader group and mode 0640, the same as `install.sh --user` writes them. With `user = "root"` they keep the module's long-standing root:root 0644: changing that would change what an existing host renders, and root can read them either way. The two paths differ there on purpose.

## The optional settings

Five options exist for a deployment that needs more than the module wrote before. Four of them default to `null` and write nothing at all, so a host that sets none of them renders byte for byte what it rendered before they existed — including the tmux configuration, which keeps only `exit-empty on`, the `default-shell` and the `new-session` line it has always had. `unitPrefix` defaults to `"tmux-share"`, which keeps the unit names the templates in `systemd/` use.

The live host sets all five, and its values are the example to copy:

```nix example
{ ... }:
{
  services.tmux-share = {
    enable = true;
    # The live host already runs the feature under these names.
    unitPrefix = "tmux-admin";
    terminal = "tmux-256color";
    historyLimit = 2000;
    sessionPath = [ "/usr/local/bin" "/usr/bin" "/bin" ];
    # An account that exists on the host.
    serverAccessReadOnly = "guest";
  };
}
```

What each one writes, and what it does not do:

- `unitPrefix` renames the five units and nothing else. The watchdog and the trimmer are ordered behind the server under its new name, and the old names are not created, so a host that renames them does not end up running two servers.
- `terminal` writes `set -g default-terminal`. It says what the shells announce; a type the host's terminfo does not have means no colours and no keypad.
- `historyLimit` writes `set -g history-limit`. It bounds the scroll-back buffer of every pane the operator opens.
- `sessionPath` writes `set-environment -g PATH` with the directories joined by `:`, before the session is created, so the session's shells get exactly that PATH instead of the one the account running the server happens to have. It replaces the inherited PATH; it does not add to it.
- `serverAccessReadOnly` writes `server-access -a -r <account>`. It is defence in depth: while the socket is owner-only the entry cannot be reached, and it does not stop `send-keys` from an account that can already connect to the socket. It says what the server would allow if the socket's mode were ever widened, and it is not a second boundary.

Every value is checked at evaluation time: a prefix or a terminal name that is not a plain name, a history limit that is not positive, a PATH entry that is not an absolute path, and an account that is not a plain name or that is the account owning the server are all refused with a message saying why, before anything is rendered.

## What the module creates

- Puts the package in `environment.systemPackages`, so its commands are on PATH: `tmux-share`, `tmux-share-verify`, `tmux-share-preflight`, `tmux-share-render`, `tmux-share-tap-start`, `tmux-share-trim` and `tmux-share-watchdog`. The wrappers in the package source `/etc/tmux-share/env` when it exists.
- Creates the reader group through `users.groups`, named after `readerGroup`, and adds `readerUser` to it through `extraGroups` when set. It never creates the reader account.
- Writes `/etc/tmux-share/tmux.conf` (`exit-empty on`, optional `default-shell`, optional `default-terminal`, `history-limit`, `server-access` and `set-environment -g PATH`, and `new-session -d`) and `/etc/tmux-share/env` (the `TMUX_SHARE_*` contract) through `environment.etc`.
- Adds tmpfiles rules: `directory` mode 0710 `user`:readerGroup, transcript mode 0640 `user`:readerGroup, and a sibling `directory.lock` mode 0600 `user`:`user` (`user` is root unless set; the lock group is the account's primary group). There is deliberately no rule for the socket; tmux creates it itself, owner-only.
- Declares `tmux-share-server.service`, `tmux-share-tap.service`, `tmux-share-trim.service` and the `tmux-share-tap.timer` (20 seconds) and `tmux-share-trim.timer` (5 minutes) timers, both with `AccuracySec=1s`. The server sets no `UMask` and no `RuntimeDirectory`. The names of the five units follow `unitPrefix`; the default prefix is the one used above.

After adding the module, apply the configuration with `nixos-rebuild switch` from a shell outside the monitored session.

## Verifying the install

`tmux-share-verify` is read-only. Run it as root (with `TMUX_SHARE_USER` set to the account when `user` is not root; the NixOS wrappers source `/etc/tmux-share/env`, which already names it), then again while logged in as the reader account, because the socket-connect check is skipped for root (root can connect to any socket whatever its mode).

```sh
tmux-share-verify
```

A zero exit status means no check failed; individual checks that do not apply to the host are reported as `SKIP`. The checks cover the directory and transcript modes and owners, the socket being owned by `user` alone, a failed reader connect, no `pipe-pane -o` in the scripts, unit properties, the stamp filter's byte-for-byte behaviour, and reader group membership. When run as the reader account, the connect attempt from that account should be refused with `EACCES`/`EPERM`.

## Adding the reader account to the group

The declarative way is `services.tmux-share.readerUser`, as shown above; the account must already exist. To grant access to an extra account without another rebuild, add it to the group once as root:

```sh example
usermod -aG tmux-share <reader>
```

Group membership applies only to new processes: the account must start a new login session before it can read the transcript, and a running agent must be restarted. To revoke access, remove the account from the group with `gpasswd -d`.

## Rebuilds drop the operator's session

The tmux server owns the monitored session. A `nixos-rebuild` that changes `tmux-share-server.service` restarts that unit, which tears down the operator's attached session and any panes in it. Run rebuilds from a different terminal or shell, outside the session you want to keep. See operations.md for the day-to-day consequences and security-model.md for the full limits.
