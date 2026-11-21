# Security model

This document states the boundary tmux-share implements and, just as importantly, every place where it does not hold. It is written from the scripts and units in this repository, not from an idealized design.

## The boundary

The tmux server socket lives in the runtime directory owned by the service account (root unless a `user` is configured; the rest of this page says root), is created by tmux itself with mode 0600 and is owned by that account. Only it, and root, can connect to it. The operator attaches as that account or root through `tmux-share`, which builds one fixed, validated `tmux -S` / `attach -t` command line; extra arguments are appended after the session. The reader account is never given this command and never gets a file descriptor for the socket — it can only open the transcript.

tmux's own read-only client mode is **not** a boundary. The attach wrapper happily passes `-r` through to tmux, but a read-only client only restricts what the *client* may type; key bindings that call `run-shell` or `if-shell` still execute as the tmux server owner, which here is root. Handing a reader a client, even a read-only one, would hand it root's shell through tmux's configuration. The boundary is the kernel's permission check on the socket, not a tmux option.

The transcript is separated from the socket by directory permissions: `/run/tmux-share` is mode 0710 root:tmux-share, so group members can open a path they already know (the transcript) but cannot list the directory to discover what else is there. The advisory lock is deliberately root-only (mode 0600) and lives outside that directory, because `flock` needs only read access and a reader who could open the lock could stall the taps. Nothing is world-readable or world-writable.

## Who can read the transcript

Root and **every member of the reader group**, by design. The transcript is mode 0640 root:tmux-share; the group has read access and no write access, so a reader cannot alter or truncate the record. There is no per-pane, per-command or per-user filtering inside the file. If three accounts are in the group, all three can read all of it forever (until the file is trimmed or the host reboots). Adding someone to the group is a permanent grant to everything already recorded and everything recorded while they remain a member.

The group is the unit of trust. Anyone who can add members to it can widen the audience, so group membership should be treated as a privileged change. The boundary assumes that root is uncompromised and that the host's sudo policy grants the reader no route to root, to the socket, or to group-management commands.

## What the transcript contains

Everything displayed in each tapped pane, byte for byte as it is rendered, including the output of privileged commands, secrets that were printed to the screen, and anything pasted into the shell. It is not a redacted or sanitized log. The stamp filter only inserts `\r\n[YYYY-MM-DD HH:MM:SS] ` markers; it does not inspect, decode or rewrite the bytes.

The transcript is therefore **untrusted input**. It can contain terminal escape sequences (colour, cursor movement, screen clears, title changes) and text deliberately shaped like prompts, instructions or tool output. Do not `cat` it raw to a terminal: a hostile program can use those bytes to manipulate what you see or to feed instructions to anything that reads the file. View it with a tool that makes control characters visible, for example `cat -v` or `sed -n 'l'`, and never pipe it into a program that interprets escape sequences as commands.

## Coverage gaps

The tap is not attached at every moment:

- **Startup.** `tmux-share-tap-start` runs as `ExecStartPost` just after the server forks and waits up to about ten seconds for the session to appear. Anything a pane renders before its pipe is attached is not recorded.
- **Panes opened later.** The watchdog attaches taps on a timer, nominally every 20 seconds (`OnBootSec=20s`, `OnUnitActiveSec=20s`, `AccuracySec=1s`). A pane created after startup can therefore produce up to one timer interval of output — about 20 seconds — before it is tapped. `AccuracySec=1s` keeps systemd's default one-minute slop out of that figure, but scheduling delay still applies.
- **During a trim.** The trimmer closes every tap while it copies and renames the transcript, then re-attaches them from an exit trap. Output produced while the taps are closed is not recorded.
- **A failed stamp filter.** If `tmux-share-stamp` hits a read or write error it exits non-zero and its pipe ends. That pane produces no transcript bytes until a watchdog pass notices and re-attaches it, again within roughly one interval; the bytes produced in between are gone.

There is no second source of truth. If a gap happens, the missing bytes are simply absent.

## The trim loss window

The trimmer does not promise zero loss. Its sequence is: enumerate panes, close every tap with `pipe-pane -t PANE` (no command), copy the newest `TMUX_SHARE_MAX_BYTES` bytes to a temporary file, give it the old mode and ownership, atomically rename it over the transcript, then re-attach the taps.

- Bytes produced between closing the taps and re-attaching them are **not recorded**. That window covers the copy and the rename, so it grows with the size bound. Taps are closed first only so the file stops growing while it is copied.
- A filter that has read bytes but not yet written them when its tap closes finishes writing them to the **old** file descriptor. If that happens after the copy or after the rename, those bytes go to an unlinked inode and are lost.
- Panes created during the window get no tap from the trimmer; they are left for the watchdog.
- The kept region starts at an arbitrary byte, so the new file may begin in the middle of a line, a UTF-8 character or an escape sequence.
- If re-attaching fails, the trimmer prints `RECORDING STOPPED`, writes the failed pane ids to `/run/tmux-share/.rebuild-required`, and exits non-zero. It never leaves recording stopped silently, but until a watchdog pass rebuilds the taps, recording is stopped. `SIGKILL` cannot be trapped, so a killed trimmer can leave taps closed.

## Retention

`/run/tmux-share` is tmpfs: it lives in memory and may be swapped out by the kernel. The transcript outlives the individual pane it was recorded from, but not a reboot of the host. tmux scrollback is likewise in memory and is not durable either. Treat the transcript as a recent, volatile record, not as long-term storage — copy it elsewhere if you need to keep it.

The trimmer verifies that it wrote the expected number of bytes, but issues no `fsync`; "complete" means the byte count matched, not that the data reached stable storage. A crash at the wrong moment can lose more than the documented trim window.

## Timestamps

`tmux-share-stamp` prefixes resumed bursts with `\r\n[YYYY-MM-DD HH:MM:SS] ` using local time via `time.localtime`. There is no time zone or UTC offset in the stamp, so its meaning depends on the host's local time setting and is ambiguous across a clock change. Stamps are inserted at chunk boundaries, not at line boundaries, so a stamp may appear in the middle of an unfinished escape sequence, a partial UTF-8 character, or a partially written line. They look like ordinary text in the file and carry no cryptographic weight; deleting exactly the inserted stamps reproduces the original byte stream.

## Outages

A server that is "not ready" — no server running, a missing socket, or a session that cannot be found — is excused for a bounded grace period. The first observation stamps `/run/tmux-share/.notready-since` with the host uptime, and passes inside the grace window (default 300 seconds, `TMUX_SHARE_NOTREADY_GRACE`) exit successfully. A successful enumeration clears the marker. The clock is uptime, not wall time, so NTP steps and manual clock changes do not stretch the window.

Two consequences follow. An outage shorter than the grace is **silent**: no unit fails, nothing appears beyond a journal note that the pass was excused. A flapping server that comes back before the marker expires can go unreported indefinitely, because each success clears the marker and the next gap starts a fresh window. Refusals (`Permission denied`), timeouts and wedged calls are not excused; they fail immediately. Failures of any kind surface only in the journal and in the unit's state (`Active: failed`), never in the transcript.

## Server restarts and the operator's shell environment

The tmux server owns the monitored session, so restarting `tmux-share-server.service` (including a NixOS rebuild that changes that unit) tears down the operator's attached session. Run maintenance and rebuilds from outside the session you care about.

The shell the operator gets inside the session is the server's: `default-shell` comes from the server's tmux configuration, and PATH, TERM and the umask are inherited from the server process. The units and module deliberately set no `UMask`, because a restrictive umask there would become the umask of every shell the operator opens. Changing any of these requires restarting the server, with the session disruption that implies.

## Assumptions about root and sudo

The boundary assumes root is uncompromised. Every tmux-share component — server, tap-start, watchdog, trimmer — runs as one account: root by default, or the single existing account named by `services.tmux-share.user` or `install.sh --user`. It records what that account's shell does and manages its runtime files. Choosing another account does not change the model: the reader still gets the transcript and never the socket, that account can drive the shell, and it must not be the reader. The account is an operator, not a sandbox: nothing here makes the service rootless. It also assumes the host's sudo policy gives the reader nothing useful: no ability to read the socket, run `tmux-share`, alter the group, or become root. If a reader can do any of those, the separation this design provides is void.

## The toggle trap

`tmux pipe-pane -o` toggles: on the tmux version measured here (3.7b) a second `-o` call **detaches** the tap instead of re-attaching it, silently stopping recording. `tmux-share-preflight` documents this in its `pipe-pane-o-toggle` check (warning-level, never a failure). For that reason no script ever calls `pipe-pane -o`: taps are attached with `pipe-pane -t PANE "exec … >> …"` and closed with a bare `pipe-pane -t PANE`. `tmux-share-verify` makes this a hard rule — its `no-pipe-pane-dash-o` check fails if any installed script calls `pipe-pane` with `-o`.

## Group membership is not retroactive

Group membership is decided when a process starts. Adding an account to the reader group does not change any process that is already running: a long-lived agent keeps its old supplementary groups and still cannot open the transcript. The account must start a new login session (or a fresh process with the new groups, for example via `newgrp tmux-share`) for the grant to take effect, and a running agent must be restarted. The same applies in reverse — removing membership does not revoke access from an already-running process that holds the group.
