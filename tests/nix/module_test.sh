#!/usr/bin/env bash
# Builds the flake check checks.<system>.module-renders, which evaluates the
# NixOS module and asserts the rendered units, tmpfiles rules and tmux config,
# then reports every named assertion as PASS or FAIL.
#
# Needs nix with flakes, and a git checkout (flakes read tracked files only).
# Without nix on the host, prints SKIP and exits 0.
#
# Exit status: 0 PASS or SKIP; 1 FAIL.
set -eu

script_dir=$(cd -- "${BASH_SOURCE[0]%/*}" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)

# Clean environment: a TMUX_SHARE_* variable from an earlier shell must not
# reach the build.
for v in $(env | grep -o '^TMUX_SHARE_[A-Z_]*' || true); do unset "$v"; done

# The named assertions the check must report. One that is missing from the
# build output is a FAIL, so the check cannot shrink without this test noticing.
EXPECTED='
good-config-assertions-hold
session-name-semicolon-rejected
server-exec-start-post-dash
server-exec-start-post-tap-start
server-exec-start-foreground
server-restart-on-failure
no-umask-in-units
tap-timer-accuracy-1s
trim-timer-accuracy-1s
tap-timer-20s
trim-timer-5min
tap-oneshot
trim-oneshot
no-remain-after-exit-yes
tmpfiles-dir-0710
tmpfiles-transcript-0640
tmpfiles-lock-0600
tmpfiles-no-socket-rule
tmux-conf-exit-empty
tmux-conf-new-session
tmux-conf-default-shell
tmux-conf-no-other-settings
env-session
env-max-bytes
user-default-render-identical-to-base
user-root-render-identical-to-base
user-default-declares-no-user
user-alice-assertions-hold
user-alice-env
user-alice-tmpfiles-dir
user-alice-tmpfiles-transcript
user-alice-primary-group-is-users
user-alice-tmpfiles-lock
user-alice-lock-group-not-named-after-the-account
user-own-group-tmpfiles-lock
user-alice-etc-conf-owned
user-alice-etc-env-owned
user-alice-tmpfiles-no-root
user-alice-server-runs-as
user-alice-tap-runs-as
user-alice-trim-runs-as
user-alice-timers-no-user
user-alice-no-umask-no-runtimedirectory
user-alice-session-in-the-account-home
user-alice-session-not-in-root
user-home-slash-session-in-slash
user-comment-names-the-slash
user-comment-names-the-home
user-semicolon-rejected
user-undeclared-rejected
user-undeclared-explains-boot-failure
user-without-primary-group-rejected
user-alice-not-rejected-as-undeclared
user-equal-to-reader-rejected
'

if ! command -v nix >/dev/null 2>&1; then
    printf 'SKIP: module_test: nix is not installed on this host, so checks.<system>.module-renders cannot be built\n'
    exit 0
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/tmux-share-module-test.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

nix_cmd() { nix --extra-experimental-features 'nix-command flakes' "$@"; }

if ! system=$(nix_cmd eval --impure --raw --expr builtins.currentSystem 2>"$work/err"); then
    printf 'FAIL: module_test: cannot read the current system: %s\n' "$(head -n 3 "$work/err")"
    exit 1
fi

cd -- "$repo_root"
build_rc=0
nix_cmd build ".#checks.$system.module-renders" --no-link --print-build-logs \
    >"$work/build.out" 2>&1 || build_rc=$?

# TRAP: a cached build prints no build log, so the ASSERT lines are read from
# the log Nix stored for the derivation. The build output is the fallback.
drv=$(nix_cmd eval --raw ".#checks.$system.module-renders.drvPath" 2>/dev/null) || drv=
if [ -z "$drv" ] || ! nix_cmd log "$drv" >"$work/build.log" 2>&1; then
    cp "$work/build.out" "$work/build.log"
fi

pass=0
fail=0
seen=' '

# The check prints "ASSERT PASS name" or "ASSERT FAIL name"; nix may prefix
# each log line, so the match is not anchored.
while IFS= read -r line; do
    [ -n "$line" ] || continue
    status=${line#ASSERT }
    status=${status%% *}
    name=${line##* }
    seen="$seen$name "
    case $status in
        PASS)
            pass=$((pass + 1))
            printf 'PASS: %s\n' "$name"
            ;;
        FAIL)
            fail=$((fail + 1))
            printf 'FAIL: %s\n' "$name"
            ;;
    esac
done <<EOF
$(grep -oE 'ASSERT (PASS|FAIL) [^ ]+' "$work/build.log" || true)
EOF

for name in $EXPECTED; do
    case $seen in
        *" $name "*) ;;
        *)
            fail=$((fail + 1))
            printf 'FAIL: %s (not reported by the check)\n' "$name"
            ;;
    esac
done

if [ "$build_rc" -ne 0 ]; then
    fail=$((fail + 1))
    printf 'FAIL: module-renders did not build (nix exit %s); last lines of the log:\n' "$build_rc"
    tail -n 25 "$work/build.log" | sed 's/^/    /'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -eq 0 ]; then
    printf 'RESULT: PASS\n'
    exit 0
fi
printf 'RESULT: FAIL\n'
exit 1
