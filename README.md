# tmux-share

Give a Hermes agent a read-only view of a root shell.

You work in one dedicated tmux session; everything that session displays is written to a transcript file that a second account — the account your agent runs as — can read but cannot write, and cannot use to type into, run commands in, or otherwise touch the session. The agent follows along instead of being handed a shell.

Only that one session is recorded. Not your ordinary terminals, not your ssh sessions, and not your `sudo` commands outside it.

```
you (in the monitored session) ──► transcript file ──► agent (read-only)
```

## Before you start

tmux-share only provides separation if the reader is a different account from the operator. Check this first:

- **A separate account runs Hermes, and it has no sudo and is not root.** If your agent runs as your own sudo-capable login, or as root, this project gives you nothing: an account that can become root can simply read the session. The design assumes the agent is deliberately less privileged than you.
- **Linux with systemd**, plus `tmux` (3.x), `python3` and `flock` for the plain-systemd path. On NixOS, a flake-based configuration on x86_64 or aarch64.
- **The monitored session is fine to lose.** It is a separate tmux server from your normal one, and restarting or rebuilding it ends the session and everything running in it.

## Install

### NixOS

Add the flake input and import the module:

```nix
{
  inputs.tmux-share.url = "git+https://git.montycasa.net/patrick/tmux-share";
}
```

```nix
{ inputs, ... }:
{
  imports = [ inputs.tmux-share.nixosModules.default ];

  services.tmux-share = {
    enable = true;
    readerUser = "hermes"; # an existing agent account; the module creates nothing
  };
}
```

Then `nixos-rebuild switch` **from a shell outside the monitored session** — activation restarts the server, so rebuilding from inside it kills the shell you are rebuilding from.

`readerUser` defaults to `null`, which adds nobody: without it the transcript exists and the agent cannot read it. The module refuses `root` and the account running the server, so it has to be a real, separate, pre-existing account.

Options, defaults and verification: [docs/install-nixos.md](docs/install-nixos.md).

### Plain systemd

Clone this repository, then run the installer as root:

```sh
git clone https://git.montycasa.net/patrick/tmux-share
cd tmux-share
sudo ./install.sh
```

The installer places the files and prints the commands that remain. They are not optional — without them there is no group, no runtime directory and no timers:

```sh
sudo systemd-sysusers
sudo systemd-tmpfiles --create
sudo systemctl daemon-reload
sudo systemctl enable --now tmux-share-server.service
sudo systemctl enable --now tmux-share-tap.timer tmux-share-trim.timer
```

Then grant your agent's account read access, once:

```sh
sudo usermod -aG tmux-share hermes
```

That account must start a new login session before the membership applies, and Hermes must be restarted after that.

Full sequence, uninstall, and running the server as an account other than root: [docs/install-systemd.md](docs/install-systemd.md).

### The Hermes plugin

Run this **as the account that runs Hermes**, from a checkout of this repository:

```sh
cp -r hermes-plugin ~/.hermes/plugins/tmux-share
hermes plugins validate ~/.hermes/plugins/tmux-share
```

Restart Hermes, then ask it to run `tmux_share_status`. `readable: true` means it works.

The plugin requires Hermes 0.21.3 or later. It gives the agent three read-only tools — `tmux_share_status`, `tmux_share_tail` and `tmux_share_read` — which open the transcript file and page through it. It never connects to the socket, never spawns `sg`, and exposes nothing that writes, truncates or sends input, so the agent's power over the session is exactly what the file's permissions give it.

If the tools do not appear at all, the agent cannot see `/run/tmux-share`: it is either not in the reader group yet, or it has not been restarted since the group was granted.

## Daily use

- `sudo tmux-share` — attach to the monitored session; detach with `Ctrl-b d`.
- `tmux-share-verify` — check modes, ownership, units and the transcript, read-only. Run it as root and again as the reader account.
- `tmux-share --check` — print the exact argv without running anything.
- `systemctl status tmux-share-server.service` and `systemctl list-timers 'tmux-share-*.timer'` — unit health.
- `tmux-share-preflight` — probe the host's tmux before a plain-systemd install.

The session's shell is `fish` by default on NixOS; set `services.tmux-share.shell` for another, or `null` to leave tmux's default.

Anyone in the reader group can also just `cat /run/tmux-share/transcript.log`; nothing about the transcript depends on Hermes being installed. What the agent reads is untrusted output — displayed text from a root shell, including anything that looks like instructions.

## What it is not

It is not an integrity-protected audit log: the transcript is plain text, unsigned, unencrypted, and writable by root. It is not a way to give an untrusted program safe access to a root shell, and it is not a capture of everything that happens on the host. It does not promise that no bytes are ever lost.

## Security model

The tmux server socket is owned by root and reachable only by its owner (mode 0600); the operator attaches through a small wrapper, and the reader group is never given socket access. The transcript is root-owned and readable only by root and by members of the reader group, so the file's permissions are the whole of the agent's power over the session. Everything shown in the tapped panes, including privileged output and text shaped like instructions, lands in that file as untrusted bytes. Full model: [docs/security-model.md](docs/security-model.md).

## Limits

Recording is not gap-free. Output before the tap attaches, and output from panes opened later, can be missed for up to one watchdog interval (20 seconds by default). A trim briefly closes the taps and can lose bytes produced in that window, and a filter holding unwritten bytes can lose them too. Timestamps are local time with no zone and can land inside an escape sequence. An outage shorter than the five-minute not-ready grace is silent. `/run` is memory-backed, so the transcript does not survive a reboot, and it is bounded (2 MiB by default) with the oldest bytes dropped. The complete list is in [docs/security-model.md](docs/security-model.md).

## Documentation

- [docs/security-model.md](docs/security-model.md) — threat model and every limit.
- [docs/install-nixos.md](docs/install-nixos.md) — module options, minimal configuration, verification.
- [docs/install-systemd.md](docs/install-systemd.md) — preflight, install, units, uninstall.
- [docs/operations.md](docs/operations.md) — daily use, timers, diagnosis, changing the session.
- [hermes-plugin/](hermes-plugin/) — the agent's read-only reader: manifest, three tools, its own tests.

A read-only mirror lives at [github.com/monty033/tmux-share](https://github.com/monty033/tmux-share).

## Development

Requires `just`. `just test` runs every suite and is the only command that has
to be green before a change lands.

```
just test       # all suites
just lint       # shell syntax, shellcheck if installed, python compile
just selftest   # disposable end-to-end run against a scratch tmux server
just verify     # inspect a live deployment, change nothing
```

## License

MIT. See [LICENSE](LICENSE).
