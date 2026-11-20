#!/usr/bin/env bash
# validate.sh: input validators for values that end up in a shell command.
#
# Source this file; do not execute it:
#
#     source core/lib/validate.sh
#
# WHY THIS EXISTS
#   A root-run command string is assembled by shell from a session name, a
#   pane id and a log path. A crafted value (a ';', a quote, a backtick, a
#   "$(...)" or a newline) injects a command into that root shell.
#
# THE RULE
#   Reject before use. A value that fails validation must NEVER reach a
#   command string, a log line that is later re-parsed, or any other place a
#   shell will read it. Validate first, build the string second:
#
#       validate_session_name "$S" || die "bad session name"
#       validate_token        "$P" || die "bad pane id"
#       validate_log_path     "$L" || die "bad log path"
#
#   Escaping or quoting a rejected value is not an acceptable substitute.
#
# FUNCTIONS (each takes exactly one argument)
#   validate_session_name VALUE
#       tmux session name. Must match ^[A-Za-z0-9][A-Za-z0-9_-]*$ and be
#       1..64 characters.
#   validate_token VALUE
#       A single word to embed in a shell command, such as a pane id (%3) or
#       a program path. Must match ^[%A-Za-z0-9_./-]+$ and be 1..64
#       characters. Note this alphabet allows a leading '-' and '..'; a
#       caller that passes the value to a program as an argument is
#       responsible for placing it after '--' where that matters.
#   validate_log_path VALUE
#       Absolute path. Must start with '/', be 1..64 characters, contain no
#       '..' path segment, and use only the characters [A-Za-z0-9_./-]. That
#       allowlist is deliberately stricter than the required reject list
#       (whitespace, quotes, backtick, '$', ';', '&', '|', '<', '>', newline,
#       NUL): it also excludes '\', '*', '?', '#', '~', '(', ')', '{', '}',
#       '!' and every non-ASCII byte.
#   validate_reason
#       Prints a fixed reason string for the most recent validator call made
#       in the current shell, or nothing if that call succeeded. Call it in
#       the same shell as the validator, not inside "$( ... )" around it.
#
# CONTRACT
#   - Return 0 for a valid value, 1 for an invalid one. Never write to
#     stdout or stderr; only validate_reason prints, and only on request.
#   - Safe to source into "set -eu" scripts. As with any function, a bare
#     failing call aborts under "set -e"; use it in an "if" or with "||".
#   - No eval, no word splitting, no globbing of the value, no external
#     commands. Character classes are spelled out so the result does not
#     depend on the locale's collation order.
#   - A NUL byte cannot be held in a bash variable, so it cannot reach these
#     functions; bash drops it when the value is formed. Reading input from
#     a file is the caller's job and must reject NUL before this point.
#
# State: the library sets VALIDATE_REASON and the _VALIDATE_* alphabets.

_VALIDATE_ALPHA='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'
_VALIDATE_ALNUM="${_VALIDATE_ALPHA}0123456789"
_VALIDATE_MAXLEN=64
# Paths are not names: 64 characters is a sane bound for an identifier but
# not for a real path, and a caller's log file may sit anywhere. 4096 is
# PATH_MAX on Linux; the character rules below still forbid anything a shell
# would interpret.
_VALIDATE_MAXPATH=4096
VALIDATE_REASON=''

# _validate_fail REASON: record the reason and return failure.
_validate_fail() {
    VALIDATE_REASON=$1
    return 1
}

# _validate_length VALUE: shared 1..64 check.
_validate_length() {
    if [ "${#1}" -lt 1 ]; then
        _validate_fail 'empty value'
        return
    fi
    if [ "${#1}" -gt "$_VALIDATE_MAXLEN" ]; then
        _validate_fail 'longer than 64 characters'
        return
    fi
    return 0
}

validate_session_name() {
    VALIDATE_REASON=''
    if [ "$#" -ne 1 ]; then
        _validate_fail 'expected exactly one argument'
        return
    fi
    _validate_length "$1" || return 1
    case $1 in
        [!"$_VALIDATE_ALNUM"]*)
            _validate_fail 'must start with a letter or digit'
            return
            ;;
        *[!"$_VALIDATE_ALNUM"_-]*)
            _validate_fail 'contains a character outside A-Z a-z 0-9 _ -'
            return
            ;;
    esac
    return 0
}

validate_token() {
    VALIDATE_REASON=''
    if [ "$#" -ne 1 ]; then
        _validate_fail 'expected exactly one argument'
        return
    fi
    _validate_length "$1" || return 1
    case $1 in
        *[!"$_VALIDATE_ALNUM"%_./-]*)
            _validate_fail 'contains a character outside A-Z a-z 0-9 % _ . / -'
            return
            ;;
    esac
    return 0
}

validate_log_path() {
    VALIDATE_REASON=''
    if [ "$#" -ne 1 ]; then
        _validate_fail 'expected exactly one argument'
        return
    fi
    if [ "${#1}" -lt 1 ]; then
        _validate_fail 'empty value'
        return
    fi
    if [ "${#1}" -gt "$_VALIDATE_MAXPATH" ]; then
        _validate_fail "longer than $_VALIDATE_MAXPATH characters"
        return
    fi
    case $1 in
        /*) ;;
        *)
            _validate_fail 'not an absolute path'
            return
            ;;
    esac
    case $1 in
        *[!"$_VALIDATE_ALNUM"_./-]*)
            _validate_fail 'contains a character outside A-Z a-z 0-9 _ . / -'
            return
            ;;
    esac
    # A trailing slash is appended so '..' is caught as the last segment too.
    case "$1/" in
        */../*)
            _validate_fail "contains a '..' path segment"
            return
            ;;
    esac
    return 0
}

# validate_exec_path VALUE: a program to execute, given either as an absolute
# path (validated like a log path) or as a bare command name resolved through
# PATH. Program paths are paths, so they get the PATH_MAX bound rather than
# the identifier bound; without this, a deployment under a long prefix cannot
# start at all.
validate_exec_path() {
    VALIDATE_REASON=''
    if [ "$#" -ne 1 ]; then
        _validate_fail 'expected exactly one argument'
        return
    fi
    if [ "${#1}" -lt 1 ]; then
        _validate_fail 'empty value'
        return
    fi
    case $1 in
        */*)
            validate_log_path "$1"
            return $?
            ;;
    esac
    if [ "${#1}" -gt "$_VALIDATE_MAXLEN" ]; then
        _validate_fail "longer than $_VALIDATE_MAXLEN characters"
        return
    fi
    case $1 in
        [!A-Za-z0-9]*)
            _validate_fail 'must start with a letter or digit'
            return
            ;;
        *[!A-Za-z0-9._-]*)
            _validate_fail 'contains a character outside A-Z a-z 0-9 _ . -'
            return
            ;;
    esac
    return 0
}

validate_reason() {
    if [ -n "$VALIDATE_REASON" ]; then
        printf '%s\n' "$VALIDATE_REASON"
    fi
    return 0
}
