#!/usr/bin/env bash
# Unit test for core/bin/tmux-share-selftest.
#
# The self-test is run against a stand-in for tmux, generated below. The
# stand-in emulates new-session, has-session, kill-server and send-keys.
# send-keys runs the tap command that pipe-pane recorded, with the keys as its
# input, so a stamped transcript line is really written. list-panes and
# pipe-pane are delegated to tests/stubs/fake-tmux.
#
# This tests the self-test's own logic, its checks and its cleanup. It is not
# a test of tmux: the behaviour that needs a real tmux is run by hand.
#
# Scenarios: a clean run (every check PASS, no temp dir left), --keep, a stamp
# that never writes, a failing attach, a temp dir inside the deployment
# directory (refused), a missing dependency, bad usage. Sentinels at the
# transcript, the lock and the deployment directory must never change.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
SELFTEST=$ROOT/core/bin/tmux-share-selftest
FAKE=$ROOT/tests/stubs/fake-tmux

# A clean environment: nothing from an earlier shell may point the self-test
# at a stub or a deployment.
for v in $(compgen -e); do
    case $v in
        TMUX_SHARE_*) unset "$v" ;;
    esac
done

[ -x "$SELFTEST" ] || { echo "FAIL: $SELFTEST is not executable" >&2; exit 1; }
[ -x "$FAKE" ] || { echo "FAIL: $FAKE is not executable" >&2; exit 1; }

TOP=$(mktemp -d "${TMPDIR:-/tmp}/selftest-test.XXXXXX")
cleanup() {
    rm -rf -- "$TOP"
}
trap cleanup EXIT

PASSES=0
FAILS=0
pass() { PASSES=$((PASSES + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAILS=$((FAILS + 1)); printf 'FAIL %s\n' "$1"; }

# expect NAME COMMAND...: pass when COMMAND succeeds.
expect() {
    local name=$1
    shift
    if "$@"; then
        pass "$name"
    else
        fail "$name"
    fi
}

DEPLOY=$TOP/deploy
LOG_SENTINEL=$TOP/sentinel.log
LOCK_SENTINEL=$TOP/sentinel.lock
mkdir -p -- "$DEPLOY" "$TOP/tmp"
printf 'deploy sentinel\n' > "$DEPLOY/sentinel"
printf 'log sentinel\n' > "$LOG_SENTINEL"
chmod 0644 -- "$LOG_SENTINEL"
printf 'lock sentinel\n' > "$LOCK_SENTINEL"
chmod 0600 -- "$LOCK_SENTINEL"

sentinels_intact() {
    [ "$(cat -- "$LOG_SENTINEL")" = 'log sentinel' ] \
        && [ "$(stat -c %a -- "$LOG_SENTINEL")" = 644 ] \
        && [ "$(cat -- "$LOCK_SENTINEL")" = 'lock sentinel' ] \
        && [ "$(cat -- "$DEPLOY/sentinel")" = 'deploy sentinel' ]
}

deploy_entries() {
    find "$DEPLOY" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | tr '\n' ' '
}

tmp_is_empty() {
    [ -z "$(ls -A -- "$TOP/tmp")" ]
}

# make_standin NAME BROKEN: write a tmux stand-in with its own state directory.
# BROKEN=1 makes every pipe-pane attach (a call with a command) fail.
# Sets STANDIN.
make_standin() {
    local name=$1 broken=$2
    local state=$TOP/state-$name
    STANDIN=$TOP/bin-$name/tmux
    mkdir -p -- "$state" "$(dirname -- "$STANDIN")"
    sed -e "s|@FAKE@|$FAKE|" -e "s|@STATE@|$state|" -e "s|@BROKEN@|$broken|" \
        > "$STANDIN" <<'TEMPLATE'
#!/usr/bin/env bash
# tmux stand-in for tests/unit/selftest_test.sh. It is NOT tmux.
FAKE=@FAKE@
STATE=@STATE@
BROKEN=@BROKEN@
export FAKE_TMUX_STATE=$STATE

# Global options: -S SOCK, -f FILE, -L NAME. Their values are not needed here.
while [ "$#" -gt 0 ]; do
    case $1 in
        -S | -f | -L) shift 2 ;;
        *) break ;;
    esac
done
cmd=${1:-}
[ "$#" -eq 0 ] || shift

case $cmd in
    new-session)
        name=''
        while [ "$#" -gt 0 ]; do
            case $1 in
                -s) name=$2; shift 2 ;;
                -x | -y | -c | -n) shift 2 ;;
                -d) shift ;;
                *) break ;;
            esac
        done
        printf '%s\n' "$name" > "$STATE/sessions"
        printf '%%0\t0\n' > "$STATE/state"
        : > "$STATE/commands"
        ;;
    has-session)
        name=''
        while [ "$#" -gt 0 ]; do
            case $1 in
                -t) name=$2; shift 2 ;;
                *) shift ;;
            esac
        done
        grep -qxF -- "$name" "$STATE/sessions" 2>/dev/null
        ;;
    kill-server)
        : > "$STATE/sessions"
        ;;
    send-keys)
        pane='' keys=''
        while [ "$#" -gt 0 ]; do
            case $1 in
                -t) pane=$2; shift 2 ;;
                -l) shift ;;
                Enter) keys="$keys"$'\n'; shift ;;
                *) keys="$keys$1"; shift ;;
            esac
        done
        pipe=0 tapcmd=''
        while IFS=$'\t' read -r p v; do
            if [ "$p" = "$pane" ]; then pipe=$v; fi
        done < "$STATE/state"
        while IFS=$'\t' read -r p c; do
            if [ "$p" = "$pane" ]; then tapcmd=$c; fi
        done < "$STATE/commands"
        if [ "$pipe" = 1 ] && [ -n "$tapcmd" ]; then
            printf '%s' "$keys" | sh -c "$tapcmd"
        fi
        ;;
    pipe-pane)
        if [ "$BROKEN" = 1 ] && [ "$#" -ge 3 ]; then
            echo 'tmux stand-in: injected attach failure' >&2
            exit 1
        fi
        exec "$FAKE" pipe-pane "$@"
        ;;
    list-panes)
        exec "$FAKE" list-panes "$@"
        ;;
    *)
        echo "tmux stand-in: unsupported command: $cmd" >&2
        exit 2
        ;;
esac
TEMPLATE
    chmod 0755 -- "$STANDIN"
}

# run_selftest NAME [VAR=VALUE ...] [-- ARG ...]: run the self-test with only
# the given variables added to a cleared environment. Sets RC and OUT.
run_selftest() {
    local name=$1
    local envs=() args=()
    shift
    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
        envs+=("$1")
        shift
    done
    if [ "$#" -gt 0 ]; then
        shift
    fi
    args=("$@")
    OUT=$TOP/out-$name.txt
    RC=0
    env -i PATH="$PATH" TMPDIR="$TOP/tmp" TMUX_SHARE_DIR="$DEPLOY" \
        ${envs[@]+"${envs[@]}"} "$SELFTEST" ${args[@]+"${args[@]}"} \
        </dev/null >"$OUT" 2>&1 || RC=$?
}

# ---- 1. clean run ----------------------------------------------------------
make_standin clean 0
run_selftest clean "TMUX_SHARE_TMUX=$STANDIN" \
    "TMUX_SHARE_LOG=$LOG_SENTINEL" "TMUX_SHARE_LOCK=$LOCK_SENTINEL"
expect clean-run-exits-0 test "$RC" -eq 0
expect clean-run-says-ok grep -qx 'SELFTEST: ok' "$OUT"
for check in deps-present temp-dir-outside-deployment scratch-server-starts \
        tap-start-attaches output-reaches-transcript watchdog-idempotent \
        deletion-recovery trimming verifier-clean \
        cleanup-no-leftover-process cleanup-temp-dir-removed; do
    expect "clean-run-passes-$check" grep -qx "PASS $check" "$OUT"
done
expect clean-run-no-failed-check grep -q '^CHECKS: .*, 0 failed, ' "$OUT"
expect clean-run-leaves-no-temp-dir tmp_is_empty
expect clean-run-leaves-sentinels-alone sentinels_intact

# ---- 2. --keep leaves the temp dir and prints its path ----------------------
make_standin keep 0
run_selftest keep "TMUX_SHARE_TMUX=$STANDIN" -- --keep
expect keep-exits-0 test "$RC" -eq 0
kept=$(sed -n 's/^kept temp dir: //p' "$OUT")
expect keep-prints-path test -n "$kept"
expect keep-leaves-directory test -d "$kept"
expect keep-path-is-under-tmp bash -c '[ "${1#"$2"/}" != "$1" ]' _ "$kept" "$TOP/tmp"
if [ -n "$kept" ]; then
    case $kept in
        "$TOP/tmp"/*) rm -rf -- "$kept" ;;
    esac
fi

# ---- 3. a stamp that never writes is caught --------------------------------
make_standin falsestamp 0
run_selftest falsestamp "TMUX_SHARE_TMUX=$STANDIN" "TMUX_SHARE_STAMP=$(command -v false)"
expect falsestamp-exits-nonzero test "$RC" -ne 0
expect falsestamp-reports-output-failure grep -q '^FAIL output-reaches-transcript' "$OUT"
expect falsestamp-says-failed grep -qx 'SELFTEST: failed' "$OUT"
expect falsestamp-leaves-no-temp-dir tmp_is_empty

# ---- 4. a failing attach is caught -----------------------------------------
make_standin brokenattach 1
run_selftest brokenattach "TMUX_SHARE_TMUX=$STANDIN"
expect brokenattach-exits-nonzero test "$RC" -ne 0
expect brokenattach-reports-attach-failure grep -q '^FAIL tap-start-attaches' "$OUT"
expect brokenattach-leaves-no-temp-dir tmp_is_empty

# ---- 5. a temp dir inside the deployment directory is refused --------------
make_standin refuse 0
mkdir -p -- "$DEPLOY/tmp"
run_selftest refuse "TMUX_SHARE_TMUX=$STANDIN" "TMPDIR=$DEPLOY/tmp"
expect refuse-exits-nonzero test "$RC" -ne 0
expect refuse-reports-the-refusal grep -q '^FAIL temp-dir-outside-deployment' "$OUT"
expect refuse-creates-nothing-in-deployment test -z "$(ls -A -- "$DEPLOY/tmp")"

# ---- 6. a missing dependency is a FAIL, not a SKIP -------------------------
run_selftest nodep "TMUX_SHARE_TMUX=$TOP/no-such-tmux"
expect nodep-exits-nonzero test "$RC" -ne 0
expect nodep-reports-deps-failure grep -q '^FAIL deps-present' "$OUT"
expect nodep-is-not-a-skip bash -c '! grep -q "^SKIP deps-present" "$1"' _ "$OUT"

# ---- 7. bad usage ----------------------------------------------------------
run_selftest badarg -- --bogus
expect badarg-exits-2 test "$RC" -eq 2
expect badarg-says-usage grep -q 'usage: tmux-share-selftest' "$OUT"

# ---- 7b. the verifier step compares against the account that runs the server
# The self-test builds its scratch tree as the invoking account and tells the
# verifier that account owns it. A fake id that names someone else makes the
# expected owner wrong, so the verifier must fail: if the step ever fell back to
# comparing against a literal root, or skipped the owner check, this would pass.
make_standin wrongowner 0
mkdir -p -- "$TOP/fakeid"
REAL_ID=$(command -v id)
cat > "$TOP/fakeid/id" <<FAKE_ID
#!/bin/sh
if [ "\$*" = "-un" ]; then echo notme; exit 0; fi
exec $REAL_ID "\$@"
FAKE_ID
chmod 0755 -- "$TOP/fakeid/id"
run_selftest wrongowner "TMUX_SHARE_TMUX=$STANDIN" "PATH=$TOP/fakeid:$PATH"
expect wrongowner-exits-nonzero test "$RC" -ne 0
expect wrongowner-reports-verifier-failure grep -q '^FAIL verifier-clean' "$OUT"
expect wrongowner-names-the-expected-owner grep -q 'expected notme:' "$OUT"
expect wrongowner-leaves-no-temp-dir tmp_is_empty

# ---- 8. the deployment and sentinels were never touched --------------------
expect sentinels-still-intact sentinels_intact
expect deployment-holds-only-what-the-test-made \
    bash -c '[ "$1" = "sentinel tmp " ]' _ "$(deploy_entries)"

# ---- summary ---------------------------------------------------------------
printf '\n%s passed, %s failed\n' "$PASSES" "$FAILS"
if [ "$FAILS" -eq 0 ]; then
    printf 'PASS: selftest_test\n'
    exit 0
fi
printf 'FAIL: selftest_test\n'
exit 1
