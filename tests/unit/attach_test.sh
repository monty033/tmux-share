#!/usr/bin/env bash
# Unit test for core/bin/tmux-share-attach. Needs no root and no real tmux:
# the tmux binary is a recording stub, so "nothing is executed" is observable.
# Exit 0 only if every case passes.
#
# The refusal cases need a non-root caller. If this test is itself run as
# root they are reported as SKIP (never as PASS); run it as an ordinary user.
#
# Who may attach is decided by who owns the directory the socket lives in. The
# refusal cases therefore point the socket at "/", which root owns, and the
# allowed case at $work, which the caller owns. No fake id or stat decides the
# outcome: the gate does not call them, and two cases prove a fake id cannot
# talk it into letting a caller in.
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
# A root-owned runtime directory: "/" is always owned by root.
rootsock=/tmux.sock
if [ "$(id -u)" -ne 0 ]; then
  export TMUX_SHARE_SOCK=$rootsock
  run
  if [ "$rc" -eq 1 ]; then pass 'non-root: exits 1'; else fail "non-root: exits 1 (rc=$rc)"; fi
  if grep -q 'tmux-share-attach' "$err" && grep -q 'root-only' "$err"; then
    pass 'non-root, root-owned runtime directory: message names the command and says root-only'
  else
    fail "non-root, root-owned runtime directory: message names the command and says root-only ($(cat "$err"))"
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

  # The directory is named by the socket, so pointing TMUX_SHARE_DIR at a
  # directory the caller owns does not let a root-owned socket through.
  TMUX_SHARE_DIR=$work run
  if [ "$rc" -eq 1 ] && ! executed; then
    pass 'non-root: TMUX_SHARE_DIR set to a caller-owned directory does not pass the gate'
  else
    fail "non-root: TMUX_SHARE_DIR set to a caller-owned directory does not pass the gate (rc=$rc)"
  fi

  # A directory that does not exist has no owner to allow.
  TMUX_SHARE_SOCK=$work/missing/tmux.sock run
  if [ "$rc" -eq 1 ] && ! executed && grep -q 'does not exist' "$err"; then
    pass 'non-root: a missing runtime directory is refused and the message says so'
  else
    fail "non-root: a missing runtime directory is refused and the message says so (rc=$rc, $(cat "$err"))"
  fi

  # A program found through PATH is the caller's to replace, so none may
  # decide the gate: a fake id that claims uid 0 must not let anyone in.
  mkdir -p "$work/fakebin"
  printf '#!/bin/sh\necho 0\n' > "$work/fakebin/id"
  chmod 0755 "$work/fakebin/id"
  PATH=$work/fakebin:$PATH run
  if [ "$rc" -eq 1 ] && ! executed; then
    pass 'non-root: a fake id on PATH claiming uid 0 is still refused'
  else
    fail "non-root: a fake id on PATH claiming uid 0 is still refused (rc=$rc)"
  fi

  # The refusal names the account that may attach. stat is used for the name
  # only, so the fake is harmless to the decision: the run is still refused.
  printf '#!/bin/sh\necho alice\n' > "$work/fakebin/stat"
  chmod 0755 "$work/fakebin/stat"
  PATH=$work/fakebin:$PATH run
  if [ "$rc" -eq 1 ] && ! executed && grep -q 'root or by alice' "$err" && [ "$(wc -l < "$err")" -eq 1 ]; then
    pass 'non-root: the refusal names the owner of the runtime directory, in one line'
  else
    fail "non-root: the refusal names the owner of the runtime directory (rc=$rc, $(cat "$err"))"
  fi
  rm -rf -- "$work/fakebin"

  # The configured user (here, whoever owns the directory: this account) is
  # not refused for being non-root. $work is created by this test, so the
  # caller owns it, as the configured user owns the runtime directory.
  export TMUX_SHARE_SOCK=$work/tmux.sock
  run
  if [ "$rc" -eq 0 ] && executed && [ "$(cat "$work/executed")" = "-S $work/tmux.sock attach -t tmux-hermes" ]; then
    pass 'non-root owner of the runtime directory: not refused, tmux runs with the fixed argv'
  else
    fail "non-root owner of the runtime directory: not refused (rc=$rc, $(cat "$err"))"
  fi
  rm -f -- "$work/executed"

  # A runtime directory owned by a non-root account that is not the caller: the
  # caller is the third user. Whatever directory on this host is owned by some
  # other ordinary account will do, since the gate only reads the owner. The
  # case is skipped, never passed, when the host has none.
  other_dir=$(find / -xdev -maxdepth 3 -type d ! -uid 0 ! -uid "$(id -u)" 2>/dev/null | head -n 1 || true)
  if [ -n "$other_dir" ]; then
    other_owner=$(stat -c %U -- "$other_dir")
    TMUX_SHARE_SOCK=$other_dir/tmux.sock run
    if [ "$rc" -eq 1 ] && ! executed && grep -q "root or by $other_owner" "$err" && ! grep -q 'root-only' "$err"; then
      pass 'non-root third user: a directory owned by another non-root account is refused, naming that account'
    else
      fail "non-root third user: refused, naming the owner (rc=$rc, $(cat "$err"))"
    fi
  else
    skip 'non-root third user: no directory owned by another ordinary account on this host'
  fi

  # The check is a courtesy, and this case records what that means: the
  # directory comes from TMUX_SHARE_SOCK, which the caller supplies, so a
  # caller can name one they own and pass. The test exists so nobody reads the
  # refusals above as a control; the socket's mode is the boundary.
  TMUX_SHARE_SOCK=$work/anything.sock run
  if [ "$rc" -eq 0 ] && executed; then
    pass 'non-root: naming a socket in a directory the caller owns passes the courtesy check (the boundary is the socket mode)'
  else
    fail "non-root: naming a socket in a caller-owned directory (rc=$rc)"
  fi
  rm -f -- "$work/executed"
else
  skip 'non-root refusal cases (test is running as root; run as an ordinary user)'
fi
export TMUX_SHARE_SOCK=$work/tmux.sock

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

# --check stays open to every account, including one the gate refuses.
TMUX_SHARE_SOCK=/tmux.sock run --check
if [ "$rc" -eq 0 ] && [ "$(cat "$out")" = "$stub -S /tmux.sock attach -t tmux-hermes" ]; then
  pass '--check: still works against a runtime directory the caller does not own'
else
  fail "--check: still works against a runtime directory the caller does not own (rc=$rc)"
fi

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
