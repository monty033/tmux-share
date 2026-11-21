#!/usr/bin/env bash
# The built artifact, not the source tree: the stamp filter must name its
# interpreter by store path and must run with no PATH at all.
#
# This exists because the two are different things and the difference shipped. The
# source file starts with "#!/usr/bin/env python3", which is right for a checkout
# and wrong for a deployment: patchShebangs only rewrites an interpreter it can
# find on the builder's PATH, python3 was a runtime input but not a build input,
# and so the built stamp kept "#!/usr/bin/env python3". tmux runs the tap with the
# session's PATH, which has no python3 on this host, so every tap died the moment
# it attached -- and because it died before writing anything, the only symptom was
# an idle-looking transcript.
#
# Needs nix with flakes. Builds the package from this checkout, which is cheap
# after the first run.
set -u

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo=$(cd -- "$script_dir/../.." && pwd -P)

case ":$PATH:" in
    *:/run/current-system/sw/bin:*) ;;
    *) [ -d /run/current-system/sw/bin ] && PATH="/run/current-system/sw/bin:$PATH" ;;
esac
export PATH

passes=0
failures=0
pass() { passes=$((passes + 1)); printf 'PASS: %s\n' "$1"; }
fail() { failures=$((failures + 1)); printf 'FAIL: %s\n' "$1"; }
check() { # check NAME CONDITION-RESULT
    if [ "$2" -eq 0 ]; then pass "$1"; else fail "$1"; fi
}

if ! command -v nix >/dev/null 2>&1; then
    printf 'SKIP: nix is not available, cannot build the package\n'
    printf 'PASS: package_test (skipped)\n'
    exit 0
fi

if ! out=$(nix build --no-link --print-out-paths "path:$repo#packages.x86_64-linux.default" 2>&1); then
    printf '%s\n' "$out" | tail -5
    fail "the package builds"
    printf '\n%s passed, %s failed\nFAIL: package_test\n' "$passes" "$failures"
    exit 1
fi
pass "the package builds"
out=$(printf '%s\n' "$out" | tail -1)

stamp=$out/lib/tmux-share/core/tmux-share-stamp
[ -x "$stamp" ]
check "the stamp filter is executable" "$?"

first=$(head -1 "$stamp")
case $first in
    '#!/nix/store/'*) pass "the stamp's interpreter is a store path" ;;
    *) fail "the stamp's interpreter is a store path (found: $first)" ;;
esac

# No executable in the artifact may keep an interpreter that only exists on the
# build machine.
leftovers=$(find "$out" -type f -perm -u+x -exec grep -lE '^#!/(usr/)?bin/env ' {} + 2>/dev/null || true)
[ -z "$leftovers" ]
check "no executable keeps an env shebang" "$?"

# The real failure mode: run it with nothing in the environment at all, which is
# stricter than the tmux session's PATH.
stamped=$(printf 'probe\n' | env -i "$stamp" 2>&1)
rc=$?
[ "$rc" -eq 0 ]
check "the stamp runs with an empty environment" "$?"
printf '%s' "$stamped" | grep -q 'probe'
check "the stamp passes output through" "$?"
printf '%s' "$stamped" | grep -qE '^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] '
check "the stamp adds a timestamp" "$?"

printf '\n%s passed, %s failed\n' "$passes" "$failures"
if [ "$failures" -eq 0 ]; then
    printf 'PASS: package_test\n'
    exit 0
fi
printf 'FAIL: package_test\n'
exit 1
