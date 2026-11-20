#!/usr/bin/env bash
# Static assertions for systemd/tmux-share.sysusers and systemd/tmux-share.tmpfiles.
# Needs no root and touches nothing outside a mktemp directory. Parsing is done
# in bash itself, so a missing awk/sed/cmp cannot turn a check into a
# vacuous pass.
set -eu

# Clean environment: a leaked TMUX_SHARE_* variable must not steer this test.
for v in $(env | grep -o '^TMUX_SHARE_[A-Z_]*' || true); do
    unset "$v"
done

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)
sysusers=$repo_root/systemd/tmux-share.sysusers
tmpfiles=$repo_root/systemd/tmux-share.tmpfiles

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
skip=0

ok()  { pass=$((pass + 1)); printf 'PASS  %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; [ -z "${2:-}" ] || printf '      %s\n' "$2"; }
skp() { skip=$((skip + 1)); printf 'SKIP  %s (%s)\n' "$1" "$2"; }

# load_rules FILE: fill RULES with the non-comment, non-blank lines.
RULES=()
load_rules() {
    local line trimmed
    RULES=()
    while IFS= read -r line || [ -n "$line" ]; do
        trimmed=${line#"${line%%[![:space:]]*}"}
        case $trimmed in
            ''|'#'*) continue ;;
        esac
        RULES+=("$line")
    done < "$1"
}

# --- assertions: print a reason on failure and return non-zero, so the same
# code can be pointed at a deliberately broken copy. ----------------------------

assert_fields() {
    local line f rc=0
    load_rules "$1"
    [ "${#RULES[@]}" -gt 0 ] || { printf 'no rules found'; return 1; }
    for line in "${RULES[@]}"; do
        read -r -a f <<< "$line"
        if [ "${#f[@]}" -ne 7 ]; then
            printf 'line has %d fields, want 7: %s\n' "${#f[@]}" "$line"
            rc=1
        fi
    done
    return "$rc"
}

assert_modes_octal() {
    local line f rc=0
    load_rules "$1"
    [ "${#RULES[@]}" -gt 0 ] || { printf 'no rules found'; return 1; }
    for line in "${RULES[@]}"; do
        read -r -a f <<< "$line"
        case ${f[2]:-} in
            [0-7][0-7][0-7][0-7]) ;;
            *) printf 'mode is not 4-digit octal: %s\n' "$line"; rc=1 ;;
        esac
    done
    return "$rc"
}

assert_no_world_bits() {
    local line f rc=0
    load_rules "$1"
    [ "${#RULES[@]}" -gt 0 ] || { printf 'no rules found'; return 1; }
    for line in "${RULES[@]}"; do
        read -r -a f <<< "$line"
        case ${f[2]:-} in
            [0-7][0-7][0-7]0) ;;
            *) printf 'world bits set or mode malformed: %s\n' "$line"; rc=1 ;;
        esac
    done
    return "$rc"
}

# assert_rule FILE TYPE PATH MODE USER GROUP
assert_rule() {
    local line f n=0
    load_rules "$1"
    for line in "${RULES[@]}"; do
        read -r -a f <<< "$line"
        [ "${#f[@]}" -ge 5 ] || continue
        if [ "${f[0]}" = "$2" ] && [ "${f[1]}" = "$3" ] && [ "${f[2]}" = "$4" ] \
            && [ "${f[3]}" = "$5" ] && [ "${f[4]}" = "$6" ]; then
            n=$((n + 1))
        fi
    done
    [ "$n" -eq 1 ] || { printf 'expected exactly one "%s %s %s %s %s" rule, found %d' "$2" "$3" "$4" "$5" "$6" "$n"; return 1; }
}

assert_rule_count() {
    load_rules "$1"
    [ "${#RULES[@]}" -eq "$2" ] || { printf 'expected exactly %d rules, found %d' "$2" "${#RULES[@]}"; return 1; }
}

# The socket check looks at rules only; the header comment explains the
# omission and so must be free to name it.
assert_no_socket_rule() {
    local line rc=0
    load_rules "$1"
    [ "${#RULES[@]}" -gt 0 ] || { printf 'no rules found'; return 1; }
    for line in "${RULES[@]}"; do
        case $line in
            *.sock|*.sock[[:space:]]*|*tmux.sock*) printf 'socket path in a rule: %s\n' "$line"; rc=1 ;;
        esac
    done
    return "$rc"
}

assert_sysusers_group_only() {
    local line f
    load_rules "$1"
    [ "${#RULES[@]}" -eq 1 ] || { printf 'expected exactly one declaration, found %d' "${#RULES[@]}"; return 1; }
    line=${RULES[0]}
    read -r -a f <<< "$line"
    [ "${f[0]}" = g ] && [ "${f[1]:-}" = tmux-share ] \
        || { printf 'the one declaration is not "g tmux-share": %s' "$line"; return 1; }
}

assert_no_user_line() {
    local line f rc=0
    load_rules "$1"
    for line in "${RULES[@]}"; do
        read -r -a f <<< "$line"
        case ${f[0]} in
            u|'u!'|m|r) printf 'account/membership line: %s\n' "$line"; rc=1 ;;
        esac
    done
    return "$rc"
}

assert_documents_usermod() {
    grep -Fq 'usermod -aG tmux-share <reader>' "$1" \
        || { printf 'header does not document the usermod command'; return 1; }
}

# run NAME CMD...: run an assertion, record the result.
run() {
    local name=$1 out rc=0
    shift
    out=$("$@") || rc=$?
    if [ "$rc" -eq 0 ]; then ok "$name"; else bad "$name" "$out"; fi
}

# expect_reject NAME CMD...: the assertion must fail on its (mutated) input.
expect_reject() {
    local name=$1 rc=0
    shift
    "$@" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then ok "$name"; else bad "$name" 'assertion accepted a broken file'; fi
}

# --- the files exist ----------------------------------------------------------
missing=0
[ -f "$sysusers" ] && ok 'sysusers file exists' || { bad 'sysusers file exists' "$sysusers"; missing=1; }
[ -f "$tmpfiles" ] && ok 'tmpfiles file exists' || { bad 'tmpfiles file exists' "$tmpfiles"; missing=1; }
if [ "$missing" -ne 0 ]; then
    printf '\nRESULT: %d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
    exit 1
fi

# --- tmpfiles structure -------------------------------------------------------
run 'tmpfiles: every rule has exactly 7 fields' assert_fields "$tmpfiles"
run 'tmpfiles: every mode is 4-digit octal' assert_modes_octal "$tmpfiles"
run 'tmpfiles: no mode has world bits set' assert_no_world_bits "$tmpfiles"

# --- tmpfiles content ---------------------------------------------------------
run 'tmpfiles: directory is d /run/tmux-share 0710 root:tmux-share' \
    assert_rule "$tmpfiles" d /run/tmux-share 0710 root tmux-share
run 'tmpfiles: transcript is f 0640 root:tmux-share' \
    assert_rule "$tmpfiles" f /run/tmux-share/transcript.log 0640 root tmux-share
run 'tmpfiles: lock is f 0600 root:root' \
    assert_rule "$tmpfiles" f /run/tmux-share.lock 0600 root root
run 'tmpfiles: exactly the three expected rules' assert_rule_count "$tmpfiles" 3
run 'tmpfiles: no rule mentions the socket path' assert_no_socket_rule "$tmpfiles"

# --- sysusers content ---------------------------------------------------------
run 'sysusers: declares only the group tmux-share' assert_sysusers_group_only "$sysusers"
run 'sysusers: no user (u) or membership (m) line' assert_no_user_line "$sysusers"
run 'sysusers: header documents the usermod command' assert_documents_usermod "$sysusers"

# --- systemd's own parsers, when available ------------------------------------
# Absolute paths throughout: the files are passed exactly as located above.
if command -v systemd-sysusers >/dev/null 2>&1; then
    if out=$(systemd-sysusers --dry-run "$sysusers" 2>&1); then
        ok 'systemd-sysusers --dry-run accepts the file'
    else
        bad 'systemd-sysusers --dry-run accepts the file' "$out"
    fi
else
    skp 'systemd-sysusers --dry-run' 'systemd-sysusers not installed'
fi

if command -v systemd-tmpfiles >/dev/null 2>&1; then
    if out=$(systemd-tmpfiles --dry-run --create "$tmpfiles" 2>&1); then
        ok 'systemd-tmpfiles --dry-run --create accepts the file'
    else
        bad 'systemd-tmpfiles --dry-run --create accepts the file' "$out"
    fi
else
    skp 'systemd-tmpfiles --dry-run' 'systemd-tmpfiles not installed'
fi

# --- the test can fail --------------------------------------------------------
# Mutated copies live in the temp dir; each assertion must reject its mutation.
mut=$work/mut
mkdir -p "$mut"

# mutate FILE_IN FILE_OUT OLD NEW: replace one exact line, require it was found.
mutate() {
    local line found=0
    : > "$2"
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$line" = "$3" ]; then
            line=$4
            found=1
        fi
        printf '%s\n' "$line" >> "$2"
    done < "$1"
    [ "$found" -eq 1 ]
}

if mutate "$tmpfiles" "$mut/mode0755" \
    'd /run/tmux-share 0710 root tmux-share - -' 'd /run/tmux-share 0755 root tmux-share - -'; then
    ok 'mutation: 0755 copy was produced from the real directory rule'
else
    bad 'mutation: 0755 copy was produced from the real directory rule' 'directory rule line not found verbatim'
fi
expect_reject 'mutation: 0755 is rejected by the world-bits assertion' \
    assert_no_world_bits "$mut/mode0755"
expect_reject 'mutation: 0755 is rejected by the directory-rule assertion' \
    assert_rule "$mut/mode0755" d /run/tmux-share 0710 root tmux-share

if mutate "$tmpfiles" "$mut/sixfields" \
    'f /run/tmux-share.lock 0600 root root - -' 'f /run/tmux-share.lock 0600 root root -'; then
    ok 'mutation: 6-field copy was produced from the real lock rule'
else
    bad 'mutation: 6-field copy was produced from the real lock rule' 'lock rule line not found verbatim'
fi
expect_reject 'mutation: 6-field line is rejected by the field-count assertion' \
    assert_fields "$mut/sixfields"

if mutate "$tmpfiles" "$mut/socket" \
    'f /run/tmux-share.lock 0600 root root - -' 'f /run/tmux-share/tmux.sock 0666 root root - -'; then
    ok 'mutation: socket-rule copy was produced'
else
    bad 'mutation: socket-rule copy was produced' 'lock rule line not found verbatim'
fi
expect_reject 'mutation: a socket rule is rejected by the socket assertion' \
    assert_no_socket_rule "$mut/socket"

# The original must be unaffected by the mutation run.
run 'mutation: original is untouched and still passes' assert_no_world_bits "$tmpfiles"

# --- summary ------------------------------------------------------------------
printf '\nRESULT: %d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ]
