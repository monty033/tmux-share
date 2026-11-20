#!/usr/bin/env bash
# Unit test for core/bin/tmux-share-preflight.
#
# Cases:
#   1. a real tmux, if one is on PATH: the preflight runs end to end and
#      reports no failures (SKIP when there is no tmux);
#   2. tests/stubs/fake-tmux: the probe completes and reports a sensible
#      status. fake-tmux has no new-session, kill-server, set-option,
#      show-options or send-keys, so a thin wrapper (in the temp dir) answers
#      those and passes list-panes and pipe-pane through to the fake, which
#      owns the pipe state;
#   3. the preflight refuses to run when TMUX_SHARE_SOCK or TMUX_SHARE_DIR
#      already exists;
#   4. afterwards the scratch directory, socket and server are gone;
#   plus failure paths: a failing pipe-pane, a tmux that cannot start, bad
#   configuration and bad usage.
#
# Every run uses its own TMPDIR and a TMUX_SHARE_DIR that does not exist, so
# the host's real deployment (if any) never matters and the temp tree can be
# inspected afterwards.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
SCRIPT=$ROOT/core/bin/tmux-share-preflight
FAKE=$ROOT/tests/stubs/fake-tmux

# A leaked variable from an earlier shell would silently point the script at
# a stub: drop them all, then set only what a case needs.
for v in $(env | grep -o '^TMUX_SHARE_[A-Z_]*' || true); do unset "$v"; done
unset TMUX TMUX_PANE FAKE_TMUX_STATE FAKE_TMUX_RC FAKE_TMUX_STDERR FAKE_TMUX_SLEEP

TOP=$(mktemp -d "${TMPDIR:-/tmp}/preflight-test.XXXXXX")
cleanup() {
    # Kill any scratch server a failed case left behind, by its recorded socket.
    local f s
    if [ -n "${REAL_TMUX:-}" ]; then
        for f in "$TOP"/*/state/sockets; do
            [ -f "$f" ] || continue
            while IFS= read -r s; do
                [ -n "$s" ] || continue
                "$REAL_TMUX" -S "$s" kill-server >/dev/null 2>&1 || true
            done < "$f"
        done
    fi
    rm -rf -- "$TOP"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

PASSES=0
FAILS=0
SKIPS=0
pass() { PASSES=$((PASSES + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAILS=$((FAILS + 1)); printf 'FAIL %s\n' "$1"; }
skip() { SKIPS=$((SKIPS + 1)); printf 'SKIP %s\n' "$1"; }

# check_eq NAME ACTUAL EXPECTED
check_eq() {
    if [ "$2" = "$3" ]; then
        pass "$1"
    else
        fail "$1 (expected <$3> got <$2>)"
    fi
}

# check_contains NAME HAYSTACK NEEDLE
check_contains() {
    case $2 in
        *"$3"*) pass "$1" ;;
        *) fail "$1 (<$3> not found in <$2>)" ;;
    esac
}

# check_not_contains NAME HAYSTACK NEEDLE
check_not_contains() {
    case $2 in
        *"$3"*) fail "$1 (<$3> unexpectedly found in <$2>)" ;;
        *) pass "$1" ;;
    esac
}

# check_match NAME TEXT ERE
check_match() {
    if [[ $2 =~ $3 ]]; then
        pass "$1"
    else
        fail "$1 (<$3> does not match <$2>)"
    fi
}

# ---- tmux wrappers -----------------------------------------------------------
# Both wrappers append every -S socket they see to $FAKE_TMUX_STATE/sockets,
# so the test can prove those sockets are gone afterwards.
REAL_TMUX=''
if command -v tmux >/dev/null 2>&1; then
    REAL_TMUX=$(command -v tmux)
fi

mkdir -p -- "$TOP/bin"

# logtmux: the real tmux, with socket logging.
LOGTMUX=$TOP/bin/logtmux
cat > "$LOGTMUX" <<EOF
#!/usr/bin/env bash
set -eu
prev=''
for a in "\$@"; do
    if [ "\$prev" = -S ]; then printf '%s\n' "\$a" >> "\$FAKE_TMUX_STATE/sockets"; fi
    prev=\$a
done
exec '$REAL_TMUX' "\$@"
EOF
chmod +x "$LOGTMUX"

# faketmux: fake-tmux plus the subcommands the preflight needs. send-keys
# replays the typed text into the pane's recorded pipe command, which is what
# a real pty would do.
FAKEWRAP=$TOP/bin/faketmux
cat > "$FAKEWRAP" <<EOF
#!/usr/bin/env bash
set -eu
FAKE='$FAKE'
STATE=\$FAKE_TMUX_STATE
mkdir -p -- "\$STATE"
sock=''
while [ "\$#" -gt 0 ]; do
    case \$1 in
        -S) sock=\$2; shift 2 ;;
        -f) shift 2 ;;
        *) break ;;
    esac
done
if [ -n "\$sock" ]; then printf '%s\n' "\$sock" >> "\$STATE/sockets"; fi
sub=\${1:-}
if [ "\$#" -gt 0 ]; then shift; fi
case \$sub in
    new-session)
        name=''
        while [ "\$#" -gt 0 ]; do
            case \$1 in
                -s) name=\$2; shift 2 ;;
                -c) shift 2 ;;
                *) shift ;;
            esac
        done
        printf '%s\n' "\$name" >> "\$STATE/sessions"
        printf '%%0\t0\n' >> "\$STATE/state"
        : > "\$sock"
        ;;
    kill-server)
        [ -z "\$sock" ] || rm -f -- "\$sock"
        : > "\$STATE/sessions"
        : > "\$STATE/state"
        ;;
    display-message)
        exit 1
        ;;
    set-option)
        shift
        printf '%s\n' "\$2" > "\$STATE/opt.\$1"
        ;;
    show-options)
        if [ -f "\$STATE/opt.\$2" ]; then cat "\$STATE/opt.\$2"; else printf 'on\n'; fi
        ;;
    send-keys)
        pane=''
        text=''
        while [ "\$#" -gt 0 ]; do
            case \$1 in
                -t) pane=\$2; shift 2 ;;
                Enter) shift ;;
                *) text=\$1; shift ;;
            esac
        done
        while IFS=\$'\t' read -r p c; do
            if [ "\$p" = "\$pane" ]; then cmd=\$c; fi
        done < "\$STATE/commands"
        if [ -n "\${cmd:-}" ]; then
            printf '%s\n' "\$text" | bash -c "\$cmd"
        fi
        ;;
    pipe-pane)
        if [ -n "\${WRAP_FAIL_PIPE:-}" ]; then
            printf 'pipe-pane: simulated failure\n' >&2
            exit 1
        fi
        exec "\$FAKE" pipe-pane "\$@"
        ;;
    *)
        exec "\$FAKE" "\$sub" "\$@"
        ;;
esac
EOF
chmod +x "$FAKEWRAP"

# ---- run helpers ---------------------------------------------------------------
RC=0
OUT=''
ERR=''
CASE_DIR=''
CASE_TMP=''
CASE_STATE=''
CASE_NODIR=''
EXTRA_ENV=()

# new_case NAME: a fresh tree with an empty TMPDIR and a nonexistent
# TMUX_SHARE_DIR.
new_case() {
    CASE_DIR=$TOP/$1
    CASE_TMP=$CASE_DIR/tmp
    CASE_STATE=$CASE_DIR/state
    CASE_NODIR=$CASE_DIR/nodir
    mkdir -p -- "$CASE_TMP" "$CASE_STATE"
    EXTRA_ENV=()
}

# run_pf TMUXBIN [ARGS...]: run the preflight; fills RC, OUT, ERR.
run_pf() {
    local bin=$1
    shift
    RC=0
    env \
        TMPDIR="$CASE_TMP" \
        TMUX_SHARE_DIR="$CASE_NODIR" \
        TMUX_SHARE_TMUX="$bin" \
        FAKE_TMUX_STATE="$CASE_STATE" \
        ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} \
        "$SCRIPT" "$@" > "$CASE_DIR/out" 2> "$CASE_DIR/err" || RC=$?
    OUT=$(cat "$CASE_DIR/out")
    ERR=$(cat "$CASE_DIR/err")
}

# procs_matching NEEDLE: pids whose command line contains NEEDLE (Linux /proc).
procs_matching() {
    local d c
    for d in /proc/[0-9]*; do
        [ -r "$d/cmdline" ] || continue
        c=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null) || continue
        case $c in
            *"$1"*) printf '%s\n' "${d#/proc/}" ;;
        esac
    done
}

# assert_clean NAME: nothing of the scratch run remains.
assert_clean() {
    local name=$1 leftover socks s n gone=1 live=''
    leftover=$(find "$CASE_TMP" -mindepth 1 2>/dev/null || true)
    check_eq "$name: temp dir removed (TMPDIR is empty)" "$leftover" ''

    socks=''
    if [ -f "$CASE_STATE/sockets" ]; then
        socks=$(sort -u "$CASE_STATE/sockets")
    fi
    if [ -n "$socks" ]; then
        pass "$name: scratch socket was recorded (so the next checks are not vacuous)"
    else
        fail "$name: scratch socket was recorded (the wrapper saw no -S argument)"
    fi
    while IFS= read -r s; do
        [ -n "$s" ] || continue
        case $s in
            "$CASE_TMP"/*) ;;
            *) fail "$name: scratch socket lives under the case TMPDIR ($s)" ;;
        esac
        if [ -e "$s" ] || [ -L "$s" ]; then gone=0; fi
    done <<EOF
$socks
EOF
    check_eq "$name: no leftover socket" "$gone" 1

    if [ -d /proc/self ]; then
        n=0
        while [ "$n" -lt 20 ]; do
            live=$(procs_matching "$CASE_TMP" | tr '\n' ' ')
            [ -z "$live" ] && break
            n=$((n + 1))
            sleep 0.1
        done
        check_eq "$name: no leftover process matching the scratch path" "$live" ''
    else
        skip "$name: no /proc, cannot scan for a leftover process"
    fi
}

# assert_server_gone NAME: with a real tmux, the scratch server answers nothing.
assert_server_gone() {
    local name=$1 s alive=0
    while IFS= read -r s; do
        [ -n "$s" ] || continue
        if "$REAL_TMUX" -S "$s" list-sessions >/dev/null 2>&1; then alive=1; fi
    done < "$CASE_STATE/sockets"
    check_eq "$name: scratch tmux server no longer answers" "$alive" 0
}

# ============================================================================
# 1. a real tmux
# ============================================================================
if [ -n "$REAL_TMUX" ]; then
    new_case real
    ver=$("$REAL_TMUX" -V 2>/dev/null || echo unknown)
    printf '# real tmux: %s (%s)\n' "$REAL_TMUX" "$ver"
    run_pf "$LOGTMUX"
    printf '%s\n' "$OUT" | sed 's/^/# | /'
    check_eq "real: exits 0" "$RC" 0
    check_match "real: summary reports no failures" "$OUT" 'PREFLIGHT: [0-9]+ passed, 0 failed, [0-9]+ warnings'
    check_not_contains "real: no FAIL line" "$OUT" 'FAIL '
    check_contains "real: pipe-pane-attach passes" "$OUT" 'PASS pipe-pane-attach'
    check_contains "real: pane-pipe-format passes" "$OUT" 'PASS pane-pipe-format'
    check_contains "real: pipe-pane-detach passes" "$OUT" 'PASS pipe-pane-detach'
    check_contains "real: list-panes-session passes" "$OUT" 'PASS list-panes-session'
    check_contains "real: exit-empty-option passes" "$OUT" 'PASS exit-empty-option'
    check_match "real: pipe-pane-o-toggle is reported (PASS or WARN, never FAIL)" "$OUT" '(PASS|WARN) pipe-pane-o-toggle'
    assert_clean "real"
    assert_server_gone "real"

    run_pf "$LOGTMUX" --json
    check_eq "real --json: exits 0" "$RC" 0
    check_contains "real --json: status ok" "$OUT" '"status":"ok"'
    check_contains "real --json: has a checks array" "$OUT" '"checks":['
    assert_clean "real --json"
    assert_server_gone "real --json"
else
    skip "real tmux cases (no tmux on PATH)"
fi

# ============================================================================
# 2. fake-tmux
# ============================================================================
new_case fake
run_pf "$FAKEWRAP"
printf '%s\n' "$OUT" | sed 's/^/# | /'
check_eq "fake: exits 0" "$RC" 0
check_contains "fake: pipe-pane-attach passes" "$OUT" 'PASS pipe-pane-attach'
check_contains "fake: pane-pipe-format passes" "$OUT" 'PASS pane-pipe-format'
check_contains "fake: pipe-pane-detach passes" "$OUT" 'PASS pipe-pane-detach'
check_contains "fake: pipe-pane-o-toggle warns (the fake models the toggle)" "$OUT" 'WARN pipe-pane-o-toggle'
check_contains "fake: list-panes-session passes" "$OUT" 'PASS list-panes-session'
check_contains "fake: exit-empty-option passes" "$OUT" 'PASS exit-empty-option'
check_contains "fake: warnings are summarised" "$OUT" 'Warnings:'
check_eq "fake: final line" "${OUT##*$'\n'}" 'PREFLIGHT: 5 passed, 0 failed, 1 warnings'
assert_clean "fake"

run_pf "$FAKEWRAP" --json
check_eq "fake --json: exits 0" "$RC" 0
check_contains "fake --json: status ok" "$OUT" '"status":"ok"'
check_contains "fake --json: counts" "$OUT" '"passed":5,"failed":0,"warnings":1'
check_contains "fake --json: toggle check is a warn" "$OUT" '"name":"pipe-pane-o-toggle","status":"warn"'
check_eq "fake --json: one line of output" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" 1
assert_clean "fake --json"

# ============================================================================
# 3. refusals
# ============================================================================
new_case refuse_sock
: > "$CASE_DIR/dummy.sock"
RC=0
env TMPDIR="$CASE_TMP" TMUX_SHARE_DIR="$CASE_NODIR" TMUX_SHARE_SOCK="$CASE_DIR/dummy.sock" \
    TMUX_SHARE_TMUX="$FAKEWRAP" FAKE_TMUX_STATE="$CASE_STATE" \
    "$SCRIPT" > "$CASE_DIR/out" 2> "$CASE_DIR/err" || RC=$?
OUT=$(cat "$CASE_DIR/out")
ERR=$(cat "$CASE_DIR/err")
if [ "$RC" -ne 0 ]; then pass "refuse: existing TMUX_SHARE_SOCK exits non-zero"; else fail "refuse: existing TMUX_SHARE_SOCK exits non-zero (got 0)"; fi
check_eq "refuse: exit status is 3" "$RC" 3
check_contains "refuse: message names the refusal" "$ERR" 'REFUSING TO RUN'
check_contains "refuse: message names TMUX_SHARE_SOCK" "$ERR" 'TMUX_SHARE_SOCK'
check_eq "refuse: nothing on stdout" "$OUT" ''
check_eq "refuse: dummy file untouched" "$([ -f "$CASE_DIR/dummy.sock" ] && echo present)" present
check_eq "refuse: tmux was never invoked" "$([ -e "$CASE_STATE/sockets" ] && echo invoked || echo never)" never
check_eq "refuse: no scratch directory left" "$(find "$CASE_TMP" -mindepth 1 | wc -l | tr -d ' ')" 0

# The deployment directory existing is normal: tmpfiles creates it at boot, so
# refusing on the directory alone would make the probe useless on the host
# that needs it. A writable existing directory must be allowed.
new_case allow_writable_dir
mkdir -p -- "$CASE_DIR/livedir"
RC=0
env TMPDIR="$CASE_TMP" TMUX_SHARE_DIR="$CASE_DIR/livedir" \
    TMUX_SHARE_SOCK="$CASE_DIR/livedir/tmux.sock" \
    TMUX_SHARE_TMUX="$FAKEWRAP" FAKE_TMUX_STATE="$CASE_STATE" \
    "$SCRIPT" > "$CASE_DIR/out" 2> "$CASE_DIR/err" || RC=$?
ERR=$(cat "$CASE_DIR/err")
if [ "$RC" -ne 3 ]; then pass "allow: a writable existing deployment directory is not refused"; else fail "allow: a writable existing deployment directory is not refused (got 3)"; fi
check_eq "allow: tmux was invoked" "$([ -e "$CASE_STATE/sockets" ] && echo invoked || echo never)" invoked

new_case refuse_dir
mkdir -p -- "$CASE_DIR/livedir"
chmod 0500 -- "$CASE_DIR/livedir"
RC=0
env TMPDIR="$CASE_TMP" TMUX_SHARE_DIR="$CASE_DIR/livedir" \
    TMUX_SHARE_TMUX="$FAKEWRAP" FAKE_TMUX_STATE="$CASE_STATE" \
    "$SCRIPT" > "$CASE_DIR/out" 2> "$CASE_DIR/err" || RC=$?
chmod 0700 -- "$CASE_DIR/livedir"
ERR=$(cat "$CASE_DIR/err")
check_eq "refuse: an unwritable TMUX_SHARE_DIR exits 3" "$RC" 3
check_contains "refuse: message names TMUX_SHARE_DIR" "$ERR" 'TMUX_SHARE_DIR'
check_eq "refuse: tmux was never invoked (dir case)" "$([ -e "$CASE_STATE/sockets" ] && echo invoked || echo never)" never

# ============================================================================
# 4+. failure paths: the exit status must follow the checks, and cleanup must
#     still happen
# ============================================================================
new_case failpipe
EXTRA_ENV=(WRAP_FAIL_PIPE=1)
run_pf "$FAKEWRAP"
check_eq "failpipe: exits 1" "$RC" 1
check_contains "failpipe: pipe-pane-attach FAILs" "$OUT" 'FAIL pipe-pane-attach'
check_contains "failpipe: pipe-pane-detach FAILs" "$OUT" 'FAIL pipe-pane-detach'
check_match "failpipe: summary counts failures" "$OUT" 'PREFLIGHT: [0-9]+ passed, [1-9][0-9]* failed, [0-9]+ warnings'
check_contains "failpipe: each failure explains itself" "$OUT" 'meaning of a failure'
assert_clean "failpipe"
run_pf "$FAKEWRAP" --json
check_eq "failpipe --json: exits 1" "$RC" 1
check_contains "failpipe --json: status fail" "$OUT" '"status":"fail"'
assert_clean "failpipe --json"

new_case nostart
run_pf "$CASE_DIR/does-not-exist"
check_eq "nostart: exits 1 when the tmux cannot start" "$RC" 1
check_contains "nostart: scratch-server FAILs" "$OUT" 'FAIL scratch-server'
check_contains "nostart: later checks are marked not run" "$OUT" 'not run'
check_eq "nostart: temp dir removed" "$(find "$CASE_TMP" -mindepth 1 | wc -l | tr -d ' ')" 0

new_case badpath
RC=0
env TMPDIR="$CASE_TMP" TMUX_SHARE_DIR="$CASE_NODIR" TMUX_SHARE_TMUX='/tmp/a b;tmux' \
    "$SCRIPT" > "$CASE_DIR/out" 2> "$CASE_DIR/err" || RC=$?
ERR=$(cat "$CASE_DIR/err")
check_eq "badpath: unsafe TMUX_SHARE_TMUX exits 2" "$RC" 2
check_contains "badpath: message names the problem" "$ERR" 'invalid tmux program path'

new_case badarg
RC=0
env TMPDIR="$CASE_TMP" TMUX_SHARE_DIR="$CASE_NODIR" TMUX_SHARE_TMUX="$FAKEWRAP" \
    "$SCRIPT" --bogus > "$CASE_DIR/out" 2> "$CASE_DIR/err" || RC=$?
ERR=$(cat "$CASE_DIR/err")
check_eq "badarg: unknown argument exits 2" "$RC" 2
check_contains "badarg: message names the argument" "$ERR" '--bogus'

# ---- summary ------------------------------------------------------------------
printf '\npreflight_test: %d passed, %d failed, %d skipped\n' "$PASSES" "$FAILS" "$SKIPS"
if [ "$FAILS" -eq 0 ]; then
    printf 'PASS\n'
    exit 0
fi
printf 'FAIL\n'
exit 1
