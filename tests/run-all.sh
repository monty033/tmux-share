#!/usr/bin/env bash
# One command that runs every suite. Exit 0 only if all of them pass.
#
# The repository had fifteen independently runnable suites and no single entry
# point, which meant a human had to remember the list and a CI job could
# silently fall behind it. This is that list.
#
# Environment is cleaned first: several suites read TMUX_SHARE_* variables, and
# an inherited value from a live deployment makes them test the wrong thing.
set -u

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo=$(cd -- "$here/.." && pwd -P)
cd -- "$repo" || exit 1

for v in $(env | grep -o '^TMUX_SHARE_[A-Z_]*' || true); do unset "$v"; done

# A stock NixOS login may not have the usual PATH; the suites call coreutils.
case ":$PATH:" in
    *:/run/current-system/sw/bin:*) ;;
    *) [ -d /run/current-system/sw/bin ] && PATH="/run/current-system/sw/bin:$PATH" ;;
esac
export PATH

suites=0
failed=0
skipped=0
failed_names=""

run_shell() {
    local t=$1 name out rc
    name=${t#"$repo"/}
    out=$(bash "$t" 2>&1)
    rc=$?
    suites=$((suites + 1))
    if [ "$rc" -eq 0 ]; then
        printf 'ok    %s\n' "$name"
    else
        failed=$((failed + 1))
        failed_names="$failed_names
$name"
        printf 'FAIL  %s (exit %d)\n' "$name" "$rc"
        printf '%s\n' "$out" | tail -5 | sed 's/^/        /'
    fi
}

run_python() {
    local t=$1 name out rc
    name=${t#"$repo"/}
    out=$(python3 "$t" 2>&1)
    rc=$?
    suites=$((suites + 1))
    if [ "$rc" -eq 0 ]; then
        printf 'ok    %s\n' "$name"
    else
        failed=$((failed + 1))
        failed_names="$failed_names
$name"
        printf 'FAIL  %s (exit %d)\n' "$name" "$rc"
        printf '%s\n' "$out" | tail -5 | sed 's/^/        /'
    fi
}

# tests/mutation is deliberately not here: it runs seven suites to prove they
# can fail, which belongs on its own (`just mutate`), not in every green run.
for t in tests/unit/*.sh tests/systemd/*.sh tests/install/*.sh \
         tests/docs/*.sh tests/nix/*.sh tests/privacy/*.sh \
         tests/parity/*.sh tests/stubs/*.sh; do
    [ -f "$t" ] || continue
    case "$t" in
        # fake-tmux is a test double, not a suite; its own test is *_test.sh.
        tests/stubs/fake-tmux) continue ;;
    esac
    run_shell "$PWD/$t"
done

for t in tests/stamp/*.py tests/plugin/*.py; do
    [ -f "$t" ] || continue
    run_python "$PWD/$t"
done

printf '\n%d suites, %d failed\n' "$suites" "$failed"
if [ "$failed" -ne 0 ]; then
    printf 'failed:%s\n' "$failed_names"
    exit 1
fi
printf 'RESULT: PASS\n'
