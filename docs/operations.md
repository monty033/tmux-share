# Operations

Day-to-day use of a running tmux-share deployment. The two install paths are described in install-nixos.md and install-systemd.md; the limits in security-model.md apply at all times.

## Attaching

`tmux-share-attach` runs one fixed, validated tmux command. It is meant for root and for the account that owns the runtime directory (the configured `user`, root by default). When run from any other account it says so, naming the account, instead of showing a tmux error. That message is a courtesy to the operator, not a control: it looks at the directory of `TMUX_SHARE_SOCK`, which the caller supplies, so a caller can name a directory they own and get past it. What actually stops a third account is the kernel: the socket is created by tmux with mode 0600 and is owned by the service account, so `connect(2)` fails for everyone else, and the runtime directory is 0710 and owned by the service account, so nobody else can list it or place anything in it. Do not rely on the wrapper to keep anyone out. Detach from a session with tmux's usual `Ctrl-b d`.

```sh
sudo tmux-share-attach
```

To see exactly what would run without running it (works for any user, no root needed):

```sh
tmux-share-attach --check
```

tmux options are appended after the session name, so they pass straight through:

```sh
sudo tmux-share-attach -r
sudo tmux-share-attach -d
```

`-r` makes the *client* read-only and `-d` detaches other clients. `-r` is a convenience, not a security boundary: bindings that call `run-shell` still execute as the server owner. The reader account gets neither this command nor the socket. Remember that restarting the server ends your attached session.

## Reading the transcript

From the reader account, read `/run/tmux-share/transcript.log`. The file contains untrusted bytes, including escape sequences and text shaped like instructions, so avoid dumping it raw to a terminal. Use a viewer that makes control characters visible:

```sh
cat -v /run/tmux-share/transcript.log
sed -n 'l' /run/tmux-share/transcript.log
```

To check which groups your current process actually has:

```sh
id -nG
```

A **stale group** looks like a missing `tmux-share` entry in that output even after an account was added: group membership is fixed at process start, so a running agent keeps its old groups. Start a new login session or use `newgrp tmux-share` to get a shell with the new group, and restart any long-running agent that needs to read the file. Removing an account from the group has the same lag in reverse.

Run `tmux-share-verify` as the reader account to get a meaningful socket-connect check; as root that check is skipped. See security-model.md for who can read the file and why.

## Log growth and the trim bound

There is no external log rotation to configure. `tmux-share-trim` keeps the transcript at or below `TMUX_SHARE_MAX_BYTES` (default 2097152 bytes): when the file exceeds it, the trimmer closes the taps, keeps the newest `MAX_BYTES` bytes, and re-attaches. It leaves a file at or under the bound completely untouched.

- The trim timer runs every five minutes, so a file can temporarily exceed the bound between passes.
- Do not use a rotating tool that truncates the file in place (`copytruncate`): the tap pipes hold an open descriptor to the original inode. If the transcript is deleted or replaced out from under them, the watchdog notices the missing file, writes the rebuild marker and re-attaches the taps — but the bytes written to the old inode are lost.
- Trimming is not lossless. Bytes produced while the taps are closed are not recorded, and a filter holding unwritten bytes can lose them. See the trim loss window in security-model.md.

## What the timers do

Both are short-lived oneshot services started by timers; neither is a daemon and neither starts or restarts the server.

```sh
systemctl list-timers tmux-share-tap.timer tmux-share-trim.timer
systemctl status tmux-share-tap.service tmux-share-trim.service
```

- `tmux-share-tap.timer` runs the watchdog every 20 seconds (`OnBootSec=20s`, `OnUnitActiveSec=20s`). Each pass attaches the recording tap to panes whose pipe is not active, and retires and re-attaches every pane while the rebuild marker exists. This bounds the coverage gap for panes opened after startup to roughly one interval.
- `tmux-share-trim.timer` runs the trimmer every five minutes (`OnBootSec=5min`, `OnUnitActiveSec=5min`).

Both timers set `AccuracySec=1s`. systemd's default is one minute, which would stretch a nominal 20-second interval to as much as 80 seconds; with `AccuracySec=1s` the real interval is close to the nominal one, subject to ordinary scheduling delay.

## Diagnosing a failed unit

Start with unit state and the journal:

```sh
systemctl status tmux-share-server.service tmux-share-tap.service tmux-share-trim.service
journalctl -u tmux-share-server.service -u tmux-share-tap.service -u tmux-share-trim.service --since '1 hour ago'
```

**Not-ready grace.** A server that is briefly absent — no server running, a missing socket, or a session that cannot be found — is excused. The first sight stamps `/run/tmux-share/.notready-since` with the uptime, and passes inside the grace window (300 seconds by default) exit successfully; a successful pass clears the marker. So a short outage is silent, and a flapping server that recovers before the window ends can go unreported. Beyond the grace the unit fails and the journal names how long the server has been not ready. Permission refusals, timeouts and other errors are never excused.

**The rebuild marker.** `/run/tmux-share/.rebuild-required` is written by the trimmer when a re-attach fails (along with `RECORDING STOPPED` in the journal), and by the watchdog when the transcript is missing. While it exists, the watchdog retires and re-attaches every pane; it is removed only after all of them succeed. Inspect it as root:

```sh
sudo cat /run/tmux-share/.rebuild-required
sudo cat /run/tmux-share/.notready-since
```

A marker that never clears means re-attachment keeps failing — check the journal for the pane ids and for tmux errors. A stale `.notready-since` that predates a long outage is normally cleared by the next successful pass.

For a full static health check, including modes, ownership and the stamp filter:

```sh
sudo tmux-share-verify
```

Run it again as the reader account for the socket-connect verdict.

## Changing the session name

The name is part of the shared contract, so change it everywhere at once.

- NixOS: set `services.tmux-share.sessionName` to the new value and rebuild. The module rewrites the env file, the tmux configuration and the units.
- Plain systemd: re-render and reinstall with the new name, then restart the units:

```sh
sudo ./install.sh --session ops-shell
sudo systemctl restart tmux-share-server.service
```

Both paths restart the server, which drops the operator's attached session and its panes; perform the change from outside that session. The name must match `^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$` — the same rule the scripts enforce at run time. Anything still using the old name, such as a manually written `tmux-share-attach` command, must be updated too.

## Uninstalling cleanly

For the plain systemd path, follow the uninstall section of install-systemd.md: preview with `sudo ./uninstall.sh --dry-run`, then run `sudo ./uninstall.sh` (add `--purge` to remove the config directory and the runtime directory). The uninstaller stops and disables the units, keeps backups and unrelated files, and reloads systemd.

On NixOS, set `services.tmux-share.enable = false` (or remove the module) and rebuild from outside the monitored session; the declarative files disappear with the configuration, while runtime files under `/run` remain until reboot or a manual purge.
