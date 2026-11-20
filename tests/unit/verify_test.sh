#!/usr/bin/env bash
# Tests for core/bin/tmux-share-verify.
#
# The verifier is deliberately testable without root: TMUX_SHARE_VERIFY_OWNER
# lets a tree built by an ordinary user be checked as if it were the
# production tree, so every case here runs unprivileged.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CORE=$(CDPATH= cd -- "$HERE/../.." && pwd)
VERIFY=$CORE/core/bin/tmux-share-verify
STAMP=$CORE/core/tmux-share-stamp

pass=0 fail=0 skip=0
ok()   { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
skp()  { skip=$((skip + 1)); printf 'skip %s\n' "$1"; }

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

ME_USER=$(id -un)
ME_GROUP=$(id -gn)

# Build a synthetic deployment tree that should pass.
# $1 = target dir
build_good_tree() {
    local t=$1
    mkdir -p "$t/deploy" "$t/bin" "$t/units"
    chmod 0710 "$t/deploy"
    : > "$t/deploy/transcript.log"
    chmod 0640 "$t/deploy/transcript.log"
    : > "$t/lock"
    chmod 0600 "$t/lock"
    cp "$STAMP" "$t/stamp"
    chmod 0755 "$t/stamp"
    # a script that never uses the toggle
    printf '#!/usr/bin/env bash\npipe-pane -t %%0 "exec cat"\n' > "$t/bin/tmux-share-watchdog"
    chmod 0755 "$t/bin/tmux-share-watchdog"
    cat > "$t/units/tmux-share-tap.service" <<'EOF'
[Service]
Type=oneshot
ExecStart=/usr/local/bin/tmux-share-watchdog
EOF
    cat > "$t/units/tmux-share-trim.service" <<'EOF'
[Service]
Type=oneshot
ExecStart=/usr/local/bin/tmux-share-trim
EOF
    cat > "$t/units/tmux-share-server.service" <<'EOF'
[Service]
Type=simple
ExecStart=/usr/bin/tmux -D -S /run/tmux-share/tmux.sock
EOF
}

# create a unix socket at $1 with mode $2 (needs python3; returns 1 if absent)
make_socket() {
    local path=$1 mode=$2
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$path" "$mode" <<'PY'
import os, socket, sys
path, mode = sys.argv[1], int(sys.argv[2], 8)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path)
os.chmod(path, mode)
s.close()
PY
}

# run the verifier against a tree built by build_good_tree
# run_verify TREE [BINDIR] -- BINDIR defaults to the synthetic tree's bin, but
# a case can point it at the repository's own scripts to check them.
run_verify() {
    local t=$1 bindir=${2:-} 
    shift || true
    [ -n "$bindir" ] && shift || true
    env TMUX_SHARE_DIR="$t/deploy" \
        TMUX_SHARE_SOCK="$t/deploy/tmux.sock" \
        TMUX_SHARE_LOG="$t/deploy/transcript.log" \
        TMUX_SHARE_LOCK="$t/lock" \
        TMUX_SHARE_STAMP="$t/stamp" \
        TMUX_SHARE_LIBDIR="$CORE/core/lib" \
        TMUX_SHARE_GROUP="$ME_GROUP" \
        TMUX_SHARE_BINDIR="${bindir:-$t/bin}" \
        TMUX_SHARE_UNITDIR="$t/units" \
        TMUX_SHARE_VERIFY_OWNER="$ME_USER:$ME_GROUP" \
        bash "$VERIFY" "$@"
}

# ---------------------------------------------------------------- case 1
T1=$TMP/good
build_good_tree "$T1"
make_socket "$T1/deploy/tmux.sock" 600 >/dev/null 2>&1 || skp 'socket fixture needs python3'
rc=0; out=$(run_verify "$T1" 2>&1) || rc=$?
if [ "$rc" -eq 0 ]; then ok 'a correct tree exits 0'; else bad "a correct tree exits 0 (rc=$rc)"; printf '%s\n' "$out" | tail -5; fi
case $out in
    *FAIL*) bad 'a correct tree reports no failures' ;;
    *) ok 'a correct tree reports no failures' ;;
esac

# ---------------------------------------------------------------- case 2
T2=$TMP/badlog; build_good_tree "$T2"; chmod 0644 "$T2/deploy/transcript.log"
rc=0; out=$(run_verify "$T2" 2>&1) || rc=$?
if [ "$rc" -ne 0 ]; then ok 'a world-readable transcript fails the run'; else bad 'a world-readable transcript fails the run'; fi
case $out in
    *transcript-mode-owner*) ok 'the transcript check is the one that failed' ;;
    *) bad 'the transcript check is the one that failed' ;;
esac

# ---------------------------------------------------------------- case 3
T3=$TMP/badsock; build_good_tree "$T3"
if make_socket "$T3/deploy/tmux.sock" 666 >/dev/null 2>&1; then
    rc=0; out=$(run_verify "$T3" 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then ok 'a world-writable socket fails the run'; else bad 'a world-writable socket fails the run'; fi
    case $out in
        *socket-owner-only*) ok 'the socket check is the one that failed' ;;
        *) bad 'the socket check is the one that failed' ;;
    esac
else
    skp 'world-writable socket case needs python3'
fi

# ---------------------------------------------------------------- case 4
T4=$TMP/badlock; build_good_tree "$T4"; chmod 0644 "$T4/lock"
rc=0; out=$(run_verify "$T4" 2>&1) || rc=$?
if [ "$rc" -ne 0 ]; then ok 'a group-readable lock fails the run'; else bad 'a group-readable lock fails the run'; fi
case $out in
    *lock-mode-owner*) ok 'the lock check is the one that failed' ;;
    *) bad 'the lock check is the one that failed' ;;
esac

# ---------------------------------------------------------------- case 5
T5=$TMP/toggle; build_good_tree "$T5"
make_socket "$T5/deploy/tmux.sock" 600 >/dev/null 2>&1 || true
printf '#!/usr/bin/env bash\npipe-pane -o -t %%0 "exec cat"\n' > "$T5/bin/tmux-share-watchdog"
rc=0; out=$(run_verify "$T5" 2>&1) || rc=$?
if [ "$rc" -ne 0 ]; then ok 'a script using pipe-pane -o fails the run'; else bad 'a script using pipe-pane -o fails the run'; fi
case $out in
    *no-pipe-pane-dash-o*) ok 'the toggle check is the one that failed' ;;
    *) bad 'the toggle check is the one that failed' ;;
esac

# ---------------------------------------------------------------- case 5b
# A tmux call that bypasses the bounded wrapper has no timeout. This passed
# every suite until the mutation suite removed the wrapper and nothing noticed.
T5b=$TMP/unbounded; build_good_tree "$T5b"
make_socket "$T5b/deploy/tmux.sock" 600 >/dev/null 2>&1 || true
printf '#!/usr/bin/env bash\npanes=$("$TMUX" list-panes -s -t sess)\n' > "$T5b/bin/tmux-share-watchdog"
rc=0; out=$(run_verify "$T5b" 2>&1) || rc=$?
if [ "$rc" -ne 0 ]; then ok 'a tmux call outside the bounded wrapper fails the run'; else bad 'a tmux call outside the bounded wrapper fails the run'; fi
case $out in
    *no-unbounded-tmux-call*) ok 'the unbounded-call check is the one that failed' ;;
    *) bad 'the unbounded-call check is the one that failed' ;;
esac

# ---------------------------------------------------------------- case 5c
# The static rules (the pipe-pane toggle and the unbounded tmux call) must be
# checked against the scripts this repository ships, not only against synthetic
# trees. Without this, bypassing tmux_bounded in core/bin passed every test.
T5c=$TMP/ownscripts; build_good_tree "$T5c"
make_socket "$T5c/deploy/tmux.sock" 600 >/dev/null 2>&1 || true
rc=0; out=$(run_verify "$T5c" "$CORE/core/bin" 2>&1) || rc=$?
# Only the two static checks matter here; the synthetic tree's ownership will
# legitimately fail the root-owned ones, so the verdict is per check name.
if printf '%s\n' "$out" | grep -qE '^FAIL no-(unbounded-tmux-call|pipe-pane-dash-o)'; then
    bad 'the shipped scripts satisfy the static rules'
    printf '%s\n' "$out" | grep -E '^FAIL no-(unbounded-tmux-call|pipe-pane-dash-o)' | head -2
else
    ok 'the shipped scripts satisfy the static rules'
fi

# ---------------------------------------------------------------- case 6
T6=$TMP/badstamp; build_good_tree "$T6"
make_socket "$T6/deploy/tmux.sock" 600 >/dev/null 2>&1 || true
printf '#!/usr/bin/env bash\ncat\n' > "$T6/stamp"; chmod 0755 "$T6/stamp"
rc=0; out=$(run_verify "$T6" 2>&1) || rc=$?
if [ "$rc" -ne 0 ]; then ok 'a stamp filter that only cats fails the run'; else bad 'a stamp filter that only cats fails the run'; fi
case $out in
    *stamp-filter*) ok 'the stamp check is the one that failed' ;;
    *) bad 'the stamp check is the one that failed' ;;
esac

# ---------------------------------------------------------------- case 7
# check 5 must never pass falsely: a socket this user owns is a SKIP, not a PASS.
T7=$TMP/ownedsock; build_good_tree "$T7"
if make_socket "$T7/deploy/tmux.sock" 600 >/dev/null 2>&1; then
    out=$(run_verify "$T7" 2>&1)
    case $out in
        *'SKIP reader-cannot-connect-socket'*) ok 'an owned socket is skipped, not passed' ;;
        *) bad 'an owned socket is skipped, not passed' ;;
    esac
else
    skp 'owned-socket case needs python3'
fi

# ---------------------------------------------------------------- case 8
# An uninstalled tree must produce skips, not failures.
T8=$TMP/empty; mkdir -p "$T8"
rc=0; out=$(env TMUX_SHARE_DIR="$T8/deploy" TMUX_SHARE_SOCK="$T8/deploy/tmux.sock" \
      TMUX_SHARE_LOG="$T8/deploy/transcript.log" TMUX_SHARE_LOCK="$T8/lock" \
      TMUX_SHARE_STAMP="$T8/stamp" TMUX_SHARE_LIBDIR="$CORE/core/lib" \
      TMUX_SHARE_BINDIR="$T8/bin" TMUX_SHARE_UNITDIR="$T8/units" \
      bash "$VERIFY" 2>&1) || rc=$?
if [ "$rc" -eq 0 ]; then ok 'an uninstalled tree exits 0'; else bad "an uninstalled tree exits 0 (rc=$rc)"; fi
case $out in
    *SKIP*) ok 'an uninstalled tree reports skips' ;;
    *) bad 'an uninstalled tree reports skips' ;;
esac

# ---------------------------------------------------------------- summary
printf '\nRESULT: %d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ] || exit 1
echo PASS
