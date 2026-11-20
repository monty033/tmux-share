#!/usr/bin/env bash
# Unit test for core/bin/tmux-share-attach. Needs no root and no real tmux:
# the tmux binary is a recording stub, so "nothing is executed" is observable.
# Exit 0 only if every case passes.
#
# The refusal cases need a non-root caller. If this test is itself run as
# root they are reported as SKIP (never as PASS); run it as an ordinary user.
set -eu

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/../.." && pwd)
attach=$repo_root/core/bin/tmux-share-attach

work=$(mktemp -d "${TMPDIR:-/tmp}/attach-test.XXXXXX")
cleanup() { rm -rf -- "$work"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

pass_count=0
fail_count=0
skip_count=0
pass() { pass_count=$((pass_count + 1)); printf 'PASS: %s\n' "$1"; }
fail() { fail_count=$((fail_count + 1)); printf 'FAIL: %s\n' "$1"; }
skip() { skip_count=$((skip_count + 1)); printf 'SKIP: %s\n' "$1"; }

# Recording tmux stub: appends its argv to $work/executed and exits 0.
stub=$work/stub-tmux
cat > "$stub" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$work/executed"
EOF
chmod 0755 "$stub"
executed() { [ -s "$work/executed" ]; }

export TMUX_SHARE_TMUX=$stub
export TMUX_SHARE_SESSION=tmux-hermes
export TMUX_SHARE_SOCK=$work/tmux.sock

out=$work/out
err=$work/err
rc=0
run() { rc=0; "$attach" "$@" > "$out" 2> "$err" || rc=$?; }

# ---- non-root refusal --------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
  run
  if [ "$rc" -eq 1 ]; then pass 'non-root: exits 1'; else fail "non-root: exits 1 (rc=$rc)"; fi
  if grep -q 'tmux-share-attach' "$err" && grep -q 'root-only' "$err"; then
    pass 'non-root: message names the command and says root-only'
  else
    fail "non-root: message names the command and says root-only ($(cat "$err"))"
  fi
  if [ "$(wc -l < "$err")" -eq 1 ]; then pass 'non-root: message is one line'; else fail 'non-root: message is one line'; fi
  if executed; then fail 'non-root: tmux was NOT executed'; else pass 'non-root: tmux was NOT executed'; fi
  if [ ! -s "$out" ]; then pass 'non-root: nothing on stdout'; else fail 'non-root: nothing on stdout'; fi

  run -r -d
  if [ "$rc" -eq 1 ] && ! executed; then
    pass 'non-root with operator args: still refused, nothing executed'
  else
    fail "non-root with operator args: still refused, nothing executed (rc=$rc)"
  fi

  # An unsafe session must not change the refusal into anything that runs.
  TMUX_SHARE_SESSION='x;touch pwned' run
  if [ "$rc" -eq 1 ] && ! executed && [ ! -e pwned ]; then
    pass 'non-root with hostile session: refused, nothing executed'
  else
    fail "non-root with hostile session: refused, nothing executed (rc=$rc)"
  fi
else
  skip 'non-root refusal cases (test is running as root; run as an ordinary user)'
fi

# ---- --check ----------------------------------------------------------------
want="$stub -S $work/tmux.sock attach -t tmux-hermes"

run --check
if [ "$rc" -eq 0 ]; then pass '--check: exits 0'; else fail "--check: exits 0 (rc=$rc, $(cat "$err"))"; fi
if [ "$(cat "$out")" = "$want" ]; then
  pass '--check: prints tmux binary, -S socket, attach, -t session'
else
  fail "--check: prints expected argv (got '$(cat "$out")', want '$want')"
fi
if [ "$(wc -l < "$out")" -eq 1 ]; then pass '--check: output is one line'; else fail '--check: output is one line'; fi
if executed; then fail '--check: tmux was NOT executed'; else pass '--check: tmux was NOT executed'; fi

run -r --check -d
if [ "$rc" -eq 0 ] && [ "$(cat "$out")" = "$want -r -d" ]; then
  pass '--check in any position: operator args follow the session, flag consumed'
else
  fail "--check in any position (rc=$rc, got '$(cat "$out")')"
fi

run --check -x 'two words'
if [ "$rc" -eq 0 ] && [ "$(cat "$out")" = "$want -x two\\ words" ]; then
  pass '--check: argument with a space is shown unambiguously'
else
  fail "--check: argument with a space (got '$(cat "$out")')"
fi

# ---- validation -------------------------------------------------------------
for bad in 'a;b' 'a b' '-lead' 'a$(id)' 'a`id`' "$(printf 'a\nb')"; do
  label=$(printf '%s' "$bad" | tr '\n' '~')
  TMUX_SHARE_SESSION=$bad run --check
  if [ "$rc" -ne 0 ] && [ ! -s "$out" ] && grep -q 'TMUX_SHARE_SESSION' "$err"; then
    pass "--check refuses bad session '$label': non-zero, no argv, names variable"
  else
    fail "--check refuses bad session '$label' (rc=$rc, stdout='$(cat "$out")')"
  fi
done
# An empty value falls back to the contract default, so it is not hostile.
TMUX_SHARE_SESSION= run --check
if [ "$rc" -eq 0 ] && [ "$(cat "$out")" = "$stub -S $work/tmux.sock attach -t tmux-hermes" ]; then
  pass 'empty session falls back to the default'
else
  fail "empty session falls back to the default (rc=$rc)"
fi

for bad in 'relative/sock' '/tmp/a;b' '/tmp/../etc/sock' '/tmp/a b'; do
  TMUX_SHARE_SOCK=$bad run --check
  if [ "$rc" -ne 0 ] && [ ! -s "$out" ] && grep -q 'TMUX_SHARE_SOCK' "$err"; then
    pass "--check refuses bad socket '$bad'"
  else
    fail "--check refuses bad socket '$bad' (rc=$rc, stdout='$(cat "$out")')"
  fi
done

for bad in 'tmux;id' '-tmux' 'a b'; do
  TMUX_SHARE_TMUX=$bad run --check
  if [ "$rc" -ne 0 ] && [ ! -s "$out" ] && grep -q 'TMUX_SHARE_TMUX' "$err"; then
    pass "--check refuses bad tmux binary '$bad'"
  else
    fail "--check refuses bad tmux binary '$bad' (rc=$rc, stdout='$(cat "$out")')"
  fi
done

if executed; then fail 'no case executed the tmux stub'; else pass 'no case executed the tmux stub'; fi

printf '\n%d passed, %d failed, %d skipped\n' "$pass_count" "$fail_count" "$skip_count"
if [ "$fail_count" -eq 0 ]; then printf 'PASS\n'; exit 0; fi
printf 'FAIL\n'
exit 1
