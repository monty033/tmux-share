#!/usr/bin/env bash
# Unit test for core/bin/tmux-share-watchdog against tests/stubs/fake-tmux.
# Everything lives in a temp dir that is removed on exit.
# Exit 0 only if every case passes.
set -u   # not -e: a failed assertion must be reported, not abort

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/../.." && pwd)
WATCHDOG=$repo_root/core/bin/tmux-share-watchdog
FAKE=$repo_root/tests/stubs/fake-tmux

work=$(mktemp -d "${TMPDIR:-/tmp}/wd-test.XXXXXX")
holder_pid=''
cleanup() {
  if [ -n "$holder_pid" ]; then kill "$holder_pid" 2>/dev/null || true; fi
  rm -rf -- "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

pass_count=0
fail_count=0
pass() { pass_count=$((pass_count + 1)); printf 'PASS: %s\n' "$1"; }
fail() { fail_count=$((fail_count + 1)); printf 'FAIL: %s\n' "$1"; }
check() { # check NAME CONDITION-RESULT(0 = true)
  if [ "$2" -eq 0 ]; then pass "$1"; else fail "$1"; fi
}

# ---- fixtures ---------------------------------------------------------------
STATE=$work/state
mkdir -p "$STATE"
LOG=$work/transcript.log
STAMP=$work/stamp
# The watchdog asks /proc whether a filter for this stamp path is alive, because
# #{pane_pipe} can stay 1 after the command has died. The tests point it at a
# fixture: entry 4242 present = alive, absent = the stale case.
PROC=$work/proc
mkdir -p "$PROC"
export TMUX_SHARE_PROC_ROOT=$PROC
stamp_alive() { mkdir -p "$PROC/4242"; printf '%s\0' "$STAMP" > "$PROC/4242/cmdline"; }
stamp_dead() { rm -rf "$PROC/4242"; }
REBUILD=$work/rebuild
NRMARK=$work/notready
UPTIME=$work/uptime
LOCKF=$work/lock
SEEN=$work/seen            # what the tmux wrapper observed
BOUNDS=$work/bounds        # first argument of every timeout invocation
errout=$work/stderr
printf '#!/bin/sh\nexit 0\n' > "$STAMP"; chmod 755 "$STAMP"

# fake-tmux does not understand the global -S option, so the wrapper drops it.
# It also records whether the rebuild marker existed at each pipe-pane, can
# make only re-attaches fail, and creates the log when an attach succeeds the
# way the real `>> LOG` redirection would.
cat > "$work/tmux" <<'EOF'
#!/usr/bin/env bash
set -u   # not -e: a failed assertion must be reported, not abort
if [ "${1:-}" = -S ]; then shift 2; fi
sub=${1:-}
if [ "$sub" = pipe-pane ]; then
  marker=absent; [ ! -e "$WD_REBUILD" ] || marker=present
  printf '%s marker=%s args=%s\n' "$sub" "$marker" "$*" >> "$WD_SEEN"

  if [ "${WD_FAIL_ATTACH:-}" = 1 ] && [ "$#" -ge 4 ]; then
    echo 'pipe-pane: simulated attach failure' >&2
    exit 1
  fi
fi
if [ -n "${FAKE_TMUX_SLEEP:-}" ]; then exec "$WD_FAKE" "$@"; fi
rc=0
"$WD_FAKE" "$@" || rc=$?
if [ "$sub" = pipe-pane ] && [ "$rc" -eq 0 ] && [ "$#" -gt 3 ]; then
  : >> "$WD_LOG"
fi
exit "$rc"
EOF
chmod 755 "$work/tmux"

# Bound wrapper: records the bound the watchdog asked for, then shortens it so
# the wedge test does not sit through the real five seconds.
cat > "$work/timeout" <<'EOF'
#!/bin/sh
printf '%s\n' "$1" >> "$WD_BOUNDS"
shift
exec timeout "${WD_SHORT_BOUND:-1}" "$@"
EOF
chmod 755 "$work/timeout"

export PATH="$PATH:/run/current-system/sw/bin"
export FAKE_TMUX_STATE=$STATE
export WD_REBUILD=$REBUILD WD_SEEN=$SEEN WD_FAKE=$FAKE WD_LOG=$LOG WD_BOUNDS=$BOUNDS
export TMUX_SHARE_DIR=$work
export TMUX_SHARE_SESSION=tmux-hermes
export TMUX_SHARE_SOCK=$work/tmux.sock
export TMUX_SHARE_LOG=$LOG
export TMUX_SHARE_LOCK=$LOCKF
export TMUX_SHARE_NOTREADY_MARKER=$NRMARK
export TMUX_SHARE_NOTREADY_GRACE=300
export TMUX_SHARE_UPTIME_FILE=$UPTIME
export TMUX_SHARE_REBUILD=$REBUILD
export TMUX_SHARE_STAMP=$STAMP
export TMUX_SHARE_TMUX=$work/tmux
export TMUX_SHARE_TIMEOUT=$work/timeout
export TMUX_SHARE_LOCK_WAIT=1
export TMPDIR=$work

set_clock() { printf '%s 1.00\n' "$1" > "$UPTIME"; }

reset() { # reset PANE_TABLE_LINES...  (each "%N<TAB>PIPE")
  unset FAKE_TMUX_RC FAKE_TMUX_STDERR FAKE_TMUX_SLEEP WD_FAIL_ATTACH
  : > "$STATE/state"; : > "$STATE/commands"; : > "$STATE/calls.log"
  printf '%s\n' tmux-hermes > "$STATE/sessions"
  local l
  for l in "$@"; do printf '%s\n' "$l" >> "$STATE/state"; done
  : > "$SEEN"; : > "$BOUNDS"; : > "$errout"
  rm -f -- "$REBUILD" "$NRMARK" "$LOG"
  : > "$LOG"
  set_clock 1000
}

# run_pass: run the watchdog, set RC and capture stderr.
run_pass() {
  RC=0
  "$WATCHDOG" 2> "$errout" || RC=$?
}

attach_count() { # attach_count PANE: pipe-pane calls that carry a command
  local n=0 l
  while IFS= read -r l; do
    case $l in "pipe-pane "*"-t $1 "*"exec "*) n=$((n + 1)) ;; esac
  done < "$SEEN"
  printf '%s' "$n"
}
pipe_of() { awk -F'\t' -v p="$1" '$1 == p { print $2 }' "$STATE/state"; }
has() { grep -q -- "$2" "$1"; }
tab=$'\t'

# ---- 1. a pane with no pipe gets one tap -----------------------------------
reset "%0${tab}0"
run_pass
check "no-pipe pane: pass exits 0" "$RC"
[ "$(pipe_of %0)" = 1 ]; check "no-pipe pane: pipe is now attached" "$?"
[ "$(attach_count %0)" = 1 ]; check "no-pipe pane: exactly one attach" "$?"
cmd=$(awk -F'\t' '$1 == "%0" { print $2 }' "$STATE/commands")
case $cmd in *"$STAMP"*) r=0 ;; *) r=1 ;; esac
check "no-pipe pane: recorded command mentions the stamp" "$r"
case $cmd in *">> $LOG"*) r=0 ;; *) r=1 ;; esac
check "no-pipe pane: recorded command mentions the log" "$r"

# ---- 2. a pane with a pipe is left alone; -o is never passed ---------------
stamp_alive
reset "%0${tab}1" "%1${tab}0"
run_pass
check "existing pipe: pass exits 0" "$RC"
[ "$(attach_count %0)" = 0 ]; check "existing pipe: pane with a tap left alone" "$?"
[ "$(attach_count %1)" = 1 ]; check "existing pipe: the bare pane still attached" "$?"
! has "$STATE/calls.log" ' -o ' && ! has "$SEEN" ' -o '
check "no -o is ever passed to pipe-pane" "$?"

# ---- 2b. a pipe flag with no live filter is repaired, not trusted -----------
# #{pane_pipe} only says a command was started. If that command died -- the
# interpreter was missing, for instance -- the flag can stay set while the
# transcript gets nothing, and skipping on the flag blinds the tap indefinitely.
stamp_dead
reset "%0${tab}1"
run_pass
check "dead filter: pass exits 0" "$RC"
[ "$(attach_count %0)" = 1 ]
check "dead filter: the pane is attached again" "$?"
grep -q 'no filter is running' "$errout"
check "dead filter: the watchdog says so" "$?"
has "$SEEN" 'pipe-pane -t %0'
check "dead filter: the stale pipe is retired first" "$?"
[ "$(pipe_of %0)" = 1 ]
check "dead filter: the pane ends up tapped" "$?"

# ---- 3. repeat passes are stable -------------------------------------------
stamp_alive
reset "%0${tab}0" "%1${tab}0"
run_pass; run_pass; run_pass
check "three passes: last exits 0" "$RC"
[ "$(attach_count %0)" = 1 ] && [ "$(attach_count %1)" = 1 ]
check "three passes: still exactly one attach per pane" "$?"
[ "$(pipe_of %0)$(pipe_of %1)" = 11 ]; check "three passes: both panes still tapped" "$?"
! has "$SEEN" ' -o '; check "three passes: no -o" "$?"

# ---- 4. deleted log + live pipe: retire and re-attach ----------------------
stamp_alive
reset "%0${tab}1" "%1${tab}1"
rm -f -- "$LOG"
run_pass
check "deleted log: pass exits 0" "$RC"
[ "$(attach_count %0)" = 1 ] && [ "$(attach_count %1)" = 1 ]
check "deleted log: every pane re-attached once" "$?"
# The retire is a pipe-pane with no command, issued while the marker existed.
grep -q '^pipe-pane marker=present args=pipe-pane -t %0$' "$SEEN"
check "deleted log: live pipe retired (marker written before it)" "$?"
grep -q 'marker=present args=pipe-pane -t %0 exec ' "$SEEN"
check "deleted log: re-attach happened while the marker existed" "$?"
[ ! -e "$REBUILD" ]; check "deleted log: rebuild marker cleared after success" "$?"
[ -e "$LOG" ]; check "deleted log: log file recreated by the attach" "$?"
# Recreated here, not by the attach redirection: that would leave the caller's
# group and umask on a file whose whole contract is "the reader group can read it,
# and nobody else can".
[ "$(stat -c %a "$LOG")" = 640 ]
check "deleted log: recreated with mode 0640" "$?"
[ "$(stat -c %G "$LOG")" = "$(stat -c %G "$TMUX_SHARE_DIR")" ]
check "deleted log: recreated in the runtime directory's group" "$?"
run_pass
check "deleted log: following pass exits 0" "$RC"
[ "$(attach_count %0)" = 1 ]; check "deleted log: following pass attaches nothing more" "$?"

# ---- 5. failed re-attach keeps the marker, exits non-zero ------------------
reset "%0${tab}1"
rm -f -- "$LOG"
export WD_FAIL_ATTACH=1
run_pass
[ "$RC" -ne 0 ]; check "failed re-attach: pass exits non-zero" "$?"
[ -e "$REBUILD" ]; check "failed re-attach: rebuild marker left in place" "$?"
has "$errout" 'attach failed for pane %0'; check "failed re-attach: failure is logged" "$?"
[ "$(pipe_of %0)" = 0 ]; check "failed re-attach: pane was retired (no stale pipe)" "$?"
unset WD_FAIL_ATTACH
run_pass
check "failed re-attach: next pass retries and exits 0" "$RC"
[ ! -e "$REBUILD" ]; check "failed re-attach: marker cleared once it recovered" "$?"
[ "$(pipe_of %0)" = 1 ]; check "failed re-attach: pane tapped after retry" "$?"

# plain attach failure with the log present is not green either
reset "%0${tab}0"
export WD_FAIL_ATTACH=1
run_pass
[ "$RC" -ne 0 ]; check "failed attach: a pass that repaired nothing is not green" "$?"
unset WD_FAIL_ATTACH

# ---- 6. server not ready: bounded grace ------------------------------------
reset "%0${tab}0"
: > "$STATE/sessions"                   # session unknown => "can't find session"
set_clock 1000
run_pass
check "not ready: first pass exits 0" "$RC"
[ -f "$NRMARK" ] && [ "$(cat "$NRMARK")" = 1000 ]
check "not ready: first pass records the not-ready marker" "$?"
set_clock 1005
run_pass
check "not ready: immediately following pass also exits 0" "$RC"
set_clock 1400
run_pass
[ "$RC" -ne 0 ]; check "not ready: pass after the grace window exits non-zero" "$?"
has "$errout" 'not ready for 400s'
check "not ready: failure names the duration" "$?"
# Recovery clears the marker.
printf '%s\n' tmux-hermes > "$STATE/sessions"
run_pass
check "not ready: pass after recovery exits 0" "$RC"
[ ! -e "$NRMARK" ]; check "not ready: successful enumeration clears the marker" "$?"

# "no server running" and a missing socket are recognised the same way.
reset "%0${tab}0"
export FAKE_TMUX_RC=1 FAKE_TMUX_STDERR='no server running on /x/tmux.sock'
run_pass
check "not ready: 'no server running' is excused" "$RC"
[ -e "$NRMARK" ]; check "not ready: 'no server running' writes the marker" "$?"
reset "%0${tab}0"
export FAKE_TMUX_RC=1 FAKE_TMUX_STDERR='error connecting to /x/tmux.sock (No such file or directory)'
run_pass
check "not ready: missing socket is excused" "$RC"

# ---- 7. a refusal is not "not ready" ---------------------------------------
reset "%0${tab}0"
export FAKE_TMUX_RC=1 FAKE_TMUX_STDERR='error connecting to /x/tmux.sock (Permission denied)'
run_pass
[ "$RC" -ne 0 ]; check "permission error: fails on the very first pass" "$?"
[ ! -e "$NRMARK" ]; check "permission error: no not-ready marker written" "$?"
has "$errout" 'Permission denied'; check "permission error: message carries the tmux error" "$?"
# A refusal mixed with a not-ready line must still fail.
reset "%0${tab}0"
export FAKE_TMUX_RC=1 FAKE_TMUX_STDERR='Permission denied'
: > "$STATE/sessions"
run_pass
[ "$RC" -ne 0 ] && [ ! -e "$NRMARK" ]
check "permission error beside a not-ready line: still fails, no marker" "$?"
# Even with the grace window open, an established refusal is never excused.
reset "%0${tab}0"
set_clock 1000; printf '%s\n' 1000 > "$NRMARK"
export FAKE_TMUX_RC=1 FAKE_TMUX_STDERR='error connecting to /x (Permission denied)'
run_pass
[ "$RC" -ne 0 ]; check "permission error inside an open grace window: fails" "$?"

# ---- 8. a wedged tmux is bounded -------------------------------------------
reset "%0${tab}0"
export FAKE_TMUX_SLEEP=30
start=$SECONDS
run_pass
elapsed=$((SECONDS - start))
[ "$RC" -ne 0 ]; check "wedged tmux: pass fails" "$?"
[ "$elapsed" -lt 10 ]; check "wedged tmux: pass returned in ${elapsed}s, did not hang" "$?"
[ ! -e "$NRMARK" ]; check "wedged tmux: not treated as not-ready" "$?"
[ -s "$BOUNDS" ] && ! grep -qv '^5$' "$BOUNDS"
check "every tmux call was bounded with timeout 5" "$?"
unset FAKE_TMUX_SLEEP

# ---- 9. lock contention ----------------------------------------------------
reset "%0${tab}0"
( exec 8>>"$LOCKF"; flock -x 8; exec sleep 30 ) & holder_pid=$!
sleep 0.5
run_pass
[ "$RC" -ne 0 ]; check "lock busy: pass exits non-zero" "$?"
has "$errout" 'next pass will retry'; check "lock busy: message says the next pass will retry" "$?"
[ "$(attach_count %0)" = 0 ] && [ ! -s "$STATE/calls.log" ]
check "lock busy: tmux was never touched" "$?"
kill "$holder_pid" 2>/dev/null || true; wait "$holder_pid" 2>/dev/null || true
holder_pid=''
run_pass
check "lock free again: pass exits 0" "$RC"
rm -f -- "$LOCKF"; run_pass
[ "$(stat -c '%a' "$LOCKF")" = 600 ]; check "lock file is created 0600" "$?"

# ---- 10. validation happens before tmux ------------------------------------
reset "%0${tab}0"
TMUX_SHARE_SESSION='x;touch /tmp/pwned' run_pass
[ "$RC" -ne 0 ] && [ ! -s "$STATE/calls.log" ]
check "bad session name: aborts before touching tmux" "$?"
TMUX_SHARE_LOG='/tmp/a b' run_pass
[ "$RC" -ne 0 ] && [ ! -s "$STATE/calls.log" ]
check "bad log path: aborts before touching tmux" "$?"
TMUX_SHARE_LOG='/tmp/../etc/x' run_pass
[ "$RC" -ne 0 ] && [ ! -s "$STATE/calls.log" ]
check "log path with '..': aborts before touching tmux" "$?"

# ---- summary ---------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass_count" "$fail_count"
if [ "$fail_count" -eq 0 ]; then
  printf 'PASS: watchdog_test\n'
  exit 0
fi
printf 'FAIL: watchdog_test\n'
exit 1
