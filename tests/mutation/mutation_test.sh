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
# The tree does not have to be clean when the run starts. This suite exists to
# prove that the checks can fail, and it is run against a tree that holds the
# change it is testing; a change that is not committed yet is the normal case
# for it. What the run must guarantee is that it leaves the tree as it found
# it: the state of every tracked file is taken before the first mutation and
# compared with the state after the last one, and any difference fails the run.
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

# tree_state: one digest of every tracked file's content and mode. The run
# must not change any of them, so the state before the first mutation and the
# state after the last one have to be the same.
tree_state() {
    git ls-files -z | while IFS= read -r -d '' f; do
        if [ -e "$f" ]; then
            printf '%s %s %s\n' "$f" "$(sha256_of "$f")" "$(stat -c '%a' -- "$f")"
        else
            printf '%s MISSING\n' "$f"
        fi
    done | sha256sum | cut -d' ' -f1
}

# The state the tree is in before anything is mutated.
start_state=$(tree_state)

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

# ---- any-user: the guards that keep a non-root account from being root in disguise
# Each one is a way the `user` option could silently stop doing its job.

mutate_case 'module: User=root emitted for the default account' \
    tests/nix/module_test.sh nix/module.nix edit_file \
    'runAs = optionalAttrs (cfg.user != "root") { User = cfg.user; };' \
    'runAs = { User = cfg.user; };'

mutate_case 'module: lock group is named after the account, not its primary group' \
    tests/nix/module_test.sh nix/module.nix edit_file \
    '"f ${lock} 0600 ${cfg.user} ${userGroup} - -"' \
    '"f ${lock} 0600 ${cfg.user} ${cfg.user} - -"'

mutate_case 'module: an account not declared in users.users is accepted' \
    tests/nix/module_test.sh nix/module.nix edit_file \
    'assertion = cfg.user == "root" || builtins.hasAttr cfg.user config.users.users;' \
    'assertion = true;'

mutate_case 'module: an account with no primary group is accepted' \
    tests/nix/module_test.sh nix/module.nix edit_file \
    'assertion = userGroup != "";' 'assertion = true;'

mutate_case 'module: user equal to readerUser accepted' \
    tests/nix/module_test.sh nix/module.nix edit_file \
    'assertion = cfg.readerUser == null || cfg.user != cfg.readerUser;' \
    'assertion = true;'

mutate_case 'module: transcript stays root-owned for another account' \
    tests/parity/parity_test.sh nix/module.nix edit_file \
    '"f ${transcript} 0640 ${cfg.user} ${cfg.readerGroup} - -"' \
    '"f ${transcript} 0640 root ${cfg.readerGroup} - -"'

mutate_case 'attach: the gate is removed' \
    tests/unit/attach_test.sh core/bin/tmux-share edit_file \
    'if [ "$check" -eq 0 ] && [ "$EUID" -ne 0 ]; then' 'if false; then'

mutate_case 'attach: the gate reads TMUX_SHARE_DIR, which a caller can set' \
    tests/unit/attach_test.sh core/bin/tmux-share edit_file \
    'rundir=${TMUX_SHARE_SOCK%/*}' 'rundir=${TMUX_SHARE_DIR:-${TMUX_SHARE_SOCK%/*}}'

mutate_case 'attach: the gate asks id on PATH instead of the kernel' \
    tests/unit/attach_test.sh core/bin/tmux-share edit_file \
    '[ -O "$rundir" ]' '[ "$(id -u)" = "$(stat -c %u -- "$rundir")" ]'

mutate_case 'verify: expected owner is root whatever the user' \
    tests/unit/verify_test.sh core/bin/tmux-share-verify edit_file \
    '    SOCK_OWNER=$USER_NAME:$(id -gn' '    SOCK_OWNER=root:root; : $(id -gn'

mutate_case 'verify: the lock is judged against a group named like the account' \
    tests/unit/verify_test.sh core/bin/tmux-share-verify edit_file \
    '    OWNER=$SOCK_OWNER' '    OWNER=$USER_NAME:$USER_NAME'

mutate_case 'verify: the directory owner check ignores the user' \
    tests/unit/verify_test.sh core/bin/tmux-share-verify edit_file \
    'check_owner "$DIR" "$OWNER_USER:$GROUP"' 'check_owner "$DIR" "root:$GROUP"'

mutate_case 'render: TMUX_SHARE_USER is not validated' \
    tests/unit/render_test.sh core/bin/tmux-share-render edit_file \
    '[!"$_VALIDATE_ALNUM"_]* | *[!"$_VALIDATE_ALNUM"_.-]*)' "'')"

mutate_case 'selftest: the scratch tree is judged against root' \
    tests/unit/selftest_test.sh core/bin/tmux-share-selftest edit_file \
    'OWNER=$(id -un):$GROUP' 'OWNER=root:$GROUP'

mutate_case 'install: an unknown --user account is accepted' \
    tests/install/install_test.sh install.sh edit_file \
    'if [ "$user" != root ] && ! getent passwd "$user" >/dev/null 2>&1; then' 'if false; then'

mutate_case 'install: --user equal to the reader account is accepted' \
    tests/install/install_test.sh install.sh edit_file \
    'if [ -n "${TMUX_SHARE_READER:-}" ] && [ "$user" = "$TMUX_SHARE_READER" ]; then' 'if false; then'

mutate_case 'install: --user name is not checked for characters' \
    tests/install/install_test.sh install.sh edit_file \
    "'' | [!A-Za-z0-9_]* | *[!A-Za-z0-9_.-]*)
        die \"invalid --user" "'')
        die \"invalid --user"

mutate_case 'install: the lock rule keeps group root' \
    tests/install/install_test.sh install.sh edit_file \
    'if ($5 == "root") $5 = g;' ''

mutate_case 'install: an unresolvable primary group is accepted' \
    tests/install/install_test.sh install.sh edit_file \
    "        '' | [!A-Za-z0-9_]* | *[!A-Za-z0-9_.-]*)
            die \"cannot determine" \
    "        zzz)
            die \"cannot determine"

mutate_case 'install: the lock group is named after the account'  \
    tests/install/install_test.sh install.sh edit_file \
    'awk -v u="$user" -v g="$user_group"' 'awk -v u="$user" -v g="$user"'

mutate_case 'install: services get User=root whatever --user says' \
    tests/install/install_test.sh install.sh edit_file \
    'print "User=" u' 'print "User=root"'

mutate_case 'install: an inherited TMUX_SHARE_USER reaches the env file' \
    tests/install/install_test.sh install.sh edit_file \
    'export TMUX_SHARE_USER=$user' ':'

# ---- the five options the module gained -------------------------------------
# Each one names a value that reaches a systemd unit or a tmux command, so
# each one is a way for a name, a PATH or an account to be wrong.

mutate_case 'module: the unit prefix is ignored' \
    tests/nix/module_test.sh nix/module.nix edit_file \
    'systemd.services."${cfg.unitPrefix}-server" = {' \
    'systemd.services."tmux-share-server" = {'

mutate_case 'module: an invalid unit prefix is accepted' \
    tests/nix/module_test.sh nix/module.nix edit_file \
    'assertion = matches nameRe cfg.unitPrefix;' \
    'assertion = true;'

mutate_case 'module: a PATH entry carrying a semicolon is accepted' \
    tests/nix/module_test.sh nix/module.nix edit_file \
    'assertion = cfg.sessionPath == null || (cfg.sessionPath != [] && lib.all (p: matches pathRe p) cfg.sessionPath);' \
    'assertion = cfg.sessionPath == null || (cfg.sessionPath != [] && true);'

mutate_case 'module: server-access names the owner instead of the read-only account' \
    tests/nix/module_test.sh nix/module.nix edit_file \
    'server-access -a -r ${cfg.serverAccessReadOnly}' \
    'server-access -a -r ${cfg.user}'

mutate_case 'module: the owner of the server is accepted as a read-only guest' \
    tests/nix/module_test.sh nix/module.nix edit_file \
    'assertion = cfg.serverAccessReadOnly == null || cfg.serverAccessReadOnly != cfg.user;' \
    'assertion = true;'

mutate_case 'module: the terminal is never written' \
    tests/nix/module_test.sh nix/module.nix edit_file \
    '(lib.optionalString (cfg.terminal != null) ' \
    '(lib.optionalString (cfg.terminal != null && false) '

mutate_case 'module: a history limit of zero is accepted' \
    tests/nix/module_test.sh nix/module.nix edit_file \
    'assertion = cfg.historyLimit == null || cfg.historyLimit > 0;' \
    'assertion = cfg.historyLimit == null;'

check_summary
summary=$?

if [ "$(tree_state)" != "$start_state" ]; then
    echo 'mutation: the tree differs after the run:'
    git status --porcelain=v1 --untracked-files=no
    git diff --stat
    exit 1
fi
echo "tree: unchanged by this run (state $start_state)"
exit "$summary"
