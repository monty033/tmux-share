# shellcheck shell=bash
# The transcript is the reader's whole interface: a file the reader group can
# open, and nothing else. Two scripts create it when it is missing -- the tap on
# startup, and the watchdog when it re-attaches after the file was deleted -- and
# both used to create it with the caller's umask and the caller's group. For a
# root deployment that meant root:root: either the reader could not read it (the
# lockout) or it was readable by everyone (a leak the runtime directory's 0710
# does not make acceptable, because the contract says 0640).
#
# The runtime directory exists precisely to carry the right group, so both
# scripts take the group from it and then prove the result instead of assuming
# it. A caller that cannot establish a readable transcript gets a non-zero status
# and a reason; silence here would look exactly like an idle session.

# ensure_transcript REF_DIR FILE: make FILE exist, group-owned like REF_DIR, and
# group-readable. Returns 0, or 1 with a reason in TRANSCRIPT_REASON.
ensure_transcript() {
    local refdir=$1 file=$2
    TRANSCRIPT_REASON=''

    if [ ! -d "$refdir" ]; then
        TRANSCRIPT_REASON="runtime directory $refdir does not exist"
        return 1
    fi

    if [ ! -e "$file" ]; then
        ( umask 027; : >> "$file" ) || {
            TRANSCRIPT_REASON="cannot create $file"
            return 1
        }
    fi

    # Copying the group from the directory is the whole point of the directory
    # being group-owned by the reader's group. It can fail for a caller who is
    # not a member of that group; that is not fatal on its own, because the group
    # may already be right, which is what the check below decides.
    chgrp --reference="$refdir" -- "$file" 2>/dev/null || true

    local want_group got_group mode
    want_group=$(stat -c '%G' -- "$refdir") || {
        TRANSCRIPT_REASON="cannot read the group of $refdir"
        return 1
    }
    got_group=$(stat -c '%G' -- "$file") || {
        TRANSCRIPT_REASON="cannot read the group of $file"
        return 1
    }
    if [ "$got_group" != "$want_group" ]; then
        TRANSCRIPT_REASON="$file is group $got_group but $refdir is group $want_group"
        return 1
    fi

    # The contract is 0640, not "some mode with the group bit set": a transcript
    # that is readable by everyone is the leak this design exists to avoid, and a
    # caller who cannot tighten it must say so rather than carry on.
    if [ "$(stat -c '%a' -- "$file")" != "640" ]; then
        chmod 0640 -- "$file" 2>/dev/null || true
    fi

    mode=$(stat -c '%a' -- "$file") || {
        TRANSCRIPT_REASON="cannot read the mode of $file"
        return 1
    }
    if [ "$mode" != "640" ]; then
        TRANSCRIPT_REASON="$file has mode $mode; it must be 0640 so the reader group can read it and nobody else can"
        return 1
    fi

    return 0
}
