#!/usr/bin/env bash
# checks.sh: a small assertion library shared by the static verifier
# (tmux-share-verify) and the later self-test, so both report identically.
#
# Source this file; do not execute it:
#
#     source core/lib/checks.sh
#
# USAGE
#     check_begin deploy-dir-mode
#     check_mode  /run/tmux-share 0710
#     check_owner /run/tmux-share root:tmux-share
#     check_summary || exit 1
#
# FUNCTIONS
#   check_begin NAME          open a check; the previous check is closed first
#   check_pass                record a pass for the open check
#   check_fail REASON         record a failure (several are joined with "; ")
#   check_skip REASON         record a skip (the check does not apply here)
#   check_end                 close the open check and print its line
#   check_summary             print "CHECKS: N passed, M failed, K skipped";
#                             return 1 if any check failed, else 0
#   check_mode PATH MODE      mode of PATH equals MODE; MODE may list
#                             alternatives: 0710|0750
#   check_owner PATH USER:GROUP
#   check_exists PATH
#   check_absent PATH
#
# OUTPUT (stdout, one line per closed check)
#     PASS name
#     FAIL name: reason
#     SKIP name: reason
#
# RULES
#   - A check ends with one result. Precedence when a check records several:
#     fail > skip > pass. A check that records nothing is reported as a
#     failure ("no result recorded"), so a forgotten branch cannot pass.
#   - The line is printed when the check is closed (by the next check_begin,
#     check_end or check_summary), because a check may collect several
#     failures first.
#   - The helpers (check_mode, ...) record into the open check. Called with
#     no check open, they open one named "<helper> <path>".
#   - Nothing here returns non-zero except check_summary: a failing check
#     never aborts a "set -eu" script. The last closed result is in
#     CHECK_LAST (pass, fail or skip).
#   - Paths given to the helpers go through validate_log_path first; an
#     invalid path is a failed check, never an argument to stat.
#   - No eval. stat(1) is the GNU one (-c).
#
# State: CHECK_PASSED, CHECK_FAILED, CHECK_SKIPPED, CHECK_LAST and the
# _CHECK_* variables. Sourcing twice keeps the counts.

_CHECKS_DIR=${BASH_SOURCE[0]%/*}
[ "$_CHECKS_DIR" != "${BASH_SOURCE[0]}" ] || _CHECKS_DIR=.

if ! command -v validate_log_path >/dev/null 2>&1; then
    # shellcheck source=validate.sh
    . "$_CHECKS_DIR/validate.sh"
fi

: "${CHECK_PASSED:=0}"
: "${CHECK_FAILED:=0}"
: "${CHECK_SKIPPED:=0}"
CHECK_LAST=''
_CHECK_OPEN=0       # 1 while a check is open
_CHECK_NAME=''
_CHECK_FAIL=''      # joined failure reasons
_CHECK_SKIP=''      # skip reason
_CHECK_HAS_PASS=0

# _check_clean TEXT: one line, no control characters that would split or
# disguise an output line.
_check_clean() {
    local s=$1
    s=${s//$'\n'/ }
    s=${s//$'\r'/ }
    s=${s//$'\t'/ }
    s=${s//$'\033'/?}
    printf '%s' "$s"
}

# check_end: close the open check, print its line, update the counts.
check_end() {
    [ "$_CHECK_OPEN" -eq 1 ] || return 0
    if [ -n "$_CHECK_FAIL" ]; then
        CHECK_FAILED=$((CHECK_FAILED + 1))
        CHECK_LAST=fail
        printf 'FAIL %s: %s\n' "$_CHECK_NAME" "$_CHECK_FAIL"
    elif [ -n "$_CHECK_SKIP" ]; then
        CHECK_SKIPPED=$((CHECK_SKIPPED + 1))
        CHECK_LAST=skip
        printf 'SKIP %s: %s\n' "$_CHECK_NAME" "$_CHECK_SKIP"
    elif [ "$_CHECK_HAS_PASS" -eq 1 ]; then
        CHECK_PASSED=$((CHECK_PASSED + 1))
        CHECK_LAST=pass
        printf 'PASS %s\n' "$_CHECK_NAME"
    else
        CHECK_FAILED=$((CHECK_FAILED + 1))
        CHECK_LAST=fail
        printf 'FAIL %s: no result recorded\n' "$_CHECK_NAME"
    fi
    _CHECK_OPEN=0
    _CHECK_NAME=''
    _CHECK_FAIL=''
    _CHECK_SKIP=''
    _CHECK_HAS_PASS=0
    return 0
}

check_begin() {
    check_end
    _CHECK_NAME=$(_check_clean "${1:-unnamed}")
    _CHECK_OPEN=1
    return 0
}

# _check_ensure NAME: open a check if none is open.
_check_ensure() {
    if [ "$_CHECK_OPEN" -eq 0 ]; then
        check_begin "$1"
    fi
    return 0
}

check_pass() {
    _check_ensure unnamed
    _CHECK_HAS_PASS=1
    return 0
}

check_fail() {
    _check_ensure unnamed
    local reason
    reason=$(_check_clean "${1:-no reason given}")
    if [ -n "$_CHECK_FAIL" ]; then
        _CHECK_FAIL="$_CHECK_FAIL; $reason"
    else
        _CHECK_FAIL=$reason
    fi
    return 0
}

check_skip() {
    _check_ensure unnamed
    if [ -z "$_CHECK_SKIP" ]; then
        _CHECK_SKIP=$(_check_clean "${1:-no reason given}")
    fi
    return 0
}

check_summary() {
    check_end
    printf 'CHECKS: %d passed, %d failed, %d skipped\n' \
        "$CHECK_PASSED" "$CHECK_FAILED" "$CHECK_SKIPPED"
    [ "$CHECK_FAILED" -eq 0 ]
}

# _check_path HELPER PATH: open a check if needed; return 0 if PATH is
# usable. Otherwise record the failure and return 1 (callers use it in an
# "if", so this never aborts a set -e script).
_check_path() {
    _check_ensure "$1 $2"
    if validate_log_path "$2"; then
        return 0
    fi
    check_fail "invalid path: $VALIDATE_REASON"
    return 1
}

# _check_norm_mode OCTAL: strip leading zeros, keep at least one digit.
_check_norm_mode() {
    local m=$1
    while [ "${#m}" -gt 1 ] && [ "${m#0}" != "$m" ]; do
        m=${m#0}
    done
    printf '%s' "$m"
}

check_mode() {
    if [ "$#" -ne 2 ]; then
        _check_ensure check_mode
        check_fail 'check_mode needs PATH and EXPECTED_MODE'
        return 0
    fi
    local path=$1 expected=$2 actual alt
    if _check_path check_mode "$path"; then
        case $expected in
            ''|*[!0-7\|]*|\|*|*\||*\|\|*)
                check_fail "bad expected mode '$expected'"
                return 0
                ;;
        esac
        if ! actual=$(stat -c '%a' -- "$path" 2>/dev/null); then
            check_fail "cannot stat $path"
            return 0
        fi
        local IFS='|'
        # shellcheck disable=SC2086  # splitting on | is the point
        set -- $expected
        for alt in "$@"; do
            if [ "$(_check_norm_mode "$alt")" = "$actual" ]; then
                check_pass
                return 0
            fi
        done
        check_fail "mode of $path is $actual, expected $expected"
    fi
    return 0
}

check_owner() {
    if [ "$#" -ne 2 ]; then
        _check_ensure check_owner
        check_fail 'check_owner needs PATH and USER:GROUP'
        return 0
    fi
    local path=$1 expected=$2 actual
    if _check_path check_owner "$path"; then
        case $expected in
            ?*:?*) ;;
            *)
                check_fail "bad expected owner '$expected' (want USER:GROUP)"
                return 0
                ;;
        esac
        if ! actual=$(stat -c '%U:%G' -- "$path" 2>/dev/null); then
            check_fail "cannot stat $path"
            return 0
        fi
        if [ "$actual" = "$expected" ]; then
            check_pass
        else
            check_fail "owner of $path is $actual, expected $expected"
        fi
    fi
    return 0
}

check_exists() {
    if [ "$#" -ne 1 ]; then
        _check_ensure check_exists
        check_fail 'check_exists needs PATH'
        return 0
    fi
    if _check_path check_exists "$1"; then
        if [ -e "$1" ] || [ -L "$1" ]; then
            check_pass
        else
            check_fail "$1 does not exist"
        fi
    fi
    return 0
}

check_absent() {
    if [ "$#" -ne 1 ]; then
        _check_ensure check_absent
        check_fail 'check_absent needs PATH'
        return 0
    fi
    if _check_path check_absent "$1"; then
        if [ -e "$1" ] || [ -L "$1" ]; then
            check_fail "$1 exists but must not"
        else
            check_pass
        fi
    fi
    return 0
}
