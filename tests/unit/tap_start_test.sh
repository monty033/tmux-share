#!/usr/bin/env bash
# Unit test for core/bin/tmux-share-tap-start.
#
# Drives the real script against tests/stubs/fake-tmux through the contract's
# environment variables. fake-tmux has no has-session and does not understand
# the global "-S SOCK" option, so each scenario puts a thin wrapper in front
# of it (in the temp dir) that drops -S, answers has-session from the fake's
# sessions file, and passes everything else through unchanged. Tests also
# shim `timeout` and `flock` to shorten the waits; the shims log what the
# script asked for so the real values are still asserted.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
SCRIPT=$ROOT/core/bin/tmux-share-tap-start
FAKE=$ROOT/tests/stubs/fake-tmux
REAL_STAMP=$ROOT/core/tmux-share-stamp
REAL_FLOCK=$(command -v flock) || { echo 'FAIL: flock not installed' >&2; exit 1; }
REAL_TIMEOUT=$(command -v timeout) || { echo 'FAIL: timeout not installed' >&2; exit 1; }

TOP=$(mktemp -d "${TMPDIR:-/tmp}/tap-start-test.XXXXXX")
cleanup() {
    exec 8>&- 2>/dev/null || true
    rm -rf -- "$TOP"
}
trap cleanup EXIT

PASSES=0
FAILS=0
pass() { PASSES=$((PASSES + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAILS=$((FAILS + 1)); printf 'FAIL %s\n' "$1"; }

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
        *) fail "$1 (<$3> not found in <$2>)" ;;
    esac
}

mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

# count_args PATTERN: lines of calls.log whose ARGS field matches the ERE.
count_args() {
    local n=0 rc args rest
    [ -f "$STATE/calls.log" ] || { printf '0'; return 0; }
    while IFS=$'\t' read -r rc args rest; do
        if [[ $args =~ $1 ]]; then n=$((n + 1)); fi
    done < "$STATE/calls.log"
    printf '%s' "$n"
}

pipe_of() {
    local p v
    while IFS=$'\t' read -r p v; do
        if [ "$p" = "$1" ]; then printf '%s' "$v"; return 0; fi
    done < "$STATE/state"
    printf 'MISSING'
}

command_of() {
    local p c
    while IFS=$'\t' read -r p c; do
        if [ "$p" = "$1" ]; then printf '%s' "$c"; return 0; fi
    done < "$STATE/commands"
    printf 'MISSING'
}

# new_env NAME: fresh temp tree with a session "work" holding panes %0 and %1.
new_env() {
    T=$TOP/$1
    STATE=$T/state
    mkdir -p -- "$T/bin" "$STATE"
    printf '%s\n' work > "$STATE/sessions"
    printf '%s\t%s\n' '%0' '0' > "$STATE/state"
    printf '%s\t%s\n' '%1' '0' >> "$STATE/state"

    # The stamp path must pass validate_token (<= 64 chars), so link to it.
    ln -s -- "$REAL_STAMP" "$T/stamp"

    cat > "$T/bin/tmux" <<'WRAP'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FAKE_TMUX_STATE/invoked.log"
if [ "${1:-}" = -S ]; then shift 2; fi
case "${1:-}" in
    has-session)
        name=''
        shift
        while [ "$#" -gt 0 ]; do
            if [ "$1" = -t ] && [ "$#" -ge 2 ]; then name=$2; shift 2; else shift; fi
        done
        grep -qxF -- "$name" "$FAKE_TMUX_STATE/sessions"
        exit
        ;;
    pipe-pane)
        if [ -n "${WRAP_FAIL_PANE:-}" ]; then
            for a in "$@"; do
                if [ "$a" = "$WRAP_FAIL_PANE" ]; then
                    printf '%s\n' "$*" >> "$FAKE_TMUX_STATE/calls.log"
                    echo 'injected pipe-pane failure' >&2
                    exit 1
                fi
            done
        fi
        ;;
esac
exec "$FAKE_TMUX_REAL" "$@"
WRAP
    # timeout shim: ignore the requested duration, use one second.
    cat > "$T/bin/fast-timeout" <<'SHIM'
#!/usr/bin/env bash
shift
exec "$REAL_TIMEOUT" 1 "$@"
SHIM
    # flock shim: log the request, then wait only one second for the lock.
    cat > "$T/bin/flock" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FLOCK_ARGS_LOG"
if [ "$1" = -w ]; then shift 2; fi
exec "$REAL_FLOCK" -w 1 "$@"
SHIM
    chmod +x "$T/bin/tmux" "$T/bin/fast-timeout" "$T/bin/flock"

    # Environment for the script under test.
    SESSION=work
    LOG=$T/transcript.log
    LOCK=$T/tap.lock
    STAMP=$T/stamp
    TIMEOUT_BIN=$REAL_TIMEOUT
}

# run_script: run the real script, set OUT (stdout+stderr), RC and ELAPSED.
run_script() {
    local t0 t1
    t0=$(date +%s)
    if OUT=$(
        umask 022
        PATH=$T/bin:$PATH \
        FAKE_TMUX_STATE=$STATE \
        FAKE_TMUX_REAL=$FAKE \
        REAL_FLOCK=$REAL_FLOCK \
        REAL_TIMEOUT=$REAL_TIMEOUT \
        FLOCK_ARGS_LOG=$T/flock.args \
        TMUX_SHARE_DIR=$T \
        TMUX_SHARE_SESSION=$SESSION \
        TMUX_SHARE_SOCK=$T/tmux.sock \
        TMUX_SHARE_LOG=$LOG \
        TMUX_SHARE_LOCK=$LOCK \
        TMUX_SHARE_STAMP=$STAMP \
        TMUX_SHARE_TMUX=$T/bin/tmux \
        TMUX_SHARE_TIMEOUT=$TIMEOUT_BIN \
        "$SCRIPT" 2>&1
    ); then
        RC=0
    else
        RC=$?
    fi
    t1=$(date +%s)
    ELAPSED=$((t1 - t0))
}

[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT is not executable" >&2; exit 1; }

# ---- 1. first run: two panes tapped, no -o ----------------------------------
new_env first
run_script
check_eq "first run exits 0" "$RC" 0
check_eq "first run: pane %0 has pipe=1" "$(pipe_of '%0')" 1
check_eq "first run: pane %1 has pipe=1" "$(pipe_of '%1')" 1
check_eq "first run: exactly two pipe-pane calls" "$(count_args '^pipe-pane ')" 2
check_eq "first run: no pipe-pane call uses -o" "$(count_args '^pipe-pane .*-o ')" 0
check_eq "first run: one pipe-pane call per pane" \
    "$(count_args '^pipe-pane -t %0 ')$(count_args '^pipe-pane -t %1 ')" 11

# ---- 2. the recorded tap command --------------------------------------------
for pane in '%0' '%1'; do
    cmd=$(command_of "$pane")
    check_contains "tap command for $pane mentions the stamp program" "$cmd" "$STAMP"
    check_contains "tap command for $pane mentions the log path" "$cmd" "$LOG"
done

# ---- 2b. modes and flock request --------------------------------------------
check_eq "log created with mode 0640" "$(mode_of "$LOG")" 640
check_eq "lock created with mode 0600" "$(mode_of "$LOCK")" 600
check_eq "flock asked for -w 20 -x 9" "$(head -n 1 "$T/flock.args")" '-w 20 -x 9'

# ---- 3. second run: idempotent ----------------------------------------------
before=$(count_args '^pipe-pane ')
run_script
check_eq "second run exits 0" "$RC" 0
check_eq "second run adds no pipe-pane calls" "$(( $(count_args '^pipe-pane ') - before ))" 0
check_eq "second run leaves pane %0 with pipe=1" "$(pipe_of '%0')" 1
check_eq "second run leaves pane %1 with pipe=1" "$(pipe_of '%1')" 1
check_contains "second run reports no work" "$OUT" 'nothing to do'

# ---- 4. existing log is neither failed on nor altered -----------------------
new_env existing
printf 'keep\n' > "$LOG"
chmod 0664 "$LOG"
run_script
check_eq "existing log: exits 0" "$RC" 0
check_eq "existing log: content untouched" "$(cat "$LOG")" keep
# 0664 was tolerated before the transcript contract was enforced. The content is
# what must survive; the mode is corrected to 0640.
check_eq "existing log: mode corrected to 0640" "$(mode_of "$LOG")" 640

# ---- 5. a session that never appears ----------------------------------------
new_env missing
SESSION=ghost
run_script
if [ "$RC" -ne 0 ]; then pass "missing session: exits non-zero"; else fail "missing session: exits non-zero"; fi
check_contains "missing session: message names the session" "$OUT" "ghost"
if [ "$ELAPSED" -le 30 ]; then pass "missing session: bounded time (${ELAPSED}s)"; else fail "missing session: bounded time (${ELAPSED}s)"; fi
check_eq "missing session: no pipe-pane calls" "$(count_args '^pipe-pane ')" 0
check_eq "missing session: polled about 100 times" \
    "$(grep -c has-session "$STATE/invoked.log")" 100

# ---- 6. wedged tmux is bounded by the timeout binary ------------------------
new_env wedged
TIMEOUT_BIN=$T/bin/fast-timeout
FAKE_TMUX_SLEEP=30
export FAKE_TMUX_SLEEP
run_script
unset FAKE_TMUX_SLEEP
if [ "$RC" -ne 0 ]; then pass "wedged tmux: exits non-zero"; else fail "wedged tmux: exits non-zero"; fi
check_contains "wedged tmux: reports the list-panes failure" "$OUT" 'list-panes failed or timed out'
if [ "$ELAPSED" -le 10 ]; then pass "wedged tmux: bounded, did not hang (${ELAPSED}s)"; else fail "wedged tmux: bounded, did not hang (${ELAPSED}s)"; fi
check_eq "wedged tmux: no pipe-pane calls" "$(count_args '^pipe-pane ')" 0

# ---- 7. invalid input aborts before tmux is invoked -------------------------
no_tmux() {
    local name=$1
    if [ -s "$STATE/calls.log" ] || [ -s "$STATE/invoked.log" ]; then
        fail "$name: tmux was invoked"
    else
        pass "$name: tmux was never invoked"
    fi
}

new_env badsession
SESSION='work;touch /tmp/pwned'
run_script
if [ "$RC" -ne 0 ]; then pass "session with ';': exits non-zero"; else fail "session with ';': exits non-zero"; fi
no_tmux "session with ';'"
check_contains "session with ';': message says invalid" "$OUT" 'invalid session name'

loop_n=0
for bad in '$(id)' 'a b' '-x' '`id`' 'a
b'; do
    loop_n=$((loop_n + 1))
    new_env "badloop$loop_n"
    SESSION=$bad
    run_script
    if [ "$RC" -ne 0 ]; then pass "session <$bad>: exits non-zero"; else fail "session <$bad>: exits non-zero"; fi
    no_tmux "session <$bad>"
done

new_env badlog
LOG="$T/trans cript.log"
run_script
if [ "$RC" -ne 0 ]; then pass "log path with a space: exits non-zero"; else fail "log path with a space: exits non-zero"; fi
no_tmux "log path with a space"
check_contains "log path with a space: message says invalid" "$OUT" 'invalid log path'

new_env badlog2
LOG="$T/x;y.log"
run_script
if [ "$RC" -ne 0 ]; then pass "log path with ';': exits non-zero"; else fail "log path with ';': exits non-zero"; fi
no_tmux "log path with ';'"
if [ ! -e "$LOG" ]; then pass "log path with ';': nothing created"; else fail "log path with ';': nothing created"; fi

# ---- 8. lock contention ------------------------------------------------------
new_env locked
: >> "$LOCK"
chmod 0600 "$LOCK"
exec 8>>"$LOCK"
"$REAL_FLOCK" -x 8
run_script
exec 8>&-
if [ "$RC" -ne 0 ]; then pass "lock contention: exits non-zero"; else fail "lock contention: exits non-zero"; fi
check_contains "lock contention: says the watchdog will retry" "$OUT" 'watchdog will retry'
check_eq "lock contention: no pipe-pane calls" "$(count_args '^pipe-pane ')" 0

# ---- 9. an attach failure names the pane and the others still get tapped ----
new_env attachfail
WRAP_FAIL_PANE='%1'
export WRAP_FAIL_PANE
run_script
unset WRAP_FAIL_PANE
if [ "$RC" -ne 0 ]; then pass "attach failure: exits non-zero"; else fail "attach failure: exits non-zero"; fi
check_contains "attach failure: message names the pane" "$OUT" '%1'
check_eq "attach failure: pane %0 still tapped" "$(pipe_of '%0')" 1
check_eq "attach failure: pane %1 not tapped" "$(pipe_of '%1')" 0

# ---- 10. a hostile pane id is refused, not embedded -------------------------
new_env badpane
printf '%s\t%s\n' '%7;id' '0' >> "$STATE/state"
run_script
if [ "$RC" -ne 0 ]; then pass "hostile pane id: exits non-zero"; else fail "hostile pane id: exits non-zero"; fi
check_eq "hostile pane id: no pipe-pane call mentions it" "$(count_args '^pipe-pane .*;id')" 0
check_eq "hostile pane id: valid panes still tapped" "$(pipe_of '%0')$(pipe_of '%1')" 11
check_contains "hostile pane id: message names it" "$OUT" '%7'

# ---- 11. a transcript created here is readable by the reader group -----------
# The reader is in the runtime directory's group and nothing else, so a log this
# script creates must carry that group and be group-readable. It used to inherit
# the caller's group, which for the root deployment locked the reader out until
# the next activation rewrote the mode.
new_env logperm
run_script
check_eq "log creation: exits 0" "$RC" 0
check_eq "log creation: mode is 0640" "$(stat -c '%a' "$LOG")" 640
check_eq "log creation: group matches the runtime directory" \
    "$(stat -c '%G' "$LOG")" "$(stat -c '%G' "$T")"

# ---- 11b. a too-permissive transcript is tightened, not tolerated ------------
# 0644 would let every account on the host read the operator's terminal.
new_env logwide
( umask 022; : > "$LOG" )
run_script
check_eq "wide log: exits 0" "$RC" 0
check_eq "wide log: tightened to 0640" "$(stat -c '%a' "$LOG")" 640

# ---- 12. an owner-only transcript is repaired before the tap attaches -------
# A file the service account owns is fixable, so it is fixed rather than refused.
# What must not happen is attaching and leaving the reader with a file they
# cannot open.
new_env owneronly
( umask 077; : > "$LOG" )
run_script
check_eq "owner-only log: exits 0" "$RC" 0
check_eq "owner-only log: repaired to 0640" "$(stat -c '%a' "$LOG")" 640
check_eq "owner-only log: taps attached" "$(count_args '^pipe-pane ')" 2

# ---- summary ------------------------------------------------------------------
printf '\n%s passed, %s failed\n' "$PASSES" "$FAILS"
if [ "$FAILS" -eq 0 ]; then
    printf 'PASS: tap_start_test\n'
    exit 0
fi
printf 'FAIL: tap_start_test\n'
exit 1
