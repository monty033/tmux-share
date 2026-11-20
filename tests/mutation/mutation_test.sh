#!/usr/bin/env bash
# Mutation: the suites must be able to fail. Each case applies one deliberate
# defect to one file, runs only the suite named for it, and requires that
# suite to report a FAIL. A suite that still passes with the defect in place
# is not testing that property: the case fails with "no suite caught this".
#
# Each case is bracketed. The suite must pass on the untouched tree first,
# otherwise a FAIL would prove nothing. The file is copied to a temp backup,
# the change is applied with python3, and the file is restored from the copy
# on the way out, whatever happens. The restored file's sha256 and mode must
# equal the values taken before the change, or the run fails and keeps the
# scratch directory for manual recovery.
#
# The tree must be clean when the run starts, and it is checked again at the
# end: any tracked change left behind is printed and fails the run.
#
# Scratch files live in a mktemp directory under TMPDIR, as the other suites
# do. Nothing else is written.
#
# Exit status: 0 every mutation was caught; 1 otherwise.
set -u

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)

# The suites read TMUX_SHARE_* variables; an inherited value from a live
# deployment would make them test the wrong thing.
for v in $(env | grep -o '^TMUX_SHARE_[A-Z_]*' || true); do unset "$v"; done

# A stock NixOS login may not have the usual PATH; git, python3 and the
# coreutils live there.
case ":$PATH:" in
    *:/run/current-system/sw/bin:*) ;;
    *) [ -d /run/current-system/sw/bin ] && PATH="/run/current-system/sw/bin:$PATH" ;;
esac
export PATH

# shellcheck source=../../core/lib/checks.sh
. "$repo_root/core/lib/checks.sh"

cd -- "$repo_root" || exit 1

# Refuse to start on a dirty tree: the final diff check could not tell our
# changes from someone else's.
if ! git diff --quiet; then
    echo 'mutation: refusing to start, tracked files already differ:' >&2
    git diff --stat >&2
    exit 1
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/mutation-test.XXXXXX") || exit 1
restore_bad=0

# active_* describe the one file that is mutated right now, if any.
active_target=''
active_backup=''
active_mode=''
active_sha=''

cleanup() {
    restore_active
    if [ "$restore_bad" -eq 0 ]; then
        rm -rf -- "$work"
    else
        echo "mutation: scratch kept for manual recovery: $work" >&2
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# The edit helper is written once, outside the repository, with a quoted
# heredoc so nothing in it is expanded by the shell.
cat > "$work/edit.py" <<'PY'
# Replace the one occurrence of OLD in FILE with NEW. The anchor must match
# exactly once, so a mutation can never land somewhere else silently.
import sys

path, old, new = sys.argv[1:4]
with open(path, encoding="utf-8") as f:
    text = f.read()
count = text.count(old)
if count != 1:
    sys.exit(f"anchor matches {count} times in {path}, need exactly 1")
with open(path, "w", encoding="utf-8") as f:
    f.write(text.replace(old, new, 1))
PY

sha256_of() {
    sha256sum -- "$1" | cut -d' ' -f1
}

# edit_file FILE OLD NEW: the mutator for text changes.
edit_file() {
    python3 -I "$work/edit.py" "$1" "$2" "$3"
}

# drop_exec_bit FILE: the mutator for a mode change.
drop_exec_bit() {
    chmod a-x -- "$1"
}

# restore_active: copy the backup back, restore the mode, and verify the
# sha256 and mode. Returns 1 if either does not match the original.
restore_active() {
    local target=$active_target status=0 now mode
    [ -n "$target" ] || return 0
    active_target=''
    cp -- "$active_backup" "$target" || status=1
    chmod "$active_mode" -- "$target" || status=1
    now=$(sha256_of "$target" 2>/dev/null)
    mode=$(stat -c '%a' -- "$target" 2>/dev/null)
    if [ "$status" -ne 0 ] || [ "$now" != "$active_sha" ] || [ "$mode" != "$active_mode" ]; then
        restore_bad=1
        printf 'mutation: RESTORE FAILED for %s: sha256 %s (want %s), mode %s (want %s); original at %s\n' \
            "$target" "$now" "$active_sha" "$mode" "$active_mode" "$active_backup" >&2
        return 1
    fi
    return 0
}

# run_suite SUITE: run one named suite from the repository root. Sets
# SUITE_RC and SUITE_OUT.
run_suite() {
    SUITE_OUT=$(bash "$repo_root/$1" 2>&1)
    SUITE_RC=$?
}

# mutate_case LABEL SUITE FILE MUTATOR [ARG...]: one mutation, judged by the
# one suite named for it.
mutate_case() {
    local label=$1 suite=$2 rel=$3 mutator=$4 backup sha mode rc out why
    shift 4
    local target=$repo_root/$rel
    check_begin "mutation: $label"

    if [ ! -f "$target" ] || [ ! -f "$repo_root/$suite" ]; then
        check_fail "missing $rel or $suite"
        return 0
    fi

    run_suite "$suite"
    if [ "$SUITE_RC" -ne 0 ]; then
        check_fail "baseline: $suite fails on the untouched tree (exit $SUITE_RC)"
        return 0
    fi

    backup=$(mktemp "$work/backup.XXXXXX")
    if ! cp -p -- "$target" "$backup"; then
        check_fail "cannot back up $rel"
        return 0
    fi
    sha=$(sha256_of "$target")
    mode=$(stat -c '%a' -- "$target")
    active_target=$target
    active_backup=$backup
    active_mode=$mode
    active_sha=$sha

    if ! "$mutator" "$target" "$@" 2> "$work/apply.err"; then
        why=$(head -c 200 "$work/apply.err" | tr '\n' ' ')
        restore_active
        check_fail "could not apply the change: ${why:-unknown error}"
        return 0
    fi

    run_suite "$suite"
    rc=$SUITE_RC
    out=$SUITE_OUT
    if ! restore_active; then
        check_fail "restore did not verify, see the RESTORE FAILED line"
        return 0
    fi

    if [ "$rc" -eq 0 ]; then
        check_fail "no suite caught this: $suite exited 0 with the defect in place"
    elif printf '%s\n' "$out" | grep -q 'FAIL'; then
        check_pass
    else
        check_fail "inconclusive: $suite exited $rc without a FAIL line, not counted as caught"
    fi
    return 0
}

mutate_case 'watchdog: pipe-pane -o re-added is caught' \
    tests/unit/watchdog_test.sh core/bin/tmux-share-watchdog edit_file \
    'pipe-pane -t "$pane" "$cmd"' 'pipe-pane -o -t "$pane" "$cmd"'

mutate_case 'server unit: ExecStartPost loses its leading -' \
    tests/systemd/units_test.sh systemd/tmux-share-server.service edit_file \
    'ExecStartPost=-/usr/local/bin/tmux-share-tap-start' \
    'ExecStartPost=/usr/local/bin/tmux-share-tap-start'

mutate_case 'tmpfiles: runtime dir 0710 widened to 0755' \
    tests/systemd/sysusers_tmpfiles_test.sh systemd/tmux-share.tmpfiles edit_file \
    'd /run/tmux-share 0710 root tmux-share' 'd /run/tmux-share 0755 root tmux-share'

mutate_case 'timer: AccuracySec=1s dropped' \
    tests/systemd/units_test.sh systemd/tmux-share-tap.timer edit_file \
    $'AccuracySec=1s\n' ''

mutate_case "validate: '..' path segment accepted" \
    tests/unit/validate_test.sh core/lib/validate.sh edit_file \
    "_validate_fail \"contains a '..' path segment\"" ':'

mutate_case 'watchdog: list-panes loses its timeout wrapper' \
    tests/unit/verify_test.sh core/bin/tmux-share-watchdog edit_file \
    'panes=$(tmux_bounded list-panes' 'panes=$("$TMUX" -S "$SOCK" list-panes'

mutate_case 'verify: execute bit removed' \
    tests/unit/modes_test.sh core/bin/tmux-share-verify drop_exec_bit

check_summary
summary=$?

if ! git diff --quiet; then
    echo 'mutation: tracked files differ after the run:'
    git diff
    exit 1
fi
echo 'tree: clean (git diff --quiet)'
exit "$summary"
