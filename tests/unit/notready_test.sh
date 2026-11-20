#!/usr/bin/env bash
# Unit test for core/lib/notready.sh using an injected uptime file.
# Exit 0 only if every case passes.
set -eu

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/../.." && pwd)

work=$(mktemp -d "${TMPDIR:-/tmp}/notready-test.XXXXXX")
locked_dir=''

cleanup() {
  # Restore any chmod first so the removal cannot fail.
  if [ -n "$locked_dir" ] && [ -d "$locked_dir" ]; then
    chmod 0700 -- "$locked_dir" 2>/dev/null || true
  fi
  rm -rf -- "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# shellcheck source=../../core/lib/notready.sh
. "$repo_root/core/lib/notready.sh"

export TMUX_SHARE_UPTIME_FILE=$work/uptime
export TMUX_SHARE_NOTREADY_MARKER=$work/marker
export TMUX_SHARE_NOTREADY_GRACE=300

pass_count=0
fail_count=0
skip_count=0

pass() { pass_count=$((pass_count + 1)); printf 'PASS: %s\n' "$1"; }
fail() { fail_count=$((fail_count + 1)); printf 'FAIL: %s\n' "$1"; }
skip() { skip_count=$((skip_count + 1)); printf 'SKIP: %s\n' "$1"; }

set_clock() { printf '%s 12345.67\n' "$1" > "$TMUX_SHARE_UPTIME_FILE"; }
marker_text() { cat -- "$TMUX_SHARE_NOTREADY_MARKER"; }
reset_marker() { rm -f -- "$TMUX_SHARE_NOTREADY_MARKER"; }

# expect_rc NAME EXPECTED_RC: run notready_check and compare its status.
expect_rc() {
  local name=$1 want=$2 rc=0
  notready_check 2>/dev/null || rc=$?
  if [ "$rc" -eq "$want" ]; then
    pass "$name (rc=$rc)"
  else
    fail "$name (rc=$rc, wanted $want)"
  fi
}

expect_marker() {
  local name=$1 want=$2 got=''
  got=$(marker_text 2>/dev/null || true)
  if [ "$got" = "$want" ]; then
    pass "$name (marker=$got)"
  else
    fail "$name (marker='$got', wanted '$want')"
  fi
}

# ---- grace window ----------------------------------------------------------
reset_marker
set_clock 1000
expect_rc 'first not-ready call is excused' 0
expect_marker 'first not-ready call writes the marker' 1000

set_clock 1010
expect_rc 'call 10 s later is still excused' 0
expect_marker 'marker keeps the first-seen time at +10 s' 1000

set_clock 1299
expect_rc 'call at 299 s is still excused' 0

set_clock 1300
expect_rc 'call at 300 s fails' 1

set_clock 1301
expect_rc 'call at 301 s fails' 1
expect_marker 'expired marker is not refreshed' 1000

# ---- untrusted marker content ---------------------------------------------
set_clock 5000
restamp_case() {
  local name=$1
  expect_rc "$name: pass excused once" 0
  expect_marker "$name: marker re-stamped" 5000
}

printf 'not a number\n' > "$TMUX_SHARE_NOTREADY_MARKER"
restamp_case 'garbage text'

: > "$TMUX_SHARE_NOTREADY_MARKER"
restamp_case 'empty file'

printf '12345678901\n' > "$TMUX_SHARE_NOTREADY_MARKER"
restamp_case '11-digit value'

printf '5100\n' > "$TMUX_SHARE_NOTREADY_MARKER"
restamp_case 'value 100 s in the future'

printf '4990\ngarbage\n' > "$TMUX_SHARE_NOTREADY_MARKER"
restamp_case 'multi-line value'

# A re-stamped marker then ages normally and does not excuse forever.
set_clock 5300
expect_rc 're-stamped marker expires after the grace' 1

# ---- unwritable marker -----------------------------------------------------
set_clock 7000
if [ "$(id -u)" -eq 0 ]; then
  skip 'unwritable directory via chmod 500 (running as root, mode bits are not enforced)'
else
  locked_dir=$work/locked
  mkdir -- "$locked_dir"
  saved_marker=$TMUX_SHARE_NOTREADY_MARKER
  TMUX_SHARE_NOTREADY_MARKER=$locked_dir/marker
  chmod 0500 -- "$locked_dir"
  expect_rc 'unwritable marker directory (chmod 500) fails the pass' 1
  chmod 0700 -- "$locked_dir"
  TMUX_SHARE_NOTREADY_MARKER=$saved_marker
fi

saved_marker=$TMUX_SHARE_NOTREADY_MARKER
TMUX_SHARE_NOTREADY_MARKER=$work/missing-dir/marker
expect_rc 'nonexistent marker directory fails the pass' 1
TMUX_SHARE_NOTREADY_MARKER=$saved_marker

# ---- fail-closed configuration --------------------------------------------
saved_marker=$TMUX_SHARE_NOTREADY_MARKER
TMUX_SHARE_NOTREADY_MARKER=''
expect_rc 'unset marker variable fails the pass' 1
TMUX_SHARE_NOTREADY_MARKER=$saved_marker

saved_clock=$TMUX_SHARE_UPTIME_FILE
TMUX_SHARE_UPTIME_FILE=$work/no-such-clock
reset_marker
expect_rc 'unreadable clock fails the pass' 1
TMUX_SHARE_UPTIME_FILE=$saved_clock

# ---- server_ready ----------------------------------------------------------
set_clock 8000
reset_marker
notready_check 2>/dev/null || true
if [ -e "$TMUX_SHARE_NOTREADY_MARKER" ]; then
  server_ready || true
  if [ ! -e "$TMUX_SHARE_NOTREADY_MARKER" ]; then
    pass 'server_ready removes the marker'
  else
    fail 'server_ready removes the marker (still present)'
  fi
else
  fail 'server_ready removes the marker (setup: no marker was written)'
fi

if server_ready; then
  pass 'server_ready with no marker returns 0'
else
  fail 'server_ready with no marker returns 0'
fi

# After success the window restarts from scratch.
set_clock 8400
expect_rc 'pass after server_ready starts a fresh window' 0
expect_marker 'fresh window is stamped at the new time' 8400

# ---- marker mode -----------------------------------------------------------
reset_marker
notready_check 2>/dev/null || true
mode=$(stat -c '%a' -- "$TMUX_SHARE_NOTREADY_MARKER" 2>/dev/null \
  || stat -f '%Lp' -- "$TMUX_SHARE_NOTREADY_MARKER")
if [ "$mode" = '600' ]; then
  pass "marker mode is 0600 (mode=$mode)"
else
  fail "marker mode is 0600 (mode=$mode)"
fi

# Mode holds even under a permissive umask.
reset_marker
( umask 000; notready_check 2>/dev/null ) || true
mode=$(stat -c '%a' -- "$TMUX_SHARE_NOTREADY_MARKER" 2>/dev/null \
  || stat -f '%Lp' -- "$TMUX_SHARE_NOTREADY_MARKER")
if [ "$mode" = '600' ]; then
  pass "marker mode is 0600 under umask 000 (mode=$mode)"
else
  fail "marker mode is 0600 under umask 000 (mode=$mode)"
fi

# ---- concurrent writers ----------------------------------------------------
conc=$work/conc
mkdir -- "$conc"
TMUX_SHARE_NOTREADY_MARKER=$conc/marker
set_clock 9000
pids=()
for _i in $(seq 1 50); do
  notready_check 2>/dev/null &
  pids+=("$!")
done
bad=0
for pid in "${pids[@]}"; do
  wait "$pid" || bad=$((bad + 1))
done
if [ "$bad" -eq 0 ]; then
  pass '50 concurrent writers all completed with rc=0'
else
  fail "50 concurrent writers: $bad of 50 did not return 0"
fi

final=$(marker_text 2>/dev/null || true)
if [[ $final =~ ^[0-9]+$ ]]; then
  pass "concurrent final marker parses as digits (marker=$final)"
else
  fail "concurrent final marker parses as digits (marker='$final')"
fi

leftover=$(find "$conc" -mindepth 1 ! -name marker -print)
if [ -z "$leftover" ]; then
  pass 'no marker.XXXXXX temp file left behind'
else
  fail "temp files left behind: $leftover"
fi

# ---- summary ---------------------------------------------------------------
printf '\nSummary: %d passed, %d failed, %d skipped\n' \
  "$pass_count" "$fail_count" "$skip_count"
if [ "$fail_count" -eq 0 ]; then
  printf 'RESULT: PASS\n'
  exit 0
fi
printf 'RESULT: FAIL\n'
exit 1
