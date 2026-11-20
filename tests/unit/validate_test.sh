#!/usr/bin/env bash
# Acceptance test for core/lib/validate.sh. Run from anywhere:
#   bash tests/unit/validate_test.sh
# Exits 0 only if every case passed. Creates no files.
set -eu

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/../.." && pwd)

# shellcheck source=../../core/lib/validate.sh
source "${repo_root}/core/lib/validate.sh"

passed=0
failed=0

ok() {
    passed=$((passed + 1))
    printf 'ok   %s\n' "$1"
}

bad() {
    failed=$((failed + 1))
    printf 'FAIL %s\n' "$1"
}

# expect_accept FUNCTION NAME VALUE
expect_accept() {
    if "$1" "$3"; then
        ok "$1 accepts $2"
    else
        bad "$1 accepts $2"
    fi
}

# expect_reject FUNCTION NAME VALUE
expect_reject() {
    if "$1" "$3"; then
        bad "$1 rejects $2"
    else
        ok "$1 rejects $2"
    fi
}

# Fake values only. Built with printf so the special characters are explicit.
nl=$'\n'
bt='`'
dq='"'
sq="'"
long65=$(printf 'a%.0s' $(seq 1 65))
long64=$(printf 'a%.0s' $(seq 1 64))
path64="/$(printf 'a%.0s' $(seq 1 63))"
path65="/$(printf 'a%.0s' $(seq 1 64))"

# ---- accepts ---------------------------------------------------------------
expect_accept validate_session_name 'admin' 'admin'
expect_accept validate_session_name 'tmux-hermes' 'tmux-hermes'
expect_accept validate_token 'pane id %3' '%3'
expect_accept validate_token 'pane id %12' '%12'
expect_accept validate_log_path '/run/tmux-share/admin.log' '/run/tmux-share/admin.log'

# Boundaries.
expect_accept validate_session_name '64 characters' "$long64"
expect_accept validate_token '64 characters' "$long64"
expect_accept validate_log_path '64 characters' "$path64"
expect_accept validate_log_path 'a name containing dots but no .. segment' '/run/a..b/x.log'

# ---- rejects: every validator ----------------------------------------------
# Each bad value is a known-good base with one hostile character spliced in, so
# a rejection can only be explained by that character.
for spec in 'validate_session_name:ab' 'validate_token:ab' 'validate_log_path:/run/ab'; do
    fn=${spec%%:*}
    base=${spec#*:}
    expect_accept "$fn" "the base value $base" "$base"
    expect_reject "$fn" 'a value with a space' "${base} x"
    expect_reject "$fn" 'a value containing ;' "${base};id"
    expect_reject "$fn" 'a value containing $(...)' "${base}"'$(id)'
    expect_reject "$fn" 'a value containing ${...}' "${base}"'${IFS}'
    expect_reject "$fn" 'a value with a backtick' "${base}${bt}id${bt}"
    expect_reject "$fn" 'a value with a double quote' "${base}${dq}x"
    expect_reject "$fn" 'a value with a single quote' "${base}${sq}x"
    expect_reject "$fn" 'a value containing a newline' "${base}${nl}x"
    expect_reject "$fn" 'a value with a trailing newline' "${base}${nl}"
    expect_reject "$fn" 'a value with a leading newline' "${nl}${base}"
    expect_reject "$fn" 'a value containing &' "${base}&x"
    expect_reject "$fn" 'a value containing |' "${base}|x"
    expect_reject "$fn" 'a value containing <' "${base}<x"
    expect_reject "$fn" 'a value containing >' "${base}>x"
    expect_reject "$fn" 'a value containing a backslash' "${base}"'\x'
    expect_reject "$fn" 'a value containing a tab' "${base}"$'\t'"x"
    expect_reject "$fn" 'a value containing a non-ASCII byte' "${base}"$'\xc3\xa9'
    expect_reject "$fn" 'an empty value' ''
    expect_reject "$fn" 'a 65-character value' "$long65"
done

# ---- rejects: rules specific to one validator ------------------------------
expect_reject validate_session_name 'a value containing ..' 'a..b'
expect_reject validate_session_name 'a leading dash' '-admin'
expect_reject validate_session_name 'a leading underscore' '_admin'
expect_reject validate_session_name 'a path separator' 'a/b'
expect_reject validate_session_name 'a percent sign' '%3'

expect_reject validate_token 'a value containing #' '#3'
expect_reject validate_token 'a value containing *' '/run/*'

expect_reject validate_log_path 'a value containing ..' '/run/tmux-share/../etc/x.log'
expect_reject validate_log_path 'a leading .. segment' '/../x.log'
expect_reject validate_log_path 'a trailing .. segment' '/run/tmux-share/..'
expect_reject validate_log_path 'a relative path' 'run/tmux-share/x.log'
expect_reject validate_log_path 'a dot-relative path' './x.log'
# Paths are bounded by PATH_MAX, not by the identifier limit: a real log
# path can legitimately exceed 64 characters, and the character rules are
# what make it safe.
long_path="/run/$(printf 'x%.0s' $(seq 1 200))/transcript.log"
expect_accept validate_log_path 'a 200-character path' "$long_path"
huge_path="/run/$(printf 'y%.0s' $(seq 1 4096)).log"
expect_reject validate_log_path 'a path beyond PATH_MAX' "$huge_path"
expect_reject validate_log_path 'a value containing *' '/run/*.log'

# ---- arity -----------------------------------------------------------------
if validate_session_name; then bad 'validate_session_name rejects zero arguments'
else ok 'validate_session_name rejects zero arguments'; fi
if validate_token a b; then bad 'validate_token rejects two arguments'
else ok 'validate_token rejects two arguments'; fi

# ---- quiet: validators write nothing on stdout or stderr -------------------
for spec in 'validate_session_name:admin' 'validate_token:%3' 'validate_log_path:/run/tmux-share/admin.log'; do
    fn=${spec%%:*}
    good=${spec#*:}
    # Confirm the "valid" and "invalid" calls really are, so quiet means quiet.
    if "$fn" "$good"; then ok "$fn: the valid sample is accepted"
    else bad "$fn: the valid sample is accepted"; fi
    if "$fn" "${good};id${nl}x"; then bad "$fn: the invalid sample is rejected"
    else ok "$fn: the invalid sample is rejected"; fi
    out_valid=$("$fn" "$good" 2>&1 || true)
    out_bad=$("$fn" "${good};id${nl}x" 2>&1 || true)
    if [ -z "$out_valid" ]; then ok "$fn is quiet on a valid call"
    else bad "$fn is quiet on a valid call"; fi
    if [ -z "$out_bad" ]; then ok "$fn is quiet on an invalid call"
    else bad "$fn is quiet on an invalid call"; fi
done

# ---- reason helper ---------------------------------------------------------
validate_log_path 'relative.log' || true
if [ -n "$(validate_reason)" ]; then ok 'validate_reason explains a rejection'
else bad 'validate_reason explains a rejection'; fi
validate_log_path '/run/x.log' || true
if [ -z "$(validate_reason)" ]; then ok 'validate_reason is empty after a success'
else bad 'validate_reason is empty after a success'; fi

# ---- summary ---------------------------------------------------------------
total=$((passed + failed))
if [ "$failed" -eq 0 ]; then
    printf 'PASS: %d/%d cases passed\n' "$passed" "$total"
    exit 0
fi
printf 'FAIL: %d of %d cases failed\n' "$failed" "$total"
exit 1
