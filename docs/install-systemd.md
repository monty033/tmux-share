# Installing on plain systemd

This is the no-Nix path. `install.sh` renders the configuration and lays out the files; it does not start, enable or grant anything to an account. All of those steps are printed at the end of the run and are listed below. Run the commands from the repository checkout.

## 1. Preflight

Before installing, check that this host's tmux actually supports the behaviour the design needs. The probe starts a throwaway server on a private socket and removes it on every exit path; the real server is never touched.

```sh
core/bin/tmux-share-preflight
```

It checks that `pipe-pane` attaches and detaches, that `#{pane_pipe}` reports state, that `list-panes -s` finds a pane id, that `exit-empty` can be set, and (warning-level) that `pipe-pane -o` toggles. Exit 0 means every required check passed; warnings do not fail the run. The tool refuses to run (exit 3) if the real socket path already exists, so it is safe to run on an installed host. Add `--json` for machine-readable output.

## 2. Dry run and the test-only prefix

```sh
./install.sh --dry-run
```

`--dry-run` lists every file, destination and mode without writing anything.

`--prefix DIR` stages the same layout under `DIR` instead of `/`; nothing outside `DIR` is touched and ownership is left as-is. It exists for the test suite and for inspection, **not** as a supported deployment: a staged tree has no enabled units and no running service.

```sh
./install.sh --prefix /tmp/install-stage
```

A real install requires root and an empty prefix; the script refuses otherwise.

## Running as an account other than root

By default every component runs as root. `--user NAME` makes the units run as an existing account and makes that account own the runtime files:

```sh example
sudo ./install.sh --user <operator>
```

- The install itself still needs root: it writes `/etc/systemd/system`. `--user root` is the default and changes nothing.
- The account must exist (`getent passwd`); the script never creates one and exits 2 when it is missing. It also exits 2 when the name is the reader account. The installer can only recognise the reader account through `TMUX_SHARE_READER`, so export it with the reader's name when you run the installer: the reader gets the transcript and never the socket, so it cannot also run the server.
- `tmux-share-server.service`, `tmux-share-tap.service` and `tmux-share-trim.service` gain `User=NAME`. The tmpfiles rules own the directory and transcript `NAME:READER-GROUP` and the lock `NAME:<primary group of NAME>`, looked up with `getent`. A group named like the account is not needed; the installer exits 2 if the primary group cannot be resolved.
- `/etc/tmux-share/tmux.conf` and `/etc/tmux-share/env` are mode 0640 and owned `NAME:READER-GROUP`. `NAME` owns them because the tmux server runs as `NAME` and has to read them, and the reader group can read them too. (The NixOS module writes the same ownership for a non-root `user`; for root it keeps its older root:root 0644, so the two paths differ there.)
- The session starts in the unit's working directory (`/`), not in a home directory.
- `tmux-share-attach` is meant for `NAME` and root, and tells anyone else so. That is a courtesy; the socket's mode and the runtime directory's ownership are what keep other accounts out (see `operations.md`). For verification, run `TMUX_SHARE_USER=NAME tmux-share-verify` after sourcing `/etc/tmux-share/env`, which already names it.

## 3. The real install

```sh
sudo ./install.sh
```

Files go to `/usr/local/lib/tmux-share/core/…` (scripts, libraries, stamp filter), symlinks in `/usr/local/bin`, unit files in `/etc/systemd/system`, the sysusers/tmpfiles rules in `/etc/sysusers.d` and `/etc/tmpfiles.d`, and the rendered config in `/etc/tmux-share`. A changed file is backed up as `NAME.bak.TIMESTAMP` before replacement. A second run with nothing to change says so.

If you want a different reader group or session name, pass `--reader GROUP` or `--session NAME` (both are validated); a re-run re-renders the config. `--force` skips the preflight and says so.

## 4. Create the runtime files and enable the units

`systemd-sysusers` must run before `systemd-tmpfiles --create`: the latter's rules reference the reader group that the former creates. Only after the files exist should the units be enabled.

```sh
sudo systemd-sysusers
sudo systemd-tmpfiles --create
sudo systemctl daemon-reload
sudo systemctl enable --now tmux-share-server.service
sudo systemctl enable --now tmux-share-tap.timer tmux-share-trim.timer
```

At the instant `install.sh` runs, the reader group may not exist yet, so it leaves `/etc/tmux-share/env` and `/etc/tmux-share/tmux.conf` with the root group (owned by `--user`, root by default). After `systemd-sysusers` has created the group, re-run the installer to fix that ownership:

```sh
sudo ./install.sh
```

## 5. Grant the reader account access

The sysusers rule creates only the group, never an account. Add an existing account to it once, as root:

```sh example
sudo usermod -aG tmux-share <reader>
```

The account must start a new login session before the new group takes effect; a running agent has to be restarted. See security-model.md for why this matters.

## 6. Verify

The plain install uses plain symlinks, not the NixOS wrappers, so source the generated environment file before running the verifier. Then run the verifier again as the reader account: the socket-connect check is skipped for root.

```sh
set -a; . /etc/tmux-share/env; set +a
tmux-share-verify
```

A zero exit status means no check failed. Checks that cannot apply are reported as `SKIP`. Do not set `TMUX_SHARE_VERIFY_OWNER` in production; it exists only so a test tree built without root can be verified.

## 7. Uninstall

```sh
sudo ./uninstall.sh --dry-run
sudo ./uninstall.sh
```

The uninstaller stops and disables the server unit and both timers, removes exactly the files this checkout would install, prunes empty directories it created, and keeps `NAME.bak.TIMESTAMP` backups and unrelated files. Add `--purge` to also remove `/etc/tmux-share` in full and, when run as root, the runtime directory `/run/tmux-share`:

```sh
sudo ./uninstall.sh --purge
```

## How this differs from the NixOS path

- There is no declarative rebuild: configuration lives in files under `/etc/tmux-share` and in environment variables, maintained by re-running `install.sh` rather than by a NixOS option set.
- Files are installed under `/usr/local` (and symlinked from `/usr/local/bin`), not from the Nix store.
- Config is under `/etc/tmux-share`; the NixOS module also writes there, but generates it from options.
- The reader group comes from a sysusers rule and must be created with `systemd-sysusers`; there is no `users.groups` declaration.
- The environment file must be sourced manually before running `tmux-share-verify`; the NixOS package's wrappers source it for you.

For daily operation, diagnosis and changing the session name, see operations.md. For the limits of what is recorded, see security-model.md.
