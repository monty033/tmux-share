#!/usr/bin/env bash
# Acceptance test for tests/stubs/fake-tmux.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
FAKE=$HERE/fake-tmux

STATE=$(mktemp -d "${TMPDIR:-/tmp}/fake-tmux-test.XXXXXX")
trap 'rm -rf -- "$STATE"' EXIT
export FAKE_TMUX_STATE=$STATE

check() {
    local desc=$1 actual=$2 expected=$3
    if [ "$actual" != "$expected" ]; then
        printf 'FAIL [%s]: expected <%s> but got <%s>\n' "$desc" "$expected" "$actual" >&2
        exit 1
    fi
    printf 'ok [%s]\n' "$desc"
}

get_pipe() {
    local pane=$1 p v
    while IFS=$'\t' read -r p v; do
        if [ "$p" = "$pane" ]; then printf '%s' "$v"; return 0; fi
    done < "$STATE/state"
    printf 'MISSING'
}

get_cmd() {
    local pane=$1 p c
    while IFS=$'\t' read -r p c; do
        if [ "$p" = "$pane" ]; then printf '%s' "$c"; return 0; fi
    done < "$STATE/commands"
    printf 'MISSING'
}

reset_state() {
    printf '%s\t%s\n' '%0' '0' > "$STATE/state"
    printf '%s\t%s\n' '%1' '1' >> "$STATE/state"
}

printf '%s\n' work > "$STATE/sessions"
reset_state

# 1. list-panes reflects the state file.
out=$("$FAKE" list-panes -s -t work -F '#{pane_id} #{pane_pipe}')
check "list-panes reflects state file" "$out" $'%0 0\n%1 1'

# 1b. It also follows edits made directly to the state file.
printf '%s\t%s\n' '%0' '1' > "$STATE/state"
printf '%s\t%s\n' '%1' '0' >> "$STATE/state"
out=$("$FAKE" list-panes -s -t work -F '#{pane_id} #{pane_pipe}')
check "list-panes follows direct state edits" "$out" $'%0 1\n%1 0'
reset_state

# 2. pipe-pane with a command sets pipe=1 and records the command; without a
#    command it sets pipe=0.
"$FAKE" pipe-pane -t %0 'cat >/dev/null'
check "pipe-pane CMD sets pipe=1" "$(get_pipe %0)" "1"
check "pipe-pane CMD records the command" "$(get_cmd %0)" "cat >/dev/null"
"$FAKE" pipe-pane -t %0
check "pipe-pane with no CMD sets pipe=0" "$(get_pipe %0)" "0"

# 3. -o toggles; two toggles must return to the original state (the trap).
original=$(get_pipe %1)
"$FAKE" pipe-pane -o -t %1 'cat >/dev/null'
check "-o first toggle flips the pipe" "$(get_pipe %1)" "0"
"$FAKE" pipe-pane -o -t %1 'cat >/dev/null'
check "-o second toggle restores original state" "$(get_pipe %1)" "$original"

# 4. Fault injection: rc and stderr come back verbatim.
if err=$(FAKE_TMUX_RC=17 FAKE_TMUX_STDERR='injected boom' \
        "$FAKE" list-panes -s -t work -F 'x' 2>&1 >/dev/null); then
    injected_rc=0
else
    injected_rc=$?
fi
check "injected rc is returned verbatim" "$injected_rc" "17"
check "injected stderr is verbatim" "$err" "injected boom"

# 5. Hang mode: a wedged server is killed by timeout with status 124.
if timeout 5 env FAKE_TMUX_SLEEP=30 \
        "$FAKE" list-panes -s -t work -F 'x' >/dev/null 2>&1; then
    hang_rc=0
else
    hang_rc=$?
fi
check "hang mode killed by timeout reports 124" "$hang_rc" "124"

# 6. Every call is in calls.log, in order (including the killed one).
order=""
while IFS=$'\t' read -r _rc _args _state; do
    if [ -n "$order" ]; then order+="|"; fi
    order+="$_args"
done < "$STATE/calls.log"
expected_order='list-panes -s -t work -F #{pane_id} #{pane_pipe}|list-panes -s -t work -F #{pane_id} #{pane_pipe}|pipe-pane -t %0 cat >/dev/null|pipe-pane -t %0|pipe-pane -o -t %1 cat >/dev/null|pipe-pane -o -t %1 cat >/dev/null|list-panes -s -t work -F x|list-panes -s -t work -F x'
check "calls.log contains every call in order" "$order" "$expected_order"
n=$(grep -c '' "$STATE/calls.log")
check "calls.log has one line per call" "$n" "8"

printf 'PASS: all fake-tmux acceptance checks passed\n'
exit 0
