#!/usr/bin/env bash
# install.sh: install tmux-share on a plain-systemd host (no Nix).
#
# USAGE
#   install.sh [--prefix DIR] [--reader GROUP] [--session NAME] [--user NAME]
#              [--force] [--dry-run]
#   install.sh --help
#
# A real install runs as root with the default empty prefix. Without root, pass
# --prefix DIR: the same layout is written under DIR and nothing outside it is
# touched. The test suite runs it that way.
#
# --user NAME is the account the units run as and that owns the runtime files
# (default root). It does not make the install rootless: writing
# /etc/systemd/system still takes root, and so does this script.
#
# LAYOUT (relative to the prefix)
#   usr/local/lib/tmux-share/core/bin/*          core scripts       0755
#   usr/local/lib/tmux-share/core/lib/*          shared libraries   0644
#   usr/local/lib/tmux-share/core/tmux-share-stamp                  0755
#   usr/local/bin/<script>                       relative symlink into core/bin
#   etc/systemd/system/*.service, *.timer        units, verbatim    0644
#                                                (with --user NAME other than root, the
#                                                services gain User=NAME)
#   etc/sysusers.d/tmux-share.conf               reader group       0644
#   etc/tmpfiles.d/tmux-share.conf               runtime rules      0644
#                                                (with --user NAME, owned NAME; the lock
#                                                group is NAME's primary group)
#   etc/tmux-share/tmux.conf                     rendered           0640 USER:READER
#   etc/tmux-share/env                           rendered           0640 USER:READER
#   USER is root unless --user names another account: the tmux server reads
#   tmux.conf as that account, and it is not in the reader group.
#
# SAFETY
#   * The preflight probe runs first. If it fails, nothing is written. --force
#     skips it and says so.
#   * Everything is rendered and validated before the first write.
#   * A file whose content differs is moved to NAME.bak.TIMESTAMP before it is
#     replaced. A file that differs only in mode or owner is fixed in place,
#     with no backup.
#   * A second run changes nothing and says so.
#   * --dry-run lists every file, destination and mode, and writes nothing.
#   * Nothing is started, enabled or granted to an account. The commands that
#     remain are printed at the end for the operator to run.
#
# Exit status: 0 done (or a dry run that would succeed)
#              1 refused or failed: not root, preflight failed, write error
#              2 usage or invalid configuration, including a --user that does
#                not exist on this host or is the reader account
set -eu

prog=install.sh
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
argv_text=''
if [ "$#" -gt 0 ]; then
    argv_text=$(printf '%q ' "$@")
fi

usage() {
    cat <<'EOF'
usage: install.sh [--prefix DIR] [--reader GROUP] [--session NAME] [--user NAME]
                  [--force] [--dry-run] [--help]

Install tmux-share on a plain-systemd host. A real install runs as root with
the default empty prefix. Without root, --prefix DIR stages the same layout
under DIR.

  --prefix DIR     install under DIR instead of / (default: empty, meaning /)
  --reader GROUP   group that may read the transcript (default: tmux-share)
  --session NAME   tmux session to monitor (default: tmux-hermes)
  --user NAME      existing account that runs the units and owns the runtime
                   files (default: root); not the reader account, which is
                   TMUX_SHARE_READER when that is set. Still needs root to run.
  --force          skip the preflight probe; the install then runs untested
  --dry-run        list every file, destination and mode; change nothing
  --help           show this help

TMUX_SHARE_* environment variables override the defaults (docs/operations.md).
TMUX_SHARE_LIBDIR and TMUX_SHARE_STAMP are fixed by the layout and ignored.
EOF
}

die() {
    printf '%s: %s\n' "$prog" "$1" >&2
    exit "${2:-1}"
}

warn() {
    printf '%s: warning: %s\n' "$prog" "$1" >&2
}

# ---- arguments --------------------------------------------------------------
prefix=''
reader=tmux-share
session=''
user=root
force=0
dry=0
while [ "$#" -gt 0 ]; do
    case $1 in
        --prefix)
            [ "$#" -ge 2 ] || die "--prefix needs a directory" 2
            prefix=$2
            shift 2
            ;;
        --reader)
            [ "$#" -ge 2 ] || die "--reader needs a group name" 2
            reader=$2
            shift 2
            ;;
        --session)
            [ "$#" -ge 2 ] || die "--session needs a name" 2
            session=$2
            shift 2
            ;;
        --user)
            [ "$#" -ge 2 ] || die "--user needs an account name" 2
            user=$2
            shift 2
            ;;
        --force)
            force=1
            shift
            ;;
        --dry-run)
            dry=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "unknown argument: $1" 2
            ;;
    esac
done

# shellcheck source=core/lib/validate.sh
. "$HERE/core/lib/validate.sh"

# A trailing slash is noise, and '/' means the real root: both become ''.
while [ "${prefix%/}" != "$prefix" ]; do
    prefix=${prefix%/}
done
if [ -n "$prefix" ] && ! validate_log_path "$prefix"; then
    die "invalid --prefix: $VALIDATE_REASON" 2
fi
case $reader in
    '' | [!a-z_]* | *[!a-z0-9_-]*)
        die "invalid --reader group name: $reader" 2
        ;;
esac
if [ "${#reader}" -gt 32 ]; then
    die "invalid --reader group name: longer than 32 characters" 2
fi
# The account is written into unit files and tmpfiles rules, so it gets the
# alphabet of the module's `user` option before anything is looked up.
case $user in
    '' | [!A-Za-z0-9_]* | *[!A-Za-z0-9_.-]*)
        die "invalid --user account name: $user" 2
        ;;
esac
if [ "${#user}" -gt 32 ]; then
    die "invalid --user account name: longer than 32 characters" 2
fi
# The reader reads the transcript and must never be the operator. Only the
# reader account the caller names can be compared: the installer has no other
# way to know it.
if [ -n "${TMUX_SHARE_READER:-}" ] && [ "$user" = "$TMUX_SHARE_READER" ]; then
    die "--user $user is the reader account (TMUX_SHARE_READER): the reader gets the transcript and never the socket, so it cannot also run the server" 2
fi
# root always exists. Any other account has to, or tmpfiles and systemd would
# fail at boot on an owner they cannot resolve.
if [ "$user" != root ] && ! getent passwd "$user" >/dev/null 2>&1; then
    die "--user $user does not exist on this host; create the account first (this script never creates one)" 2
fi
# The lock rule is owned by the account's primary group: it is the group tmux
# gives the socket and the one that always exists, unlike a group named after
# the account, which a normal account does not have. Looked up before anything
# is written so that an account with no resolvable group is refused up front.
user_group=root
if [ "$user" != root ]; then
    user_gid=$(getent passwd "$user" | cut -d: -f4)
    user_group=$(getent group "$user_gid" 2>/dev/null | cut -d: -f1 || true)
    case $user_group in
        '' | [!A-Za-z0-9_]* | *[!A-Za-z0-9_.-]*)
            die "cannot determine the primary group of --user $user (gid '${user_gid:-none}'): the lock file is owned by it" 2
            ;;
    esac
fi
if [ -n "$session" ]; then
    if ! validate_session_name "$session"; then
        die "invalid --session: $VALIDATE_REASON" 2
    fi
    export TMUX_SHARE_SESSION=$session
fi
# Set unconditionally so a TMUX_SHARE_USER inherited from the caller cannot make
# the rendered env file disagree with the units and rules written below.
export TMUX_SHARE_USER=$user
for v in TMUX_SHARE_LIBDIR TMUX_SHARE_STAMP; do
    if [ -n "${!v:-}" ]; then
        warn "$v is fixed by the install layout; ignoring the value from the environment"
    fi
done

# ---- who is running -----------------------------------------------------------
uid=$(id -u)
self=$(printf '%q' "$HERE/install.sh")
if [ -z "$prefix" ] && [ "$uid" -ne 0 ]; then
    die "a real install must run as root (uid $uid). Run: sudo $self $argv_text" 1
fi
if [ -n "$prefix" ] && [ "$uid" -ne 0 ]; then
    warn "not running as root: staging under $prefix; owners and groups are left as they are"
fi

# ---- 1. preflight -------------------------------------------------------------
preflight() {
    local pf=$HERE/core/bin/tmux-share-preflight out rc=0 failed
    if [ "$force" -eq 1 ]; then
        warn "--force: the preflight probe is SKIPPED; nothing has checked that this tmux can run tmux-share"
        return 0
    fi
    out=$(env -u TMUX_SHARE_LIBDIR "$pf" 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
        failed=$(printf '%s\n' "$out" | sed -n 's/^FAIL \([^ ]*\).*/\1/p' | tr '\n' ' ')
        {
            printf '%s: preflight FAILED (exit %s); nothing was installed.\n' "$prog" "$rc"
            printf '%s: failing checks: %s\n' "$prog" "${failed:-none reported, see below}"
            printf '%s\n' "$out" | sed 's/^/  | /'
            printf '%s: fix the problem and re-run, or pass --force to install without the probe.\n' "$prog"
        } >&2
        exit 1
    fi
    printf 'preflight: ok (%s)\n' "$(printf '%s\n' "$out" | tail -n 1)"
}
preflight

# ---- 2. render and validate, into a scratch directory ------------------------
stage=$(mktemp -d "${TMPDIR:-/tmp}/tmux-share-install.XXXXXX") \
    || die "cannot create a scratch directory" 1
trap 'rm -rf -- "$stage"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ts=$(date +%Y%m%d%H%M%S)

# dest REL: where REL (relative to the root) lands under the prefix.
dest() {
    printf '%s/%s' "$prefix" "$1"
}

lib_dst=$(dest usr/local/lib/tmux-share/core/lib)
stamp_dst=$(dest usr/local/lib/tmux-share/core/tmux-share-stamp)
if ! validate_log_path "$lib_dst"; then
    die "the install location is not usable: $VALIDATE_REASON ($lib_dst)" 2
fi

# render MODE OUTFILE: a refusal from the renderer writes nothing.
#
# The renderer sources validate.sh from TMUX_SHARE_LIBDIR. That directory does
# not exist until the files are copied, so the renderer runs against this
# checkout's lib/, and the one line that must name the installed location
# (LIBDIR) is rewritten below. Everything else in the output is the renderer's.
render() {
    if ! env TMUX_SHARE_LIBDIR="$HERE/core/lib" TMUX_SHARE_STAMP="$stamp_dst" \
        "$HERE/core/bin/tmux-share-render" "$1" > "$2"; then
        die "tmux-share-render rejected the configuration (see above); nothing was written" 2
    fi
    [ -s "$2" ] || die "tmux-share-render printed nothing for '$1'" 1
}
render paths "$stage/env.raw"
render tmux-config "$stage/tmux.conf"
if [ "$(grep -c '^TMUX_SHARE_LIBDIR=' "$stage/env.raw")" -ne 1 ]; then
    die "tmux-share-render did not print TMUX_SHARE_LIBDIR exactly once; nothing was written" 1
fi
while IFS= read -r line; do
    case $line in
        TMUX_SHARE_LIBDIR=*) printf "TMUX_SHARE_LIBDIR='%s'\n" "$lib_dst" ;;
        *) printf '%s\n' "$line" ;;
    esac
done < "$stage/env.raw" > "$stage/env"

# ---- 3. the plan ---------------------------------------------------------------
# Parallel arrays, one entry per destination. For kind=link, p_src holds the
# link target, not a path.
p_src=()
p_dst=()
p_mode=()
p_kind=()
p_owner=()
p_state=()

# add_file SRC DST MODE OWNER(none|reader)
add_file() {
    p_src+=("$1")
    p_dst+=("$2")
    p_mode+=("$3")
    p_kind+=(file)
    p_owner+=("$4")
    p_state+=(ok)
}

# add_link TARGET DST
add_link() {
    p_src+=("$1")
    p_dst+=("$2")
    p_mode+=(-)
    p_kind+=(link)
    p_owner+=(none)
    p_state+=(ok)
}

for f in "$HERE"/core/bin/*; do
    [ -f "$f" ] || continue
    n=${f##*/}
    add_file "$f" "$(dest usr/local/lib/tmux-share/core/bin/$n)" 0755 none
    add_link "../lib/tmux-share/core/bin/$n" "$(dest usr/local/bin/$n)"
done
for f in "$HERE"/core/lib/*; do
    [ -f "$f" ] || continue
    add_file "$f" "$(dest usr/local/lib/tmux-share/core/lib/${f##*/})" 0644 none
done
add_file "$HERE/core/tmux-share-stamp" "$stamp_dst" 0755 none
# The templates run as root. For another account the installed copies are
# rendered from them; for root they are the templates themselves, byte for byte.
units_src=$HERE/systemd
tmpfiles_src=$HERE/systemd/tmux-share.tmpfiles
if [ "$user" != root ]; then
    mkdir -p -- "$stage/units"
    for f in "$HERE"/systemd/*.service; do
        [ -f "$f" ] || continue
        # Timers start a unit and take no User=.
        awk -v u="$user" '
            { print }
            /^\[Service\]$/ {
                print "# User: the account that owns the server and the runtime files (install.sh --user); without it the unit runs as root."
                print "User=" u
            }
        ' "$f" > "$stage/units/${f##*/}"
        if [ "$(grep -c '^User=' "$stage/units/${f##*/}")" -ne 1 ]; then
            die "could not add User= to ${f##*/}; nothing was written" 1
        fi
    done
    for f in "$HERE"/systemd/*.timer; do
        [ -f "$f" ] || continue
        cp -- "$f" "$stage/units/${f##*/}"
    done
    units_src=$stage/units
    # Owner and group fields of the rules that name root: the directory and the
    # transcript keep the reader group, the lock's group becomes the user's
    # primary group.
    awk -v u="$user" -v g="$user_group" '
        /^#/ || NF != 7 { print; next }
        { if ($4 == "root") $4 = u; if ($5 == "root") $5 = g; print }
    ' "$tmpfiles_src" > "$stage/tmux-share.tmpfiles"
    if [ "$(grep -c "^[df] .* $user " "$stage/tmux-share.tmpfiles")" -ne 3 ]; then
        die "could not set the owner in the tmpfiles rules; nothing was written" 1
    fi
    tmpfiles_src=$stage/tmux-share.tmpfiles
fi
for f in "$HERE"/systemd/*.service "$HERE"/systemd/*.timer; do
    [ -f "$f" ] || continue
    add_file "$units_src/${f##*/}" "$(dest etc/systemd/system/${f##*/})" 0644 none
done
add_file "$HERE/systemd/tmux-share.sysusers" "$(dest etc/sysusers.d/tmux-share.conf)" 0644 none
add_file "$tmpfiles_src" "$(dest etc/tmpfiles.d/tmux-share.conf)" 0644 none
add_file "$stage/tmux.conf" "$(dest etc/tmux-share/tmux.conf)" 0640 reader
add_file "$stage/env" "$(dest etc/tmux-share/env)" 0640 reader

# The group that owns the rendered files. If it does not exist yet (sysusers
# has not run), their group stays root and a later run fixes them. Their owner
# is the --user account, which is root unless named.
grp=root
if [ "$uid" -eq 0 ]; then
    if getent group "$reader" >/dev/null 2>&1; then
        grp=$reader
    else
        warn "group '$reader' does not exist yet (systemd-sysusers creates it); env and tmux.conf stay root:root until install.sh is re-run"
    fi
fi

# sum PATH: the sha256 of a file.
sum() {
    sha256sum -- "$1" | cut -d' ' -f1
}

# classify INDEX: set p_state[INDEX] to create, replace, update, fixup or ok.
classify() {
    local i=$1 src dst u=root g=root
    src=${p_src[$i]}
    dst=${p_dst[$i]}
    if [ "${p_owner[$i]}" = reader ]; then u=$user; g=$grp; fi
    p_state[$i]=ok
    if [ -L "$dst" ]; then
        if [ "${p_kind[$i]}" = link ] && [ "$(readlink -- "$dst")" = "$src" ]; then
            p_state[$i]=ok
        else
            p_state[$i]=replace
        fi
    elif [ -d "$dst" ]; then
        die "$dst is a directory; refusing to replace it" 1
    elif [ ! -e "$dst" ]; then
        p_state[$i]=create
    elif [ "${p_kind[$i]}" = link ]; then
        p_state[$i]=replace
    elif [ "$(sum "$src")" != "$(sum "$dst")" ]; then
        p_state[$i]=update
    elif [ "$(stat -c %a -- "$dst")" != "${p_mode[$i]#0}" ]; then
        p_state[$i]=fixup
    elif [ "$uid" -eq 0 ] && [ "$(stat -c %U:%G -- "$dst")" != "$u:$g" ]; then
        p_state[$i]=fixup
    fi
    return 0
}

# describe INDEX: one line of the plan.
describe() {
    local i=$1 detail
    if [ "${p_kind[$i]}" = link ]; then
        detail="-> ${p_src[$i]}"
    else
        detail="mode ${p_mode[$i]}"
        if [ "${p_owner[$i]}" = reader ]; then
            detail="$detail, group $reader"
            if [ "$user" != root ]; then
                detail="$detail, owner $user"
            fi
        fi
    fi
    printf '  %-8s %s  %s\n' "${p_state[$i]}" "${p_dst[$i]}" "$detail"
}

# backup_aside PATH: move PATH to PATH.bak.TIMESTAMP, never overwriting a backup.
backup_aside() {
    local bak=$1.bak.$ts n=1
    while [ -e "$bak" ] || [ -L "$bak" ]; do
        n=$((n + 1))
        bak=$1.bak.$ts.$n
    done
    mv -- "$1" "$bak"
    printf '  kept     %s (replaced copy)\n' "$bak"
}

# apply_one INDEX: make the destination match the plan.
apply_one() {
    local i=$1 src dst u=root g=root
    src=${p_src[$i]}
    dst=${p_dst[$i]}
    if [ "${p_owner[$i]}" = reader ]; then u=$user; g=$grp; fi
    case ${p_state[$i]} in
        ok)
            return 0
            ;;
        fixup)
            chmod -- "${p_mode[$i]}" "$dst"
            ;;
        create | update | replace)
            if [ "${p_state[$i]}" != create ]; then
                backup_aside "$dst"
            fi
            mkdir -p -- "$(dirname -- "$dst")"
            if [ "${p_kind[$i]}" = link ]; then
                ln -s -- "$src" "$dst"
                return 0
            fi
            install -m "${p_mode[$i]}" -- "$src" "$dst"
            ;;
    esac
    if [ "$uid" -eq 0 ] && [ "${p_kind[$i]}" = file ]; then
        chown -- "$u:$g" "$dst"
    fi
    return 0
}

next_steps() {
    if [ -n "$prefix" ]; then
        printf '\nthis was a staged install under %s; the steps below are for a real root install, after the files are placed at /\n' "$prefix"
    fi
    cat <<EOF

next steps (run as root; this script does not run them):
  systemd-sysusers                                 # creates group $reader
  systemd-tmpfiles --create                        # creates /run/tmux-share and the transcript
  systemctl daemon-reload
  systemctl enable --now tmux-share-server.service
  systemctl enable --now tmux-share-tap.timer tmux-share-trim.timer
  set -a; . /etc/tmux-share/env; set +a
  TMUX_SHARE_GROUP=$reader TMUX_SHARE_READER=<reader> tmux-share-verify

grant a reader account access to the transcript (run once, as root; not run by this script):
  usermod -aG $reader <reader>
  (the account must start a new login session before the membership applies)
EOF
}

for i in "${!p_dst[@]}"; do
    classify "$i"
done

if [ "$dry" -eq 1 ]; then
    printf 'dry run: what a real install under %s would do (nothing is written):\n' "${prefix:-/}"
else
    printf 'installing under %s:\n' "${prefix:-/}"
fi
for i in "${!p_dst[@]}"; do
    describe "$i"
done

n_create=0
n_update=0
n_fixup=0
n_ok=0
for i in "${!p_state[@]}"; do
    case ${p_state[$i]} in
        create) n_create=$((n_create + 1)) ;;
        update | replace) n_update=$((n_update + 1)) ;;
        fixup) n_fixup=$((n_fixup + 1)) ;;
        ok) n_ok=$((n_ok + 1)) ;;
    esac
done
changes=$((n_create + n_update + n_fixup))

if [ "$dry" -eq 0 ]; then
    for i in "${!p_dst[@]}"; do
        apply_one "$i"
    done
fi

if [ "$dry" -eq 1 ]; then
    printf 'dry run: %d change(s) would be made, %d file(s) already current; nothing was written\n' "$changes" "$n_ok"
elif [ "$changes" -eq 0 ]; then
    printf 'no changes: this installation was already current (%d file(s) checked)\n' "$n_ok"
else
    printf 'installed: %d created, %d replaced (old copies kept as NAME.bak.%s), %d fixed in place, %d unchanged\n' \
        "$n_create" "$n_update" "$ts" "$n_fixup" "$n_ok"
fi

next_steps
