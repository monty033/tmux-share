#!/usr/bin/env bash
# Unit test for core/bin/tmux-share-trim against tests/stubs/fake-tmux.
# Everything happens in a mktemp directory that is removed on exit.
# Exit 0 only if every assertion passes.
#
# Failure injection that fake-tmux cannot do by itself is done by a thin
# wrapper (written below) that records an event sequence and delegates to the
# fake. Atomicity is asserted from that recorded sequence; see case "atomic".
set -eu

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/../.." && pwd)
TRIM=$repo_root/core/bin/tmux-share-trim
FAKE=$repo_root/tests/stubs/fake-tmux

base=${TMPDIR:-/tmp}
if [ "${#base}" -gt 30 ]; then base=/tmp; fi # the script caps paths at 64 chars
work=$(mktemp -d "$base/trim-test.XXXXXX")
export TMPDIR=$work
holder_pid=''

cleanup() {
  if [ -n "$holder_pid" ]; then kill "$holder_pid" 2>/dev/null || true; fi
  rm -rf -- "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

REAL_MV=$(command -v mv)
REAL_MKTEMP=$(command -v mktemp)
export REAL_MV REAL_MKTEMP

pass_count=0
fail_count=0
pass() { pass_count=$((pass_count + 1)); printf 'PASS: %s\n' "$1"; }
fail() { fail_count=$((fail_count + 1)); printf 'FAIL: %s\n' "$1"; }

# assert NAME COMMAND...: pass if the command succeeds.
assert() {
  local name=$1
  shift
  if "$@"; then pass "$name"; else fail "$name"; fi
}
not() { ! "$@"; }

# assert_and NAME CMD... -- CMD... -- CMD...: pass only if every command
# (separated by a literal --) succeeds. Never chain asserts with && instead:
# under set -e a failing tail of the chain would end the whole run.
assert_and() {
  local name=$1 ok=1
  shift
  local cmd=()
  while [ "$#" -gt 0 ]; do
    if [ "$1" = -- ]; then
      if [ "${#cmd[@]}" -gt 0 ] && ! "${cmd[@]}"; then ok=0; fi
      cmd=()
    else
      cmd+=("$1")
    fi
    shift
  done
  if [ "${#cmd[@]}" -gt 0 ] && ! "${cmd[@]}"; then ok=0; fi
  if [ "$ok" -eq 1 ]; then pass "$name"; else fail "$name"; fi
}

# ---- test doubles -----------------------------------------------------------
# tmux wrapper: records CLOSE/ATTACH events (with the transcript's inode and
# size at that instant) and can make one pane vanish on close or refuse a
# re-attach. Everything else goes to the fake.
cat >"$work/tmux-wrap" <<'WRAP'
#!/usr/bin/env bash
set -eu
sub=${1:-}
if [ "$sub" != pipe-pane ]; then exec "$WRAP_FAKE" "$@"; fi
shift
pane='' cmd='' has_cmd=0
while [ "$#" -gt 0 ]; do
  case $1 in
    -t) pane=$2; shift 2 ;;
    *) cmd=$1; has_cmd=1; shift ;;
  esac
done
if [ "$has_cmd" -eq 1 ]; then ev=ATTACH; else ev=CLOSE; fi
if [ -n "${WRAP_SEQ:-}" ]; then
  printf '%s %s ino=%s size=%s\n' "$ev" "$pane" \
    "$(stat -c %i "$TMUX_SHARE_LOG")" "$(stat -c %s "$TMUX_SHARE_LOG")" >>"$WRAP_SEQ"
fi
inject() { # RC MESSAGE: act like a failing tmux and leave a calls.log trace
  if [ "$has_cmd" -eq 1 ]; then
    printf '%s\tpipe-pane -t %s %s\t-\n' "$1" "$pane" "$cmd" >>"$FAKE_TMUX_STATE/calls.log"
  else
    printf '%s\tpipe-pane -t %s\t-\n' "$1" "$pane" >>"$FAKE_TMUX_STATE/calls.log"
  fi
  printf '%s\n' "$2" >&2
  exit "$1"
}
if [ "$ev" = CLOSE ] && [ "${WRAP_VANISH_PANE:-}" = "$pane" ]; then
  grep -v -F -- "$pane"$'\t' "$FAKE_TMUX_STATE/state" >"$FAKE_TMUX_STATE/state.new" || true
  cat -- "$FAKE_TMUX_STATE/state.new" >"$FAKE_TMUX_STATE/state"
  rm -f -- "$FAKE_TMUX_STATE/state.new"
  inject 1 "can't find pane: $pane"
fi
if [ "$ev" = ATTACH ] && [ "${WRAP_FAIL_ATTACH_PANE:-}" = "$pane" ]; then
  inject 1 "tmux: simulated attach failure"
fi
if [ "$has_cmd" -eq 1 ]; then exec "$WRAP_FAKE" pipe-pane -t "$pane" "$cmd"; fi
exec "$WRAP_FAKE" pipe-pane -t "$pane"
WRAP

# PATH shims, used only by the cases that put them first on PATH.
mkdir -p "$work/shim"
cat >"$work/shim/mv" <<'SHIM'
#!/usr/bin/env bash
# Records what exists just before and just after a rename onto the transcript.
src=${*: -2:1}
dst=${*: -1}
snap() { # FILE: inode, size, checksum
  printf 'ino=%s size=%s sum=%s' "$(stat -c %i "$1")" "$(stat -c %s "$1")" \
    "$(cksum <"$1" | tr ' ' :)"
}
if [ "$dst" = "${TMUX_SHARE_LOG:-}" ]; then
  printf 'MV-PRE src[%s] dst[%s]\n' "$(snap "$src")" "$(snap "$dst")" >>"$WRAP_SEQ"
  if [ -n "${SHIM_MV_FAIL:-}" ]; then echo 'mv: injected failure' >&2; exit 1; fi
fi
rc=0
"$REAL_MV" "$@" || rc=$?
if [ "$dst" = "${TMUX_SHARE_LOG:-}" ]; then
  printf 'MV-POST dst[%s]\n' "$(snap "$dst")" >>"$WRAP_SEQ"
fi
exit "$rc"
SHIM
cat >"$work/shim/mktemp" <<'SHIM'
#!/usr/bin/env bash
out=$("$REAL_MKTEMP" "$@") || exit
printf 'MKTEMP %s\n' "$out" >>"$WRAP_SEQ"
printf '%s\n' "$out"
SHIM
chmod +x "$work/tmux-wrap" "$work/shim/mv" "$work/shim/mktemp"

# ---- per-case setup -----------------------------------------------------------
C='' LOGDIR='' LOG=''
MAX=1000

new_case() { # NAME: fresh dir, three panes with taps, env for the trimmer
  local v
  for v in FAKE_TMUX_RC FAKE_TMUX_STDERR FAKE_TMUX_SLEEP WRAP_VANISH_PANE \
    WRAP_FAIL_ATTACH_PANE SHIM_MV_FAIL; do
    unset "$v"
  done
  C=$work/$1
  LOGDIR=$C/dir
  LOG=$LOGDIR/transcript.log
  mkdir -p "$C/state" "$LOGDIR"
  printf 'sess1\n' >"$C/state/sessions"
  printf '%s\t%s\n' '%0' 1 '%1' 1 '%2' 1 >"$C/state/state"
  printf '#!/bin/sh\nexit 0\n' >"$LOGDIR/stamp"
  chmod 755 "$LOGDIR/stamp"
  printf '1000 5.00\n' >"$C/uptime"
  export FAKE_TMUX_STATE=$C/state WRAP_FAKE=$FAKE WRAP_SEQ=$C/seq
  export TMUX_SHARE_DIR=$LOGDIR TMUX_SHARE_SESSION=sess1
  export TMUX_SHARE_SOCK=$LOGDIR/tmux.sock TMUX_SHARE_LOG=$LOG
  export TMUX_SHARE_LOCK=$LOGDIR/lock TMUX_SHARE_REBUILD=$LOGDIR/rebuild
  export TMUX_SHARE_NOTREADY_MARKER=$LOGDIR/notready TMUX_SHARE_NOTREADY_GRACE=300
  export TMUX_SHARE_UPTIME_FILE=$C/uptime
  export TMUX_SHARE_STAMP=$LOGDIR/stamp TMUX_SHARE_TMUX=$work/tmux-wrap
  export TMUX_SHARE_TIMEOUT=timeout TMUX_SHARE_MAX_BYTES=$MAX
  export TMUX_SHARE_CALL_SECS=5 TMUX_SHARE_LOCK_WAIT=2
  export TMUX_SHARE_LIBDIR=$repo_root/core/lib
}

# make_log SIZE: HEADMARK first, TAILMARK last, filler between; mode 0640.
make_log() {
  local size=$1 head='HEADMARK
' tail='
TAILMARK
'
  local fill=$((size - ${#head} - ${#tail}))
  {
    printf '%s' "$head"
    head -c "$fill" /dev/zero | tr '\0' 'x'
    printf '%s' "$tail"
  } >"$LOG"
  chmod 640 "$LOG"
  cp -- "$LOG" "$C/orig.copy"
}

RC=0
run_trim() { RC=0; "$TRIM" >"$C/out" 2>"$C/err" || RC=$?; }
run_trim_shim() { RC=0; PATH="$work/shim:$PATH" "$TRIM" >"$C/out" 2>"$C/err" || RC=$?; }

ino() { stat -c %i "$1"; }
size_of() { stat -c %s "$1"; }
mode_of() { stat -c %a "$1"; }
owner_of() { stat -c %u:%g "$1"; }
sum_of() { cksum <"$1" | tr ' ' :; }
calls() { if [ -f "$C/state/calls.log" ]; then cut -f2 "$C/state/calls.log"; fi; }
n_pipe_calls() { calls | grep -c '^pipe-pane ' || true; }
n_calls() { calls | grep -c . || true; }
has_call() { calls | grep -q -x -F -- "$1"; }
cmd_of() { cmd_text=$(grep -F -- "$1"$'\t' "$C/state/commands" | cut -f2 || true); printf '%s' "$cmd_text"; }
has_tmpfile() { compgen -G "$LOGDIR/transcript.log.*" >/dev/null; }
has_scratch() { compgen -G "$work/tmux-share-trim.*" >/dev/null; }
err_has() { grep -q -i -- "$1" "$C/err"; }
out_has() { grep -q -i -- "$1" "$C/out"; }
file_has() { grep -q -F -- "$1" "$2"; }
cmp_tail() { # does FILE equal the last MAX bytes of the saved original?
  tail -c "$MAX" -- "$C/orig.copy" | cmp -s - "$1"
}
close_line() { printf 'pipe-pane -t %s' "$1"; }
attach_line() { printf 'pipe-pane -t %s exec %s >> %s' "$1" "$TMUX_SHARE_STAMP" "$LOG"; }
line_no() { # PATTERN FILE: first matching line number (0 if none)
  local n
  n=$(grep -n -m1 -- "$1" "$2" | cut -d: -f1 || true)
  printf '%s' "${n:-0}"
}
last_line_no() { # PATTERN FILE
  local n
  n=$(grep -n -- "$1" "$2" | tail -n 1 | cut -d: -f1 || true)
  printf '%s' "${n:-0}"
}
nth() { if [ "$2" -gt 0 ]; then sed -n "$2p" "$1"; fi; } # FILE N: Nth line, if N > 0
field() { # LINE KEY: value of KEY=VALUE inside LINE (first match)
  if [[ $1 =~ (^|[[:space:]\[])$2=([^][[:space:]]*) ]]; then printf '%s' "${BASH_REMATCH[2]}"; fi
}

# ---- 1. under or at the bound: no tmux, no change -------------------------------
for size in 1000 400; do
  new_case "under$size"
  make_log "$size"
  ino0=$(ino "$LOG"); sum0=$(sum_of "$LOG")
  run_trim
  assert "under the bound ($size bytes): exits 0 (rc=$RC)" [ "$RC" -eq 0 ]
  assert "under the bound ($size bytes): no pipe-pane calls at all" [ "$(n_pipe_calls)" -eq 0 ]
  assert "under the bound ($size bytes): tmux was not contacted" [ "$(n_calls)" -eq 0 ]
  assert "under the bound ($size bytes): same inode" [ "$(ino "$LOG")" = "$ino0" ]
  assert "under the bound ($size bytes): same content" [ "$(sum_of "$LOG")" = "$sum0" ]
  assert "under the bound ($size bytes): no temp file left" not has_tmpfile
done

# ---- 2. over the bound: close all, trim, keep newest, re-attach all -----------------
new_case over
make_log 5000
ino0=$(ino "$LOG"); owner0=$(owner_of "$LOG")
run_trim
assert "over the bound: exits 0 (rc=$RC)" [ "$RC" -eq 0 ]
for p in '%0' '%1' '%2'; do
  assert "over the bound: tap of pane $p was closed" has_call "$(close_line "$p")"
  assert "over the bound: pane $p was re-attached with the stamp command" has_call "$(attach_line "$p")"
  assert "over the bound: pane $p is tapped at the end" [ "$(cmd_of "$p")" = "exec $TMUX_SHARE_STAMP >> $LOG" ]
done
assert "over the bound: file is at most the bound ($(size_of "$LOG") bytes)" [ "$(size_of "$LOG")" -le "$MAX" ]
assert "over the bound: kept the tail marker" file_has TAILMARK "$LOG"
assert "over the bound: dropped the head marker" not file_has HEADMARK "$LOG"
assert "over the bound: kept exactly the newest bytes" cmp_tail "$LOG"
assert "over the bound: mode preserved ($(mode_of "$LOG"))" [ "$(mode_of "$LOG")" = 640 ]
assert "over the bound: owner and group preserved" [ "$(owner_of "$LOG")" = "$owner0" ]
assert "over the bound: the file was replaced (new inode)" [ "$(ino "$LOG")" != "$ino0" ]
assert "over the bound: no temp file left" not has_tmpfile
assert "over the bound: no scratch directory left" not has_scratch
assert "over the bound: no rebuild marker after a clean run" not test -e "$TMUX_SHARE_REBUILD"
calls >"$C/args"
last_close=$(last_line_no '^pipe-pane -t %[0-9]$' "$C/args")
first_attach=$(line_no ' exec ' "$C/args")
assert_and "over the bound: all closes precede all re-attaches" [ "$last_close" -gt 0 ] -- [ "$last_close" -lt "$first_attach" ]
assert "over the bound: every tap was down after the last close" \
  grep -q -F '%0=0,%1=0,%2=0' <(nth "$C/state/calls.log" "$last_close" | cut -f3)

# ---- 3. a pane vanishes between enumeration and close -----------------------------
new_case vanish
make_log 5000
export WRAP_VANISH_PANE='%1'
run_trim
assert "vanished pane: trim still exits 0 (rc=$RC)" [ "$RC" -eq 0 ]
assert "vanished pane: the close of the missing pane was attempted" has_call "$(close_line '%1')"
assert_and "vanished pane: file trimmed to the bound" [ "$(size_of "$LOG")" -le "$MAX" ] -- cmp_tail "$LOG"
assert "vanished pane: surviving pane %0 re-attached" has_call "$(attach_line '%0')"
assert "vanished pane: surviving pane %2 re-attached" has_call "$(attach_line '%2')"
assert "vanished pane: no re-attach attempted on the vanished pane" not has_call "$(attach_line '%1')"
assert "vanished pane: no rebuild marker" not test -e "$TMUX_SHARE_REBUILD"

# ---- 4. a re-attach failure is loud and non-zero -----------------------------------
new_case attachfail
make_log 5000
export WRAP_FAIL_ATTACH_PANE='%1'
run_trim
assert "re-attach failure: exits non-zero (rc=$RC)" [ "$RC" -ne 0 ]
assert "re-attach failure: says recording stopped" err_has 'recording stopped'
assert "re-attach failure: names the pane" err_has '%1'
assert "re-attach failure: EXIT trap tried pane %1 (calls.log)" has_call "$(attach_line '%1')"
assert "re-attach failure: trap still re-attached pane %0" has_call "$(attach_line '%0')"
assert "re-attach failure: trap still re-attached pane %2" has_call "$(attach_line '%2')"
assert "re-attach failure: rebuild marker names the lost pane" file_has '%1' "$TMUX_SHARE_REBUILD"
assert "re-attach failure: marker does not list healthy panes" not file_has '%0' "$TMUX_SHARE_REBUILD"

# ---- 5. a failure mid-trim still re-attaches via the trap ---------------------------
new_case midfail
make_log 5000
ino0=$(ino "$LOG"); sum0=$(sum_of "$LOG")
export SHIM_MV_FAIL=1
run_trim_shim
assert "failed rename: exits non-zero (rc=$RC)" [ "$RC" -ne 0 ]
assert "failed rename: transcript untouched (inode)" [ "$(ino "$LOG")" = "$ino0" ]
assert "failed rename: transcript untouched (content)" [ "$(sum_of "$LOG")" = "$sum0" ]
assert "failed rename: temp file removed" not has_tmpfile
for p in '%0' '%1' '%2'; do
  assert "failed rename: trap re-attached pane $p" has_call "$(attach_line "$p")"
done
assert "failed rename: no recording-stopped claim, taps were restored" not err_has 'recording stopped'

# ---- 6. not-ready handling ---------------------------------------------------------
new_case notready
make_log 5000
ino0=$(ino "$LOG"); sum0=$(sum_of "$LOG")
: >"$C/state/sessions" # "can't find session": server up but session absent
printf '1000 5.00\n' >"$C/uptime"
run_trim
assert "not-ready, first sight: excused (rc=$RC)" [ "$RC" -eq 0 ]
assert "not-ready, first sight: marker stamped" [ "$(cat -- "$TMUX_SHARE_NOTREADY_MARKER")" = 1000 ]
printf '1100 5.00\n' >"$C/uptime"
run_trim
assert "not-ready, inside grace (100s): excused (rc=$RC)" [ "$RC" -eq 0 ]
printf '1299 5.00\n' >"$C/uptime"
run_trim
assert "not-ready, 299s: still excused (rc=$RC)" [ "$RC" -eq 0 ]
printf '1400 5.00\n' >"$C/uptime"
run_trim
assert "not-ready, beyond grace: fails (rc=$RC)" [ "$RC" -ne 0 ]
assert "not-ready, beyond grace: names the duration" err_has '400s'
assert "not-ready: no tap was ever closed" [ "$(n_pipe_calls)" -eq 0 ]
assert_and "not-ready: transcript untouched" [ "$(ino "$LOG")" = "$ino0" ] -- [ "$(sum_of "$LOG")" = "$sum0" ]
printf 'sess1\n' >"$C/state/sessions"
run_trim
assert_and "recovery: a successful pass trims (rc=$RC)" [ "$RC" -eq 0 ] -- [ "$(size_of "$LOG")" -le "$MAX" ]
assert "recovery: a successful pass clears the marker" not test -e "$TMUX_SHARE_NOTREADY_MARKER"

new_case noserver
make_log 5000
export FAKE_TMUX_RC=1 FAKE_TMUX_STDERR='no server running on the socket'
run_trim
assert "no server running: first sight excused (rc=$RC)" [ "$RC" -eq 0 ]
assert "no server running: marker stamped" test -e "$TMUX_SHARE_NOTREADY_MARKER"

new_case refusal
make_log 5000
ino0=$(ino "$LOG")
export FAKE_TMUX_RC=1 FAKE_TMUX_STDERR='error connecting to the socket (Permission denied)'
run_trim
assert "refusal: fails at once (rc=$RC)" [ "$RC" -ne 0 ]
assert "refusal: no not-ready marker written" not test -e "$TMUX_SHARE_NOTREADY_MARKER"
assert "refusal: nothing closed" [ "$(n_pipe_calls)" -eq 0 ]
assert "refusal: transcript untouched" [ "$(ino "$LOG")" = "$ino0" ]
assert "refusal: reported as a failure, not as not-ready" err_has 'failed'

new_case wedge
make_log 5000
export FAKE_TMUX_SLEEP=5 TMUX_SHARE_CALL_SECS=1
run_trim
assert "wedged tmux: fails at once (rc=$RC)" [ "$RC" -ne 0 ]
assert "wedged tmux: says it timed out" err_has 'timed out'
assert "wedged tmux: no not-ready marker written" not test -e "$TMUX_SHARE_NOTREADY_MARKER"
assert "wedged tmux: nothing closed" [ "$(n_pipe_calls)" -eq 0 ]

# ---- 7. lock contention --------------------------------------------------------------
new_case lock
make_log 5000
ino0=$(ino "$LOG"); sum0=$(sum_of "$LOG")
(
  exec 8>>"$TMUX_SHARE_LOCK"
  flock -x 8
  : >"$C/held"
  exec sleep 60
) &
holder_pid=$!
tries=0
while [ ! -e "$C/held" ] && [ "$tries" -lt 50 ]; do sleep 0.1; tries=$((tries + 1)); done
assert "lock: the holder has the lock" [ -e "$C/held" ]
run_trim
assert "lock busy: exits non-zero (rc=$RC)" [ "$RC" -ne 0 ]
assert "lock busy: says the next pass will retry" err_has 'retry'
assert "lock busy: tmux was not contacted" [ "$(n_calls)" -eq 0 ]
assert_and "lock busy: transcript untouched" [ "$(ino "$LOG")" = "$ino0" ] -- [ "$(sum_of "$LOG")" = "$sum0" ]
kill "$holder_pid" 2>/dev/null || true
wait "$holder_pid" 2>/dev/null || true
holder_pid=''
run_trim
assert_and "lock released: the next pass trims (rc=$RC)" [ "$RC" -eq 0 ] -- [ "$(size_of "$LOG")" -le "$MAX" ]

# ---- 8. invalid settings abort before tmux is touched ------------------------------
for bad in 0 -5 abc 1.5 '' 007; do
  new_case badmax
  make_log 5000
  export TMUX_SHARE_MAX_BYTES=$bad
  run_trim
  assert "max bytes '$bad': rejected (rc=$RC)" [ "$RC" -ne 0 ]
  assert "max bytes '$bad': tmux not contacted" [ "$(n_calls)" -eq 0 ]
done
new_case badsess
make_log 5000
export TMUX_SHARE_SESSION='x;touch pwned'
run_trim
assert "bad session name: rejected (rc=$RC)" [ "$RC" -ne 0 ]
assert "bad session name: tmux not contacted" [ "$(n_calls)" -eq 0 ]
new_case badlog
make_log 5000
export TMUX_SHARE_LOG="$LOGDIR/a b.log"
run_trim
assert "bad log path: rejected (rc=$RC)" [ "$RC" -ne 0 ]
assert "bad log path: tmux not contacted" [ "$(n_calls)" -eq 0 ]

# ---- 9. atomic replacement, from the recorded event sequence -----------------------
# The wrapper and the PATH shims append one line per event to $C/seq:
#   CLOSE/ATTACH pane ino= size=   transcript state when tmux was called
#   MKTEMP path                    every mktemp the script runs
#   MV-PRE src[..] dst[..]         just before the rename onto the transcript
#   MV-POST dst[..]                just after it
new_case atomic
make_log 5000
orig_ino=$(ino "$LOG"); orig_size=$(size_of "$LOG"); orig_sum=$(sum_of "$LOG")
exp_sum=$(tail -c "$MAX" -- "$C/orig.copy" | cksum | tr ' ' :)
run_trim_shim
seq=$C/seq
assert "atomic: trim succeeded (rc=$RC)" [ "$RC" -eq 0 ]
i_last_close=$(last_line_no '^CLOSE ' "$seq")
i_mktemp=$(line_no "^MKTEMP $LOGDIR/transcript.log\\." "$seq")
i_pre=$(line_no '^MV-PRE ' "$seq")
i_post=$(line_no '^MV-POST ' "$seq")
i_first_attach=$(line_no '^ATTACH ' "$seq")
assert_and "atomic: every event was recorded" [ "$i_last_close" -gt 0 ] -- [ "$i_mktemp" -gt 0 ] \
  -- [ "$i_pre" -gt 0 ] -- [ "$i_post" -gt 0 ] -- [ "$i_first_attach" -gt 0 ]
assert_and "atomic: sequence is close, mktemp, rename, re-attach" \
  [ "$i_last_close" -lt "$i_mktemp" ] -- [ "$i_mktemp" -lt "$i_pre" ] \
  -- [ "$i_pre" -lt "$i_post" ] -- [ "$i_post" -lt "$i_first_attach" ]
tmp_path=$(nth "$seq" "$i_mktemp" | cut -d' ' -f2)
assert "atomic: temp file was created in the transcript's own directory" [ "$(dirname -- "$tmp_path")" = "$LOGDIR" ]
pre=$(nth "$seq" "$i_pre")
post=$(nth "$seq" "$i_post")
pre_src=${pre#*src\[}; pre_src=${pre_src%%\]*}
pre_dst=${pre#*dst\[}; pre_dst=${pre_dst%%\]*}
post_dst=${post#*dst\[}; post_dst=${post_dst%%\]*}
assert "atomic: before the rename the temp file was already complete (size)" [ "$(field "$pre_src" size)" = "$MAX" ]
assert "atomic: before the rename the temp file was already complete (content)" [ "$(field "$pre_src" sum)" = "$exp_sum" ]
assert "atomic: before the rename the original name still had the old inode" [ "$(field "$pre_dst" ino)" = "$orig_ino" ]
assert_and "atomic: before the rename the original name still had the full old content" \
  [ "$(field "$pre_dst" size)" = "$orig_size" ] -- [ "$(field "$pre_dst" sum)" = "$orig_sum" ]
assert_and "atomic: after the rename the original name is the complete temp inode" \
  [ "$(field "$post_dst" ino)" = "$(field "$pre_src" ino)" ] -- [ "$(field "$post_dst" ino)" != "$orig_ino" ]
assert_and "atomic: after the rename the original name has the full new content" \
  [ "$(field "$post_dst" size)" = "$MAX" ] -- [ "$(field "$post_dst" sum)" = "$exp_sum" ]
closes_ok=1
while IFS= read -r line; do
  if [ "$(field "$line" ino)" != "$orig_ino" ] || [ "$(field "$line" size)" != "$orig_size" ]; then closes_ok=0; fi
done < <(grep '^CLOSE ' "$seq")
assert "atomic: the original was untouched while taps were being closed" [ "$closes_ok" -eq 1 ]
attach_ok=1
while IFS= read -r line; do
  if [ "$(field "$line" ino)" != "$(field "$post_dst" ino)" ] || [ "$(field "$line" size)" != "$MAX" ]; then attach_ok=0; fi
done < <(grep '^ATTACH ' "$seq")
assert "atomic: every re-attach saw the finished replacement, never a partial file" [ "$attach_ok" -eq 1 ]
assert "atomic: the number of mv calls onto the transcript is exactly one" [ "$(grep -c '^MV-PRE ' "$seq")" -eq 1 ]

# ---- summary ------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass_count" "$fail_count"
if [ "$fail_count" -ne 0 ]; then
  printf 'FAIL\n'
  exit 1
fi
printf 'PASS\n'
