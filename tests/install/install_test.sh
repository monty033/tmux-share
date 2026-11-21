#!/usr/bin/env bash
# Tests for install.sh and uninstall.sh.
#
# Every run goes to --prefix inside a fresh temp tree, so nothing outside it is
# written and no root is needed. The real-root path (empty prefix) is never run
# here. The non-root refusal case is skipped when this runs as root.
#
# The preflight probe needs a tmux, so two stand-ins are used:
#   faketmux  tests/stubs/fake-tmux behind a thin wrapper that answers the
#             subcommands the fake lacks (as tests/unit/preflight_test.sh does),
#             so the probe passes;
#   failtmux  a program that exits 1, so the probe fails.
# Every run starts with env -i, so no TMUX_SHARE_* variable from the caller's
# shell can reach the scripts.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
INSTALL=$ROOT/install.sh
UNINSTALL=$ROOT/uninstall.sh
FAKE=$ROOT/tests/stubs/fake-tmux

for v in $(env | grep -o '^TMUX_SHARE_[A-Z_]*' || true); do unset "$v"; done
unset TMUX TMUX_PANE FAKE_TMUX_STATE FAKE_TMUX_RC FAKE_TMUX_STDERR FAKE_TMUX_SLEEP WRAP_FAIL_PIPE

TOP=$(mktemp -d "${TMPDIR:-/tmp}/install-test.XXXXXX")
cleanup() {
    rm -rf -- "$TOP"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

PASSES=0
FAILS=0
SKIPS=0
pass() { PASSES=$((PASSES + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAILS=$((FAILS + 1)); printf 'FAIL %s\n' "$1"; }
skip() { SKIPS=$((SKIPS + 1)); printf 'SKIP %s\n' "$1"; }

# check_eq NAME ACTUAL EXPECTED
check_eq() {
    if [ "$2" = "$3" ]; then
        pass "$1"
    else
        fail "$1 (expected <$3> got <$2>)"
    fi
}

# check_contains NAME HAYSTACK NEEDLE
check_contains() {
    case $2 in
        *"$3"*) pass "$1" ;;
        *) fail "$1 (<$3> not found)" ;;
    esac
}

# check_link NAME PATH WANT_TARGET
check_link() {
    if [ -L "$2" ] && [ "$(readlink -- "$2")" = "$3" ]; then
        pass "$1"
    else
        fail "$1 (<$2> is not a link to <$3>)"
    fi
}

sum() { sha256sum -- "$1" | cut -d' ' -f1; }
mode_of() { stat -c %a -- "$1"; }

# snap DIR: names, types, modes, sizes and contents of everything under DIR.
snap() {
    find "$1" -mindepth 1 -printf '%p %y %m %s\n' | sort
    find "$1" -type f -exec sha256sum {} + | sort
}

# ---- stand-ins for tmux -------------------------------------------------------
mkdir -p -- "$TOP/bin"

# faketmux: fake-tmux plus the subcommands the preflight needs (copied from
# tests/unit/preflight_test.sh).
FAKEWRAP=$TOP/bin/faketmux
cat > "$FAKEWRAP" <<EOF
#!/usr/bin/env bash
set -eu
FAKE='$FAKE'
STATE=\$FAKE_TMUX_STATE
mkdir -p -- "\$STATE"
sock=''
while [ "\$#" -gt 0 ]; do
    case \$1 in
        -S) sock=\$2; shift 2 ;;
        -f) shift 2 ;;
        *) break ;;
    esac
done
if [ -n "\$sock" ]; then printf '%s\n' "\$sock" >> "\$STATE/sockets"; fi
sub=\${1:-}
if [ "\$#" -gt 0 ]; then shift; fi
case \$sub in
    new-session)
        name=''
        while [ "\$#" -gt 0 ]; do
            case \$1 in
                -s) name=\$2; shift 2 ;;
                -c) shift 2 ;;
                *) shift ;;
            esac
        done
        printf '%s\n' "\$name" >> "\$STATE/sessions"
        printf '%%0\t0\n' >> "\$STATE/state"
        : > "\$sock"
        ;;
    kill-server)
        [ -z "\$sock" ] || rm -f -- "\$sock"
        : > "\$STATE/sessions"
        : > "\$STATE/state"
        ;;
    display-message)
        exit 1
        ;;
    set-option)
        shift
        printf '%s\n' "\$2" > "\$STATE/opt.\$1"
        ;;
    show-options)
        if [ -f "\$STATE/opt.\$2" ]; then cat "\$STATE/opt.\$2"; else printf 'on\n'; fi
        ;;
    send-keys)
        pane=''
        text=''
        while [ "\$#" -gt 0 ]; do
            case \$1 in
                -t) pane=\$2; shift 2 ;;
                Enter) shift ;;
                *) text=\$1; shift ;;
            esac
        done
        while IFS=\$'\t' read -r p c; do
            if [ "\$p" = "\$pane" ]; then cmd=\$c; fi
        done < "\$STATE/commands"
        if [ -n "\${cmd:-}" ]; then
            printf '%s\n' "\$text" | bash -c "\$cmd"
        fi
        ;;
    pipe-pane)
        exec "\$FAKE" pipe-pane "\$@"
        ;;
    *)
        exec "\$FAKE" "\$sub" "\$@"
        ;;
esac
EOF
chmod +x "$FAKEWRAP"

# failtmux: a tmux that cannot do anything, so the probe fails.
FAILTMUX=$TOP/bin/failtmux
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAILTMUX"
chmod +x "$FAILTMUX"

# ---- run helpers ----------------------------------------------------------------
RC=0
OUT=''
ERR=''
CASE_DIR=''
CASE_TMP=''
CASE_STATE=''
P=''
EXTRA_ENV=()

# new_case NAME: a fresh tree; P is the prefix the case installs into.
new_case() {
    CASE_DIR=$TOP/$1
    CASE_TMP=$CASE_DIR/tmp
    CASE_STATE=$CASE_DIR/state
    P=$CASE_DIR/root
    mkdir -p -- "$CASE_TMP" "$CASE_STATE"
    EXTRA_ENV=()
}

# run SCRIPT TMUXBIN [ARGS...]: run with a clean environment; fills RC, OUT, ERR.
run() {
    local script=$1 tbin=$2
    shift 2
    RC=0
    env -i PATH="$PATH" TMPDIR="$CASE_TMP" \
        TMUX_SHARE_DIR="$CASE_DIR/run" TMUX_SHARE_TMUX="$tbin" \
        FAKE_TMUX_STATE="$CASE_STATE" \
        ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} \
        "$script" "$@" > "$CASE_DIR/out" 2> "$CASE_DIR/err" || RC=$?
    OUT=$(cat "$CASE_DIR/out")
    ERR=$(cat "$CASE_DIR/err")
}

# install_into TMUXBIN: a clean install into P, which must succeed.
install_into() {
    run "$INSTALL" "$1" --prefix "$P"
    if [ "$RC" -ne 0 ]; then
        fail "setup: install into $P failed (exit $RC): $ERR"
        return 1
    fi
}

LIB=''
set_lib() {
    LIB=$P/usr/local/lib/tmux-share/core
}

# ============================================================================
# 1. --help
# ============================================================================
new_case help
OUT=$("$INSTALL" --help 2>&1) && RC=0 || RC=$?
check_eq "help: install.sh --help exits 0" "$RC" 0
check_contains "help: install.sh --help prints usage" "$OUT" 'usage: install.sh'
OUT=$("$UNINSTALL" --help 2>&1) && RC=0 || RC=$?
check_eq "help: uninstall.sh --help exits 0" "$RC" 0
check_contains "help: uninstall.sh --help prints usage" "$OUT" 'usage: uninstall.sh'

# ============================================================================
# 2. bad arguments
# ============================================================================
new_case args
run "$INSTALL" "$FAKEWRAP" --bogus
check_eq "args: unknown install argument exits 2" "$RC" 2
run "$INSTALL" "$FAKEWRAP" --prefix relative/dir
check_eq "args: a relative --prefix exits 2" "$RC" 2
run "$UNINSTALL" "$FAKEWRAP" --prefix "$P" --bogus
check_eq "args: unknown uninstall argument exits 2" "$RC" 2

# ============================================================================
# 3. non-root refusal (skipped as root, where the refusal does not happen)
# ============================================================================
if [ "$(id -u)" -eq 0 ]; then
    skip "noroot: install and uninstall without --prefix (running as root)"
else
    new_case noroot
    run "$INSTALL" "$FAKEWRAP"
    check_eq "noroot: install without --prefix refused as non-root (exit 1)" "$RC" 1
    check_contains "noroot: install prints the sudo command" "$ERR" 'sudo '
    run "$UNINSTALL" "$FAILTMUX"
    check_eq "noroot: uninstall without --prefix refused as non-root (exit 1)" "$RC" 1
    check_contains "noroot: uninstall prints the sudo command" "$ERR" 'sudo '
fi

# ============================================================================
# 4. fresh install: every file, mode, link and rendered value
# ============================================================================
new_case fresh
run "$INSTALL" "$FAKEWRAP" --prefix "$P"
check_eq "fresh: install exits 0" "$RC" 0
check_contains "fresh: the preflight passed" "$OUT" 'preflight: ok'
check_eq "fresh: no scratch directory left behind" \
    "$(find "$CASE_TMP" -mindepth 1 | wc -l | tr -d ' ')" 0
set_lib

for f in "$ROOT"/core/bin/*; do
    n=${f##*/}
    check_eq "fresh: $n mode 0755" "$(mode_of "$LIB/bin/$n")" 755
    check_eq "fresh: $n identical to the repo copy" "$(sum "$LIB/bin/$n")" "$(sum "$f")"
    check_link "fresh: /usr/local/bin/$n links into core/bin" "$P/usr/local/bin/$n" "../lib/tmux-share/core/bin/$n"
    check_eq "fresh: /usr/local/bin/$n resolves to the installed script" \
        "$(realpath -- "$P/usr/local/bin/$n")" "$(realpath -- "$LIB/bin/$n")"
done
for f in "$ROOT"/core/lib/*; do
    n=${f##*/}
    check_eq "fresh: lib $n mode 0644" "$(mode_of "$LIB/lib/$n")" 644
    check_eq "fresh: lib $n identical to the repo copy" "$(sum "$LIB/lib/$n")" "$(sum "$f")"
done
check_eq "fresh: stamp mode 0755" "$(mode_of "$LIB/tmux-share-stamp")" 755
check_eq "fresh: stamp identical to the repo copy" \
    "$(sum "$LIB/tmux-share-stamp")" "$(sum "$ROOT/core/tmux-share-stamp")"
for f in "$ROOT"/systemd/*.service "$ROOT"/systemd/*.timer; do
    n=${f##*/}
    check_eq "fresh: unit $n mode 0644" "$(mode_of "$P/etc/systemd/system/$n")" 644
    check_eq "fresh: unit $n identical to the repo copy" \
        "$(sum "$P/etc/systemd/system/$n")" "$(sum "$f")"
done
check_eq "fresh: sysusers installed as sysusers.d/tmux-share.conf, mode 0644" \
    "$(mode_of "$P/etc/sysusers.d/tmux-share.conf")" 644
check_eq "fresh: sysusers identical to the repo copy" \
    "$(sum "$P/etc/sysusers.d/tmux-share.conf")" "$(sum "$ROOT/systemd/tmux-share.sysusers")"
check_eq "fresh: tmpfiles installed as tmpfiles.d/tmux-share.conf, mode 0644" \
    "$(mode_of "$P/etc/tmpfiles.d/tmux-share.conf")" 644
check_eq "fresh: tmpfiles identical to the repo copy" \
    "$(sum "$P/etc/tmpfiles.d/tmux-share.conf")" "$(sum "$ROOT/systemd/tmux-share.tmpfiles")"
check_eq "fresh: env mode 0640" "$(mode_of "$P/etc/tmux-share/env")" 640
check_eq "fresh: tmux.conf mode 0640" "$(mode_of "$P/etc/tmux-share/tmux.conf")" 640
check_contains "fresh: tmux.conf starts the default session" \
    "$(cat "$P/etc/tmux-share/tmux.conf")" 'new-session -d -s tmux-hermes'
check_contains "fresh: env records the lib dir inside the prefix" \
    "$(cat "$P/etc/tmux-share/env")" "TMUX_SHARE_LIBDIR='$LIB/lib'"
check_contains "fresh: env records the stamp inside the prefix" \
    "$(cat "$P/etc/tmux-share/env")" "TMUX_SHARE_STAMP='$LIB/tmux-share-stamp'"
if ( set -eu; . "$P/etc/tmux-share/env"; [ "$TMUX_SHARE_LIBDIR" = "$LIB/lib" ] ); then
    pass "fresh: env is shell-sourceable and sets TMUX_SHARE_LIBDIR"
else
    fail "fresh: env is shell-sourceable and sets TMUX_SHARE_LIBDIR"
fi
check_contains "fresh: next steps name the server unit" \
    "$OUT" 'systemctl enable --now tmux-share-server.service'
check_contains "fresh: next steps print the usermod command" \
    "$OUT" 'usermod -aG tmux-share <reader>'
check_contains "fresh: the usermod command is printed, not run" \
    "$OUT" 'not run by this script'
check_eq "fresh: no backups on a fresh install" \
    "$(find "$P" -name '*.bak.*' | wc -l | tr -d ' ')" 0

# A second run changes nothing and says so.
before=$(snap "$P")
run "$INSTALL" "$FAKEWRAP" --prefix "$P"
check_eq "rerun: exits 0" "$RC" 0
check_contains "rerun: says nothing changed" "$OUT" 'no changes'
check_eq "rerun: tree is identical (names, types, modes, sizes, contents)" "$(snap "$P")" "$before"
check_eq "rerun: no backups were made" \
    "$(find "$P" -name '*.bak.*' | wc -l | tr -d ' ')" 0

# ============================================================================
# 5. a changed file is backed up and replaced; a mode drift is fixed in place
# ============================================================================
new_case update
install_into "$FAKEWRAP"
printf 'not what we ship\n' > "$P/etc/systemd/system/tmux-share-server.service"
chmod 0644 "$P/etc/tmux-share/env"
run "$INSTALL" "$FAKEWRAP" --prefix "$P"
check_eq "update: exits 0" "$RC" 0
check_eq "update: the unit is back to the repo copy" \
    "$(sum "$P/etc/systemd/system/tmux-share-server.service")" \
    "$(sum "$ROOT/systemd/tmux-share-server.service")"
baks=("$P"/etc/systemd/system/tmux-share-server.service.bak.*)
check_eq "update: the replaced unit was kept as a .bak.<timestamp>" \
    "$(cat "${baks[0]}" 2>/dev/null)" 'not what we ship'
check_contains "update: the plan reports the replacement" "$OUT" 'update   '
check_eq "update: env mode restored to 0640" "$(mode_of "$P/etc/tmux-share/env")" 640
check_contains "update: the plan reports the mode fix" "$OUT" 'fixup    '
check_eq "update: a mode fix makes no backup" \
    "$(ls "$P/etc/tmux-share/" | grep -c 'bak' || true)" 0

# ============================================================================
# 6. --dry-run lists everything and writes nothing
# ============================================================================
new_case dry
run "$INSTALL" "$FAKEWRAP" --prefix "$P" --dry-run
check_eq "dry: exits 0" "$RC" 0
check_eq "dry: the prefix is not created" "$([ -e "$P" ] && echo exists || echo absent)" absent
check_contains "dry: names the env file" "$OUT" "$P/etc/tmux-share/env"
check_contains "dry: gives its mode" "$OUT" 'mode 0640'
check_contains "dry: names a core script" "$OUT" "$P/usr/local/lib/tmux-share/core/bin/tmux-share-render"
check_contains "dry: says nothing was written" "$OUT" 'nothing was written'
check_eq "dry: no scratch directory left behind" \
    "$(find "$CASE_TMP" -mindepth 1 | wc -l | tr -d ' ')" 0

# ============================================================================
# 7. preflight: a failing probe aborts before any write; --force proceeds
# ============================================================================
new_case preflight
run "$INSTALL" "$FAILTMUX" --prefix "$P"
check_eq "preflight: a failing probe exits 1" "$RC" 1
check_contains "preflight: names the failing check" "$ERR" 'FAIL scratch-server'
check_contains "preflight: says nothing was installed" "$ERR" 'nothing was installed'
check_eq "preflight: the prefix stays empty or absent" \
    "$(find "$P" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')" 0
run "$INSTALL" "$FAILTMUX" --prefix "$P" --force
check_eq "preflight: --force proceeds with a failing probe (exit 0)" "$RC" 0
check_contains "preflight: --force says the probe was skipped" "$ERR" 'SKIPPED'
check_eq "preflight: --force wrote the env file" \
    "$([ -f "$P/etc/tmux-share/env" ] && echo yes || echo no)" yes

# ============================================================================
# 8. --session, and a refused configuration writes nothing
# ============================================================================
new_case session
run "$INSTALL" "$FAKEWRAP" --prefix "$P" --session tmux-audit
check_eq "session: install with --session exits 0" "$RC" 0
check_contains "session: tmux.conf starts the named session" \
    "$(cat "$P/etc/tmux-share/tmux.conf")" 'new-session -d -s tmux-audit'
check_contains "session: env records the session" \
    "$(cat "$P/etc/tmux-share/env")" "TMUX_SHARE_SESSION='tmux-audit'"
run "$INSTALL" "$FAKEWRAP" --prefix "$P" --session 'bad name'
check_eq "session: an invalid --session exits 2" "$RC" 2

new_case badenv
EXTRA_ENV=(TMUX_SHARE_SESSION='bad name')
run "$INSTALL" "$FAKEWRAP" --prefix "$P"
check_eq "badenv: a value the renderer refuses exits 2" "$RC" 2
check_contains "badenv: the renderer names the refusal" "$ERR" 'rejected'
check_eq "badenv: nothing was written" \
    "$(find "$P" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')" 0

# ============================================================================
# 9. uninstall removes exactly what install created, and nothing else
# ============================================================================
new_case uclean
install_into "$FAKEWRAP"
set_lib
printf 'mine\n' > "$P/usr/local/lib/tmux-share/unrelated.txt"
printf 'mine\n' > "$P/usr/local/bin/unrelated-tool"
before=$(snap "$P")

run "$UNINSTALL" "$FAKEWRAP" --prefix "$P" --dry-run
check_eq "dry-uninstall: exits 0" "$RC" 0
check_eq "dry-uninstall: changes nothing" "$(snap "$P")" "$before"
check_contains "dry-uninstall: lists the env file" "$OUT" "$P/etc/tmux-share/env"

run "$UNINSTALL" "$FAKEWRAP" --prefix "$P"
check_eq "uninstall: exits 0" "$RC" 0
check_contains "uninstall: reports the removal" "$OUT" 'uninstalled: removed'
check_eq "uninstall: only the two unrelated files remain" \
    "$(find "$P" -type f | sort)" \
    "$(printf '%s\n' "$P/usr/local/bin/unrelated-tool" "$P/usr/local/lib/tmux-share/unrelated.txt" | sort)"
check_eq "uninstall: no symlink remains" "$(find "$P" -type l | wc -l | tr -d ' ')" 0
check_eq "uninstall: core/ removed" "$([ -e "$LIB" ] && echo yes || echo no)" no
check_eq "uninstall: etc/tmux-share removed once empty" \
    "$([ -e "$P/etc/tmux-share" ] && echo yes || echo no)" no
check_eq "uninstall: the unit file is gone" \
    "$([ -e "$P/etc/systemd/system/tmux-share-server.service" ] && echo yes || echo no)" no

# --purge removes the whole configuration directory, including added files.
new_case upurge
install_into "$FAKEWRAP"
printf 'operator note\n' > "$P/etc/tmux-share/notes.txt"
run "$UNINSTALL" "$FAKEWRAP" --prefix "$P" --purge
check_eq "purge: exits 0" "$RC" 0
check_eq "purge: etc/tmux-share removed entirely, operator notes included" \
    "$([ -e "$P/etc/tmux-share" ] && echo yes || echo no)" no
if [ "$(id -u)" -ne 0 ]; then
    check_contains "purge: the runtime directory is left alone without root" "$ERR" 'not root'
fi

# A backup of a replaced file is kept.
new_case ubackup
install_into "$FAKEWRAP"
printf 'old\n' > "$P/etc/systemd/system/tmux-share-tap.timer.bak.20000101000000"
run "$UNINSTALL" "$FAKEWRAP" --prefix "$P"
check_eq "backup: uninstall exits 0" "$RC" 0
check_eq "backup: the backup survives" \
    "$(cat "$P/etc/systemd/system/tmux-share-tap.timer.bak.20000101000000" 2>/dev/null)" old

# ============================================================================
# 10. a hostile symlink in the prefix aborts uninstall with nothing removed
# ============================================================================
new_case uhostile
install_into "$FAKEWRAP"
OUTSIDE=$CASE_DIR/outside
mkdir -p -- "$OUTSIDE"
printf 'victim\n' > "$OUTSIDE/victim"
rm -f -- "$P/usr/local/bin/tmux-share-preflight"
ln -s -- "$OUTSIDE/victim" "$P/usr/local/bin/tmux-share-preflight"
before=$(snap "$P")
run "$UNINSTALL" "$FAKEWRAP" --prefix "$P"
check_eq "hostile link: uninstall refuses (exit 1)" "$RC" 1
check_contains "hostile link: the refusal names the escape" "$ERR" 'outside the prefix'
check_eq "hostile link: the file outside is intact" "$(cat "$OUTSIDE/victim")" victim
check_eq "hostile link: nothing was removed" "$(snap "$P")" "$before"

new_case uhostiledir
install_into "$FAKEWRAP"
OUTSIDE=$CASE_DIR/outside
mkdir -p -- "$OUTSIDE/etcdir"
cp -- "$P/etc/tmux-share/env" "$OUTSIDE/etcdir/env"
cp -- "$P/etc/tmux-share/tmux.conf" "$OUTSIDE/etcdir/tmux.conf"
rm -rf -- "$P/etc/tmux-share"
ln -s -- "$OUTSIDE/etcdir" "$P/etc/tmux-share"
outside_before=$(snap "$OUTSIDE")
run "$UNINSTALL" "$FAKEWRAP" --prefix "$P"
check_eq "hostile dir: uninstall refuses (exit 1)" "$RC" 1
check_contains "hostile dir: the refusal names the escape" "$ERR" 'outside the prefix'
check_eq "hostile dir: nothing outside the prefix was touched" "$(snap "$OUTSIDE")" "$outside_before"
check_eq "hostile dir: the prefix's own files were not removed" \
    "$([ -e "$P/usr/local/lib/tmux-share/core/tmux-share-stamp" ] && echo yes || echo no)" yes

# ============================================================================
# --user: run as an account other than root
# ============================================================================
# A stand-in getent that knows three accounts. The test runs without root and on
# hosts that have none of them, so the real getent cannot be what answers; every
# other lookup goes to the real one.
#   bob    primary group "users" (gid 100): a normal account, no group of its own
#   eve    primary group "eve" (gid 4242): an account with a group named like it
#   ghost  primary gid 9999, which no group has: the group cannot be resolved
REAL_GETENT=$(command -v getent)
mkdir -p -- "$TOP/userbin"
cat > "$TOP/userbin/getent" <<EOF
#!/bin/sh
case "\$1 \$2" in
    "passwd bob") echo "bob:x:1001:100::/srv/bob:/bin/sh"; exit 0 ;;
    "passwd eve") echo "eve:x:4242:4242::/srv/eve:/bin/sh"; exit 0 ;;
    "passwd ghost") echo "ghost:x:4300:9999::/srv/ghost:/bin/sh"; exit 0 ;;
    "group 100") echo "users:x:100:"; exit 0 ;;
    "group 4242") echo "eve:x:4242:"; exit 0 ;;
esac
exec $REAL_GETENT "\$@"
EOF
chmod 0755 -- "$TOP/userbin/getent"

# rules FILE: the non-comment, non-blank lines of a tmpfiles file.
rules() { grep -v '^[[:space:]]*\(#\|$\)' "$1"; }

# Root is the default and --user root is the same thing: the installed units and
# rules are the templates, byte for byte, and the env names no user.
new_case userroot
run "$INSTALL" "$FAKEWRAP" --prefix "$P" --user root
check_eq "user root: install exits 0" "$RC" 0
for u in tmux-share-server.service tmux-share-tap.service tmux-share-trim.service \
        tmux-share-tap.timer tmux-share-trim.timer; do
    check_eq "user root: $u is the template, byte for byte" \
        "$(sum "$P/etc/systemd/system/$u")" "$(sum "$ROOT/systemd/$u")"
done
check_eq "user root: tmpfiles rules are the template, byte for byte" \
    "$(sum "$P/etc/tmpfiles.d/tmux-share.conf")" "$(sum "$ROOT/systemd/tmux-share.tmpfiles")"
check_eq "user root: the env names no TMUX_SHARE_USER" \
    "$(grep -c '^TMUX_SHARE_USER=' "$P/etc/tmux-share/env" || true)" 0
check_eq "user root: no unit has a User= line" \
    "$(cat "$P"/etc/systemd/system/* | grep -c '^User=' || true)" 0

# A TMUX_SHARE_USER inherited from the caller must not reach the rendered env:
# the units are written from --user, so the env has to agree with them.
new_case userinherit
EXTRA_ENV=(TMUX_SHARE_USER=mallory)
run "$INSTALL" "$FAKEWRAP" --prefix "$P"
check_eq "user inherited: install exits 0" "$RC" 0
check_eq "user inherited: the caller's TMUX_SHARE_USER does not reach the env" \
    "$(grep -c 'mallory' "$P/etc/tmux-share/env" || true)" 0

# A real account: every service runs as it and the rules are owned by it.
new_case userbob
PATH=$TOP/userbin:$PATH run "$INSTALL" "$FAKEWRAP" --prefix "$P" --user bob
check_eq "user bob: install exits 0" "$RC" 0
check_contains "user bob: the plan shows the owner of the rendered files" "$OUT" 'group tmux-share, owner bob'
for u in tmux-share-server.service tmux-share-tap.service tmux-share-trim.service; do
    f=$P/etc/systemd/system/$u
    check_eq "user bob: $u has exactly one User=bob" "$(grep -c '^User=bob$' "$f")" 1
    check_eq "user bob: $u has exactly one User= line of any kind" "$(grep -c '^User=' "$f")" 1
    check_eq "user bob: $u has no root User=" "$(grep -c '^User=root' "$f" || true)" 0
    # The only difference from the template is the two lines the installer adds.
    check_eq "user bob: $u is the template plus the User= lines and their comment" \
        "$(grep -v '^User=bob$\|^# User: ' "$f" | sha256sum)" "$(sha256sum < "$ROOT/systemd/$u")"
    # The directive sits inside [Service], where systemd reads it.
    check_eq "user bob: $u has User= inside [Service]" \
        "$(awk '/^\[/ { s = $0 } /^User=/ { print s }' "$f")" '[Service]'
done
for t in tmux-share-tap.timer tmux-share-trim.timer; do
    check_eq "user bob: $t is unchanged (a timer takes no User=)" \
        "$(sum "$P/etc/systemd/system/$t")" "$(sum "$ROOT/systemd/$t")"
done
tf=$P/etc/tmpfiles.d/tmux-share.conf
check_eq "user bob: the runtime directory rule is owned bob:tmux-share" \
    "$(rules "$tf" | grep '^d ')" 'd /run/tmux-share 0710 bob tmux-share - -'
check_eq "user bob: the transcript rule is owned bob:tmux-share" \
    "$(rules "$tf" | grep 'transcript.log')" 'f /run/tmux-share/transcript.log 0640 bob tmux-share - -'
check_eq "user bob: the lock rule is owned bob:users, the primary group, not a group named bob" \
    "$(rules "$tf" | grep 'tmux-share.lock')" 'f /run/tmux-share.lock 0600 bob users - -'
check_eq "user bob: no rule still names root" "$(rules "$tf" | grep -c ' root ' || true)" 0
check_eq "user bob: modes are the template's, rule for rule" \
    "$(rules "$tf" | awk '{print $1, $2, $3}')" \
    "$(rules "$ROOT/systemd/tmux-share.tmpfiles" | awk '{print $1, $2, $3}')"
check_eq "user bob: the env names bob" "$(grep -c "^TMUX_SHARE_USER='bob'$" "$P/etc/tmux-share/env")" 1
check_eq "user bob: env mode is still 0640" "$(mode_of "$P/etc/tmux-share/env")" 640
check_eq "user bob: tmux.conf mode is still 0640" "$(mode_of "$P/etc/tmux-share/tmux.conf")" 640

# A second run with the same account changes nothing.
PATH=$TOP/userbin:$PATH run "$INSTALL" "$FAKEWRAP" --prefix "$P" --user bob
check_eq "user bob: a second run exits 0" "$RC" 0
check_contains "user bob: a second run changes nothing" "$OUT" 'no changes'

# An account with no group named after it (bob: primary group "users") must not
# make the installer name one: systemd-tmpfiles fails a rule whose group does not
# exist, so the lock would not be created at boot. Nothing here may mention a
# group "bob", in the rules or in a warning.
check_eq "user bob: no rule names a group called bob" "$(rules "$tf" | grep -c ' bob bob ' || true)" 0
new_case userbobwarn
PATH=$TOP/userbin:$PATH run "$INSTALL" "$FAKEWRAP" --prefix "$P" --user bob
check_eq "user bob: a first install prints no warning about a missing same-named group" "$(printf '%s\n' "$ERR" | grep -c "no group named" || true)" 0

# An account that does have a group of its own gets that group, which is also
# its primary group.
new_case usereve
PATH=$TOP/userbin:$PATH run "$INSTALL" "$FAKEWRAP" --prefix "$P" --user eve
check_eq "user eve: install exits 0" "$RC" 0
check_eq "user eve: the lock rule is owned eve:eve" \
    "$(rules "$P/etc/tmpfiles.d/tmux-share.conf" | grep 'tmux-share.lock')" 'f /run/tmux-share.lock 0600 eve eve - -'

# A primary group that cannot be resolved is refused before anything is written.
new_case userghost
PATH=$TOP/userbin:$PATH run "$INSTALL" "$FAKEWRAP" --prefix "$P" --user ghost
check_eq "user ghost: an unresolvable primary group exits 2" "$RC" 2
check_contains "user ghost: the refusal says the primary group is unknown" "$ERR" 'cannot determine the primary group'
check_eq "user ghost: nothing was written" "$([ -e "$P" ] && echo yes || echo no)" no

# --dry-run shows the user and writes nothing.
new_case userdry
PATH=$TOP/userbin:$PATH run "$INSTALL" "$FAKEWRAP" --prefix "$P" --user bob --dry-run
check_eq "user dry-run: exits 0" "$RC" 0
check_contains "user dry-run: names the owner" "$OUT" 'owner bob'
check_eq "user dry-run: writes nothing" "$([ -e "$P" ] && echo yes || echo no)" no

# An account that does not exist is refused before anything is written. No
# stand-in: the real getent must not know this name.
new_case userunknown
run "$INSTALL" "$FAKEWRAP" --prefix "$P" --user no-such-account-xyz
check_eq "user unknown: exits 2" "$RC" 2
check_contains "user unknown: the refusal says the account does not exist" "$ERR" 'does not exist'
check_eq "user unknown: nothing was written" "$([ -e "$P" ] && echo yes || echo no)" no

# The reader account is never the operator. The installer only knows it through
# TMUX_SHARE_READER, so that is what is compared.
new_case userreader
EXTRA_ENV=(TMUX_SHARE_READER=bob)
PATH=$TOP/userbin:$PATH run "$INSTALL" "$FAKEWRAP" --prefix "$P" --user bob
check_eq "user reader: --user equal to the reader account exits 2" "$RC" 2
check_contains "user reader: the refusal names the reader account" "$ERR" 'reader account'
check_eq "user reader: nothing was written" "$([ -e "$P" ] && echo yes || echo no)" no

# The name is written into unit files and rules, so only a plain name gets in.
new_case userbad
for bad in 'a;b' 'a b' '-lead' 'a/b' '' 'x$(id)' "a'b" 'abcdefghijklmnopqrstuvwxyzabcdefg'; do
    PATH=$TOP/userbin:$PATH run "$INSTALL" "$FAKEWRAP" --prefix "$P" --user "$bad"
    check_eq "user bad: '$bad' is refused (exit 2)" "$RC" 2
    # The renderer refuses these names too, later and with its own message. The
    # installer's check is the one that runs first and before anything is
    # rendered, so it is the one that has to be seen to fire.
    check_contains "user bad: '$bad' is refused by the installer's own check" "$ERR" 'invalid --user account name'
done
check_eq "user bad: nothing was written" "$([ -e "$P" ] && echo yes || echo no)" no
run "$INSTALL" "$FAKEWRAP" --prefix "$P" --user
check_eq "user bad: --user without a value exits 2" "$RC" 2

# ============================================================================
# summary
# ============================================================================
printf '\ninstall_test: %d passed, %d failed, %d skipped\n' "$PASSES" "$FAILS" "$SKIPS"
if [ "$FAILS" -eq 0 ]; then
    printf 'PASS\n'
    exit 0
fi
printf 'FAIL\n'
exit 1
