#!/usr/bin/env bash
# uninstall.sh: remove what install.sh installed, and nothing else.
#
# USAGE
#   uninstall.sh [--prefix DIR] [--purge] [--dry-run]
#   uninstall.sh --help
#
# The removal list is built from this checkout's core/ and systemd/ trees, the
# same trees install.sh copied from. Anything else under the prefix is left
# alone. Backups (NAME.bak.TIMESTAMP) are kept. A directory is removed only
# when it is empty; system directories such as usr/local/bin and
# etc/systemd/system are never removed.
#
# --purge also removes etc/tmux-share in full, including files added there, and
# when running as root the runtime directory TMUX_SHARE_DIR (default
# /run/tmux-share). Without root the runtime directory is left alone.
#
# Before anything is removed, every target is resolved with realpath and must
# lie inside the prefix. One that does not aborts the run with nothing removed.
#
# With an empty prefix (a real root install) and systemctl present, the server
# unit and both timers are stopped and disabled first, and systemd reloads after.
#
# Exit status: 0 done (or a dry run that would succeed)
#              1 refused or aborted; nothing was removed
#              2 usage or invalid configuration
set -eu

prog=uninstall.sh
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
argv_text=$(printf '%q ' "$@")

usage() {
    cat <<'EOF'
usage: uninstall.sh [--prefix DIR] [--purge] [--dry-run] [--help]

Remove what install.sh installed. Unrelated files are never touched, and
backups (NAME.bak.TIMESTAMP) are kept.

  --prefix DIR   remove from DIR instead of / (default: empty, meaning /)
  --purge        also remove etc/tmux-share in full, and (as root) the
                 runtime directory TMUX_SHARE_DIR (default /run/tmux-share)
  --dry-run      list what would be removed; remove nothing
  --help         show this help
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
purge=0
dry=0
while [ "$#" -gt 0 ]; do
    case $1 in
        --prefix)
            [ "$#" -ge 2 ] || die "--prefix needs a directory" 2
            prefix=$2
            shift 2
            ;;
        --purge)
            purge=1
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

while [ "${prefix%/}" != "$prefix" ]; do
    prefix=${prefix%/}
done
if [ -n "$prefix" ] && ! validate_log_path "$prefix"; then
    die "invalid --prefix: $VALIDATE_REASON" 2
fi

uid=$(id -u)
self=$(printf '%q' "$HERE/uninstall.sh")
if [ -z "$prefix" ] && [ "$uid" -ne 0 ]; then
    die "a real uninstall must run as root (uid $uid). Run: sudo $self $argv_text" 1
fi

# dest REL: where REL (relative to the root) lives under the prefix.
dest() {
    printf '%s/%s' "$prefix" "$1"
}

# ---- the removal list -----------------------------------------------------------
files=()
for f in "$HERE"/core/bin/*; do
    [ -f "$f" ] || continue
    n=${f##*/}
    files+=("$(dest usr/local/lib/tmux-share/core/bin/$n)" "$(dest usr/local/bin/$n)")
done
for f in "$HERE"/core/lib/*; do
    [ -f "$f" ] || continue
    files+=("$(dest usr/local/lib/tmux-share/core/lib/${f##*/})")
done
files+=("$(dest usr/local/lib/tmux-share/core/tmux-share-stamp)")
for f in "$HERE"/systemd/*.service "$HERE"/systemd/*.timer; do
    [ -f "$f" ] || continue
    files+=("$(dest etc/systemd/system/${f##*/})")
done
files+=(
    "$(dest etc/sysusers.d/tmux-share.conf)"
    "$(dest etc/tmpfiles.d/tmux-share.conf)"
    "$(dest etc/tmux-share/tmux.conf)"
    "$(dest etc/tmux-share/env)"
)

# Directories we created, deepest first. Removed only when empty.
dirs=(
    "$(dest usr/local/lib/tmux-share/core/bin)"
    "$(dest usr/local/lib/tmux-share/core/lib)"
    "$(dest usr/local/lib/tmux-share/core)"
    "$(dest usr/local/lib/tmux-share)"
)
conf_dir=$(dest etc/tmux-share)

runtime=''
if [ "$purge" -eq 1 ]; then
    if [ "$uid" -eq 0 ]; then
        if ! validate_log_path "${TMUX_SHARE_DIR:-/run/tmux-share}"; then
            die "invalid TMUX_SHARE_DIR: $VALIDATE_REASON" 2
        fi
        runtime=$prefix${TMUX_SHARE_DIR:-/run/tmux-share}
    else
        warn "--purge: the runtime directory is left alone (not root)"
    fi
else
    dirs+=("$conf_dir")
fi

# ---- 1. check every target before removing anything -------------------------------
Pr=''
if [ -n "$prefix" ]; then
    Pr=$(realpath -m -- "$prefix")
fi

# inside PATH: die unless PATH, with every symlink in it resolved, lies inside
# the prefix. A target that does not exist cannot be a problem.
inside() {
    local r
    if [ ! -e "$1" ] && [ ! -L "$1" ]; then
        return 0
    fi
    r=$(realpath -m -- "$1")
    case $r in
        "$Pr"/?*) ;;
        *) die "refusing: $1 resolves to $r, outside the prefix. Nothing was removed." 1 ;;
    esac
}

for p in "${files[@]}"; do
    inside "$p"
    if [ -d "$p" ] && [ ! -L "$p" ]; then
        die "$p is a directory where a file was installed. Nothing was removed." 1
    fi
done
for p in "${dirs[@]}" "$conf_dir"; do
    inside "$p"
done
if [ -n "$runtime" ]; then
    rr=$(realpath -m -- "$runtime")
    case $rr in
        /*/*) ;;
        *) die "refusing to purge $rr: too shallow to be a runtime directory. Nothing was removed." 1 ;;
    esac
    if [ "$rr" = "$Pr" ]; then
        die "refusing to purge $rr: that is the prefix itself. Nothing was removed." 1
    fi
    inside "$runtime"
fi

# ---- 2. remove -------------------------------------------------------------------
# present PATH: a file, a symlink or a directory entry exists at PATH.
present() {
    [ -e "$1" ] || [ -L "$1" ]
}

verb=removed
if [ "$dry" -eq 1 ]; then
    verb='would remove'
    printf 'dry run: nothing will be removed\n'
fi

if [ -z "$prefix" ] && command -v systemctl >/dev/null 2>&1; then
    units=(tmux-share-server.service tmux-share-tap.timer tmux-share-trim.timer)
    if [ "$dry" -eq 1 ]; then
        printf '  would run  systemctl disable --now %s\n' "${units[*]}"
    elif ! systemctl disable --now "${units[@]}"; then
        warn "systemctl disable --now failed; check with: systemctl status tmux-share-server.service"
    fi
fi

n_files=0
for p in "${files[@]}"; do
    present "$p" || continue
    if [ "$dry" -eq 0 ]; then
        rm -f -- "$p"
    fi
    printf '  %-12s %s\n' "$verb" "$p"
    n_files=$((n_files + 1))
done

if [ "$purge" -eq 1 ] && present "$conf_dir"; then
    if [ "$dry" -eq 0 ]; then
        rm -rf -- "$conf_dir"
    fi
    printf '  %-12s %s (--purge: everything in it)\n' "$verb" "$conf_dir"
    n_files=$((n_files + 1))
fi
if [ -n "$runtime" ] && present "$runtime"; then
    if [ "$dry" -eq 0 ]; then
        rm -rf -- "$runtime"
    fi
    printf '  %-12s %s (--purge: runtime directory)\n' "$verb" "$runtime"
    n_files=$((n_files + 1))
fi

n_dirs=0
for d in "${dirs[@]}"; do
    if [ ! -d "$d" ] || [ -L "$d" ]; then
        continue
    fi
    if [ "$dry" -eq 1 ]; then
        printf '  %-12s %s (only if empty)\n' 'would prune' "$d"
        continue
    fi
    if rmdir -- "$d" 2>/dev/null; then
        printf '  %-12s %s/ (empty)\n' removed "$d"
        n_dirs=$((n_dirs + 1))
    else
        printf '  %-12s %s/ (not empty: unrelated files are kept)\n' kept "$d"
    fi
done

if [ -z "$prefix" ] && command -v systemctl >/dev/null 2>&1; then
    if [ "$dry" -eq 1 ]; then
        printf '  would run  systemctl daemon-reload\n'
    elif ! systemctl daemon-reload; then
        warn "systemctl daemon-reload failed; run it by hand"
    fi
fi

n_bak=0
for p in "${files[@]}"; do
    for b in "$p".bak.*; do
        if [ -e "$b" ] || [ -L "$b" ]; then
            printf '  %-12s %s (backup of a replaced file)\n' kept "$b"
            n_bak=$((n_bak + 1))
        fi
    done
done

if [ "$dry" -eq 1 ]; then
    printf 'dry run: %d file(s) would be removed; nothing was removed\n' "$n_files"
else
    printf 'uninstalled: removed %d file(s) and %d empty director%s; kept %d backup(s)\n' \
        "$n_files" "$n_dirs" "$( [ "$n_dirs" -eq 1 ] && echo y || echo ies )" "$n_bak"
fi
