#!/usr/bin/env bash
# Unit test for core/bin/tmux-share-render. No root, no tmux, no network.
# Exit 0 only if every case passes.
#
# The renderer derives a few default paths from its own location and refuses
# paths longer than 64 characters, so the test runs a copy of it from a short
# temporary directory instead of from the (possibly deep) checkout.
set -eu

script_dir=$(cd -- "${BASH_SOURCE[0]%/*}" && pwd)
repo_root=$(cd -- "${script_dir}/../.." && pwd)

work=$(mktemp -d "${TMPDIR:-/tmp}/render-test.XXXXXX")
cleanup() { rm -rf -- "$work"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$work/core/bin" "$work/core/lib"
cp -- "$repo_root/core/bin/tmux-share-render" "$work/core/bin/"
cp -- "$repo_root/core/lib/validate.sh" "$work/core/lib/"
render=$work/core/bin/tmux-share-render

pass_count=0
fail_count=0
pass() { pass_count=$((pass_count + 1)); printf 'PASS: %s\n' "$1"; }
fail() { fail_count=$((fail_count + 1)); printf 'FAIL: %s\n' "$1"; }

# Clean environment: only what each case sets reaches the renderer.
unset TMUX_SHARE_DIR TMUX_SHARE_SESSION TMUX_SHARE_SOCK TMUX_SHARE_LOG \
  TMUX_SHARE_LOCK TMUX_SHARE_NOTREADY_MARKER TMUX_SHARE_REBUILD \
  TMUX_SHARE_STAMP TMUX_SHARE_TMUX TMUX_SHARE_TIMEOUT TMUX_SHARE_MAX_BYTES \
  TMUX_SHARE_LIBDIR TMUX_SHARE_SHELL TMUX_SHARE_USER || true

out=$work/out
err=$work/err
rc=0
run() { rc=0; "$render" "$@" > "$out" 2> "$err" || rc=$?; }
has() { grep -qF -- "$1" "$out"; }

# ---- tmux-config ------------------------------------------------------------
TMUX_SHARE_SESSION=my-session run tmux-config
if [ "$rc" -eq 0 ]; then pass 'tmux-config: exits 0'; else fail "tmux-config: exits 0 (rc=$rc, $(cat "$err"))"; fi
if has 'my-session'; then pass 'tmux-config: contains the session name'; else fail 'tmux-config: contains the session name'; fi
if grep -qx 'set -g exit-empty on' "$out"; then pass 'tmux-config: contains "set -g exit-empty on"'; else fail 'tmux-config: contains "set -g exit-empty on"'; fi
if grep -qi 'systemd owns the lifecycle' "$out"; then pass 'tmux-config: explains exit-empty (systemd owns the lifecycle)'; else fail 'tmux-config: explains exit-empty'; fi
if ! has 'default-shell'; then pass 'tmux-config: no default-shell when TMUX_SHARE_SHELL is unset'; else fail 'tmux-config: no default-shell when TMUX_SHARE_SHELL is unset'; fi

TMUX_SHARE_SHELL=/bin/zsh run tmux-config
if grep -qx 'set -g default-shell /bin/zsh' "$out"; then pass 'tmux-config: operator shell rendered when set'; else fail 'tmux-config: operator shell rendered when set'; fi
if grep -qi 'dedicated' "$out"; then pass 'tmux-config: explains global settings (dedicated server)'; else fail 'tmux-config: explains global settings'; fi

# Every directive line is preceded (possibly after other comments) by a comment.
undocumented=$(awk '
  /^#/ { c = 1; next }
  /^$/ { if (c != 2) c = 0; next }
  { if (c == 0) print "no comment before: " $0; c = 0 }
' "$out")
if [ -z "$undocumented" ]; then pass 'tmux-config: every directive has a comment'; else fail "tmux-config: every directive has a comment: $undocumented"; fi

# ---- hostile values ---------------------------------------------------------
for bad in 'a;b' "$(printf 'a\nkill-server')" 'a b' '$(id)' '`id`'; do
  label=$(printf '%s' "$bad" | tr '\n' '~')
  for mode in tmux-config units paths; do
    TMUX_SHARE_SESSION=$bad run "$mode"
    if [ "$rc" -ne 0 ] && [ ! -s "$out" ] && grep -q 'TMUX_SHARE_SESSION' "$err"; then
      pass "$mode refuses session '$label': non-zero, empty stdout, names variable"
    else
      fail "$mode refuses session '$label' (rc=$rc, stdout bytes=$(wc -c < "$out"))"
    fi
  done
done

for pair in 'TMUX_SHARE_SOCK=/tmp/a;b' 'TMUX_SHARE_LOG=relative' 'TMUX_SHARE_DIR=/tmp/../x' \
  'TMUX_SHARE_TMUX=tmux;id' 'TMUX_SHARE_TMUX=%h' 'TMUX_SHARE_TIMEOUT=-x' \
  'TMUX_SHARE_MAX_BYTES=12a' 'TMUX_SHARE_MAX_BYTES=0' 'TMUX_SHARE_SHELL=/bin/sh;id'; do
  name=${pair%%=*}
  value=${pair#*=}
  for mode in tmux-config units paths; do
    rc=0
    env "$pair" "$render" "$mode" > "$out" 2> "$err" || rc=$?
    if [ "$rc" -ne 0 ] && [ ! -s "$out" ] && grep -q "$name" "$err"; then
      pass "$mode refuses $name='$value'"
    else
      fail "$mode refuses $name='$value' (rc=$rc, stdout bytes=$(wc -c < "$out"))"
    fi
  done
done

# A program path is a path: an install prefix well past 64 characters must be
# accepted, because that bound is for identifiers and this was the bug that
# stopped a real installer.
LONGP="$PWD/$(printf 'p%.0s' $(seq 1 80))"
mkdir -p "$LONGP"; printf '#!/bin/sh\n' > "$LONGP/tmux"; chmod 0755 "$LONGP/tmux"
rc=0
env TMUX_SHARE_TMUX="$LONGP/tmux" "$render" tmux-config > "$out" 2> "$err" || rc=$?
if [ "$rc" -eq 0 ] && [ -s "$out" ]; then pass 'accepts a program path longer than 64 characters'
else fail "accepts a program path longer than 64 characters (rc=$rc)"; fi
rm -rf "$LONGP"

# The offending value itself is never echoed.
TMUX_SHARE_SESSION='evil;value' run paths
if ! grep -q 'evil' "$err"; then pass 'error message does not echo the rejected value'; else fail 'error message does not echo the rejected value'; fi

# ---- paths ------------------------------------------------------------------
TMUX_SHARE_SHELL=/bin/zsh run paths
if [ "$rc" -eq 0 ]; then pass 'paths: exits 0'; else fail "paths: exits 0 (rc=$rc, $(cat "$err"))"; fi
badlines=$(grep -vcE "^[A-Z_]+='[^']*'$" "$out" || true)
if [ "$badlines" -eq 0 ] && [ -s "$out" ]; then pass 'paths: every line is KEY='"'"'value'"'"''; else fail "paths: every line is KEY='value' ($badlines bad)"; fi
for key in TMUX_SHARE_DIR TMUX_SHARE_SESSION TMUX_SHARE_SOCK TMUX_SHARE_LOG TMUX_SHARE_LOCK \
  TMUX_SHARE_NOTREADY_MARKER TMUX_SHARE_REBUILD TMUX_SHARE_STAMP TMUX_SHARE_TMUX \
  TMUX_SHARE_TIMEOUT TMUX_SHARE_MAX_BYTES TMUX_SHARE_LIBDIR TMUX_SHARE_SHELL; do
  if grep -q "^$key=" "$out"; then pass "paths: defines $key"; else fail "paths: defines $key"; fi
done
# Parse in a subshell with a clean environment and read the values back.
parsed=$(
  unset TMUX_SHARE_SESSION TMUX_SHARE_SOCK
  # shellcheck disable=SC1090
  eval "$(cat "$out")"
  printf '%s|%s' "$TMUX_SHARE_SESSION" "$TMUX_SHARE_SOCK"
) || parsed='EVAL-FAILED'
if [ "$parsed" = 'tmux-hermes|/run/tmux-share/tmux.sock' ]; then
  pass 'paths: eval in a subshell succeeds and yields the contract defaults'
else
  fail "paths: eval in a subshell (got '$parsed')"
fi

TMUX_SHARE_DIR=/srv/ts run paths
if grep -qx "TMUX_SHARE_SOCK='/srv/ts/tmux.sock'" "$out" && grep -qx "TMUX_SHARE_LOG='/srv/ts/transcript.log'" "$out"; then
  pass 'paths: SOCK and LOG follow an overridden TMUX_SHARE_DIR'
else
  fail 'paths: SOCK and LOG follow an overridden TMUX_SHARE_DIR'
fi

# ---- units ------------------------------------------------------------------
run units
if [ "$rc" -eq 0 ]; then pass 'units: exits 0'; else fail "units: exits 0 (rc=$rc, $(cat "$err"))"; fi
markers=$(grep -cx '# ---' "$out" || true)
sections=$(grep -c '^\[Unit\]$' "$out" || true)
if [ "$sections" -ge 1 ]; then pass "units: emits at least one unit ($sections)"; else fail 'units: emits at least one unit'; fi
if [ "$markers" -eq $((sections - 1)) ]; then pass 'units: units are separated by exactly one "# ---" line each'; else fail "units: separator count (markers=$markers, units=$sections)"; fi
if [ "$sections" -ge 2 ] && [ "$markers" -ge 1 ]; then pass 'units: more than one unit, so the separator is exercised'; else fail 'units: more than one unit'; fi
if has 'ExecStart=tmux -D -S /run/tmux-share/tmux.sock'; then pass 'units: server ExecStart uses the contract socket and tmux binary'; else fail 'units: server ExecStart uses the contract socket'; fi
if grep -qx 'Environment="TMUX_SHARE_SESSION=tmux-hermes"' "$out"; then pass 'units: carries the contract environment'; else fail 'units: carries the contract environment'; fi
# Each section between markers starts with a "# name" comment and has a body.
empty=$(awk 'BEGIN{n=0} /^# ---$/ { if (n < 2) print "short section"; n = 0; next } { n++ } END { if (n < 2) print "short section" }' "$out")
if [ -z "$empty" ]; then pass 'units: no empty section between markers'; else fail 'units: no empty section between markers'; fi

# ---- TMUX_SHARE_USER --------------------------------------------------------
# Root (set or not) renders exactly what an unset user renders: the account is
# named in the output only when it is not root.
run units; cp -- "$out" "$work/units.default"
run paths; cp -- "$out" "$work/paths.default"
TMUX_SHARE_USER=root run units
if cmp -s "$out" "$work/units.default"; then pass 'user: root renders units byte-identical to no user'; else fail 'user: root renders units byte-identical to no user'; fi
TMUX_SHARE_USER=root run paths
if cmp -s "$out" "$work/paths.default"; then pass 'user: root renders paths byte-identical to no user'; else fail 'user: root renders paths byte-identical to no user'; fi
if ! grep -q '^User=' "$work/units.default"; then pass 'user: the default units carry no User= line'; else fail 'user: the default units carry no User= line'; fi

TMUX_SHARE_USER=bob run units
if [ "$rc" -eq 0 ] && [ "$(grep -cx 'User=bob' "$out")" -eq 3 ]; then
  pass 'user: a non-root account puts User=bob in all three services'
else
  fail "user: a non-root account puts User=bob in all three services (rc=$rc)"
fi
if grep -qx 'Environment="TMUX_SHARE_USER=bob"' "$out"; then pass 'user: units carry TMUX_SHARE_USER in the environment'; else fail 'user: units carry TMUX_SHARE_USER in the environment'; fi
# User= sits inside a [Service] section, never in [Unit] or [Timer].
misplaced=$(awk '/^\[/ { sec = $0 } /^User=/ && sec != "[Service]" { print sec }' "$out")
if [ -z "$misplaced" ]; then pass 'user: every User= line is inside [Service]'; else fail "user: User= outside [Service]: $misplaced"; fi
TMUX_SHARE_USER=bob run paths
if grep -qx "TMUX_SHARE_USER='bob'" "$out"; then pass 'user: paths defines TMUX_SHARE_USER for a non-root account'; else fail 'user: paths defines TMUX_SHARE_USER for a non-root account'; fi

for bad in 'a;b' 'a b' '-lead' '.lead' 'a$(id)' 'a`id`' 'a/b' "a'b"; do
  TMUX_SHARE_USER=$bad run units
  if [ "$rc" -ne 0 ] && [ ! -s "$out" ] && grep -q 'TMUX_SHARE_USER' "$err" && ! grep -qF -- "$bad" "$err"; then
    pass "user: refuses '$bad' with nothing on stdout and without echoing it"
  else
    fail "user: refuses '$bad' (rc=$rc)"
  fi
done

# ---- no host probing --------------------------------------------------------
# paths mode is pure builtins, so it works with an unusable PATH.
rc=0
PATH=/nonexistent "$BASH" "$render" paths > "$out" 2> "$err" || rc=$?
if [ "$rc" -eq 0 ] && [ -s "$out" ]; then pass 'paths mode renders with an empty PATH (builtins only)'; else fail "paths mode renders with an empty PATH (rc=$rc, $(cat "$err"))"; fi

# ---- --help -----------------------------------------------------------------
run --help
if [ "$rc" -eq 0 ]; then pass '--help: exits 0'; else fail "--help: exits 0 (rc=$rc)"; fi
if has 'tmux-config' && has 'units' && has 'paths'; then pass '--help: lists the three modes'; else fail '--help: lists the three modes'; fi

run bogus
if [ "$rc" -ne 0 ] && [ ! -s "$out" ]; then pass 'unknown mode: non-zero, nothing on stdout'; else fail "unknown mode (rc=$rc)"; fi

printf '\n%d passed, %d failed\n' "$pass_count" "$fail_count"
if [ "$fail_count" -eq 0 ]; then printf 'PASS\n'; exit 0; fi
printf 'FAIL\n'
exit 1
