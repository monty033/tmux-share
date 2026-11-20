# tmux-share

tmux-share runs a dedicated tmux server as root and records everything displayed in its panes into one transcript file that a single reader group may read. A watchdog keeps the recording tap attached to every pane, and a trimmer keeps the file within a byte bound. It is meant for the narrow case where an operator wants a text record of what a root shell did, and a separate account should be able to read that record without being able to drive the shell.

## What it is not

It is not an integrity-protected audit log: the transcript is plain text, unsigned, unencrypted, and writable by root. It is not a way to give an untrusted program safe access to a root shell, and it is not a capture of everything that happens on the host. It does not promise that no bytes are ever lost.

## Security model

The tmux server socket is root-owned and owner-only (mode 0600); the operator attaches as root through a fixed wrapper, and the reader group is never given socket access. The transcript is root-owned and readable only by root and by members of the reader group, by design. Everything shown in the tapped panes, including privileged output and text shaped like instructions, is written into that file as untrusted bytes.

## Install

NixOS module, minimal configuration:

```nix
services.tmux-share = {
  enable = true;
};
```

Plain systemd, three commands from the checkout, as root:

```sh
sudo ./install.sh
sudo systemctl enable --now tmux-share-server.service
tmux-share-attach --check
```

See docs/install-nixos.md and docs/install-systemd.md for the full steps.

## Commands an operator uses

- `tmux-share-attach` — attach to the monitored session; root only.
- `tmux-share-attach --check` — print the exact argv without running it; works for any user.
- `tmux-share-verify` — static check of modes, ownership, units and the stamp filter; run as root and again as the reader account.
- `tmux-share-preflight` — probe this host's tmux before a plain-systemd install.
- `systemctl status tmux-share-server.service` and `systemctl list-timers tmux-share-tap.timer tmux-share-trim.timer` — unit health.
- From the reader account: read `/run/tmux-share/transcript.log`.

## Limits

Recording is not gap-free. Output produced before the tap attaches at startup, and output from panes opened later, can be missed for up to one watchdog interval (20 seconds by default). A trim briefly closes the taps and loses bytes produced in that window, and a filter holding unwritten bytes can lose them too. Timestamps are local time with no zone and can land inside an escape sequence. An outage shorter than the five-minute not-ready grace is silent, and `/run` is memory-backed. The complete list is in docs/security-model.md.

## Documentation

- docs/security-model.md — threat model and every limit.
- docs/install-nixos.md — module options, minimal configuration, verification.
- docs/install-systemd.md — preflight, install, units, uninstall.
- docs/operations.md — daily use, timers, diagnosis, changing the session.

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
