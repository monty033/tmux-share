#!/usr/bin/env bash
# tests/docs/claims_test.sh: keep the documentation honest, statically.
#
# No root, no systemd, no network. The repository root is derived from this
# script's location, so the test works on a copy of the tree as well as here.
#
# WHAT IS CHECKED (the definition of each claim is given where it is tested):
#   1. every "core/bin/<name>" reference, and every tmux-share-* command token,
#      names a file that exists (a systemd unit stem or core/tmux-share-stamp
#      is accepted as a non-script token);
#   2. every tmux-share-*.service/.timer/.sysusers/.tmpfiles name names a file
#      under systemd/;
#   3. every services.tmux-share.<option> mentioned in the docs is a declared
#      option in nix/module.nix, and every declared option is documented;
#   4. no <angle-bracket> placeholder appears inside a fenced code block that
#      claims to be runnable. A block is an "example" (and exempt) when its
#      opening fence carries the word "example"; every other fenced block is
#      treated as a runnable command block and is checked;
#   5. every relative *.md path written in a doc resolves to a file, considered
#      relative to the directory of the doc that mentions it;
#   6. the README's "Security model" section mentions both "root" and "group".
#
# Exit 0 only if every assertion passes.
set -eu

script_dir=$(cd -- "${BASH_SOURCE[0]%/*}" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)

README=$repo_root/README.md
MODULE=$repo_root/nix/module.nix
SYSTEMD=$repo_root/systemd
DOCS=(
    "$repo_root/README.md"
    "$repo_root/docs/security-model.md"
    "$repo_root/docs/install-nixos.md"
    "$repo_root/docs/install-systemd.md"
    "$repo_root/docs/operations.md"
)

pass_count=0
fail_count=0
pass() { pass_count=$((pass_count + 1)); printf 'PASS: %s\n' "$1"; }
fail() { fail_count=$((fail_count + 1)); printf 'FAIL: %s\n' "$1"; }

# A clean environment keeps a leaked TMUX_SHARE_* value from affecting anything.
for v in $(env | grep -o '^TMUX_SHARE_[A-Z_]*' || true); do unset "$v"; done

# ---------------------------------------------------------------------------
# 0. the documents themselves
# ---------------------------------------------------------------------------
for doc in "${DOCS[@]}"; do
    if [ -f "$doc" ]; then
        pass "doc exists: ${doc#"$repo_root"/}"
    else
        fail "doc exists: ${doc#"$repo_root"/}"
    fi
done

# ---------------------------------------------------------------------------
# 1. script references
# ---------------------------------------------------------------------------
# A tmux-share-* token is acceptable if it is a real file in core/bin, the
# stamp filter in core/, the group/prefix name, or the stem of a file in
# systemd/ (units, tmpfiles, sysusers). Anything else is a broken claim.
script_ref_ok() {
    local t=$1 s
    [ -f "$repo_root/core/bin/$t" ] && return 0
    [ "$t" = tmux-share-stamp ] && [ -f "$repo_root/core/$t" ] && return 0
    [ "$t" = tmux-share ] && return 0
    for s in service timer tmpfiles sysusers; do
        [ -f "$SYSTEMD/$t.$s" ] && return 0
    done
    return 1
}

script_refs=$(grep -ohE 'tmux-share-[a-z][a-z0-9-]*' "${DOCS[@]}" | sort -u || true)
bad_refs=''
n_refs=0
while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    n_refs=$((n_refs + 1))
    if script_ref_ok "$tok"; then
        :
    else
        bad_refs="$bad_refs $tok"
    fi
done <<< "$script_refs"
if [ -z "$bad_refs" ]; then
    pass "script references resolve ($n_refs distinct tmux-share-* tokens)"
else
    fail "script references resolve (missing:$bad_refs)"
fi

bin_paths=$(grep -ohE 'core/bin/[A-Za-z0-9._-]+' "${DOCS[@]}" | sort -u || true)
bad_paths=''
n_paths=0
while IFS= read -r p; do
    [ -n "$p" ] || continue
    n_paths=$((n_paths + 1))
    name=${p##*/}
    if [ -f "$repo_root/core/bin/$name" ]; then
        :
    else
        bad_paths="$bad_paths $p"
    fi
done <<< "$bin_paths"
if [ -z "$bad_paths" ]; then
    pass "core/bin/<name> paths exist ($n_paths distinct paths)"
else
    fail "core/bin/<name> paths exist (missing:$bad_paths)"
fi

# ---------------------------------------------------------------------------
# 2. unit names
# ---------------------------------------------------------------------------
unit_refs=$(grep -ohE 'tmux-share-[a-z][a-z0-9-]*\.(service|timer|tmpfiles|sysusers)' "${DOCS[@]}" | sort -u || true)
bad_units=''
n_units=0
while IFS= read -r u; do
    [ -n "$u" ] || continue
    n_units=$((n_units + 1))
    if [ -f "$SYSTEMD/$u" ]; then
        :
    else
        bad_units="$bad_units $u"
    fi
done <<< "$unit_refs"
if [ -z "$bad_units" ]; then
    pass "unit names exist under systemd/ ($n_units distinct names)"
else
    fail "unit names exist under systemd/ (missing:$bad_units)"
fi

# ---------------------------------------------------------------------------
# 3. NixOS module option names
# ---------------------------------------------------------------------------
option_refs=$(grep -ohE 'services\.tmux-share\.[A-Za-z][A-Za-z0-9]*' "${DOCS[@]}" | sed 's/^.*\.//' | sort -u || true)
bad_opts=''
n_opts=0
while IFS= read -r opt; do
    [ -n "$opt" ] || continue
    n_opts=$((n_opts + 1))
    if grep -qE "^[[:space:]]+${opt}[[:space:]]*=[[:space:]]*mk(Enable)?Option" "$MODULE"; then
        :
    else
        bad_opts="$bad_opts $opt"
    fi
done <<< "$option_refs"
if [ -z "$bad_opts" ]; then
    pass "documented options are declared in nix/module.nix ($n_opts distinct options)"
else
    fail "documented options are declared in nix/module.nix (undeclared:$bad_opts)"
fi

declared_opts=$(grep -oE '^[[:space:]]+[A-Za-z][A-Za-z0-9]*[[:space:]]*=[[:space:]]*mk(Enable)?Option' "$MODULE" | sed -E 's/^[[:space:]]+([A-Za-z][A-Za-z0-9]*).*/\1/' | sort -u || true)
undocumented=''
n_declared=0
while IFS= read -r opt; do
    [ -n "$opt" ] || continue
    n_declared=$((n_declared + 1))
    if grep -q -- "$opt" "$repo_root/docs/install-nixos.md"; then
        :
    else
        undocumented="$undocumented $opt"
    fi
done <<< "$declared_opts"
if [ -z "$undocumented" ]; then
    pass "every declared module option is documented ($n_declared options)"
else
    fail "every declared module option is documented (undocumented:$undocumented)"
fi

# ---------------------------------------------------------------------------
# 4. placeholders in runnable command blocks
# ---------------------------------------------------------------------------
# Walk each doc line by line. A fenced block opens on a line whose first three
# characters are ``` and closes on the next such line. If the opening fence
# contains the word "example", the whole block is exempt; otherwise any
# <name>-style token in it is a violation. HTML comments outside blocks and
# angle brackets in prose are not commands and are not checked.
PH_BAD=''
placeholder_violations() {
    local doc line first3 tok inblock example
    for doc in "${DOCS[@]}"; do
        inblock=0
        example=0
        while IFS= read -r line || [ -n "$line" ]; do
            first3=${line:0:3}
            if [ "$first3" = '```' ]; then
                if [ "$inblock" -eq 0 ]; then
                    inblock=1
                    case $line in
                        *example*) example=1 ;;
                        *) example=0 ;;
                    esac
                else
                    inblock=0
                    example=0
                fi
                continue
            fi
            if [ "$inblock" -eq 1 ] && [ "$example" -eq 0 ]; then
                tok=$(printf '%s\n' "$line" | grep -oE '<[A-Za-z][A-Za-z0-9_-]*>' || true)
                if [ -n "$tok" ]; then
                    PH_BAD+="${doc#"$repo_root"/}: $line"$'\n'
                fi
            fi
        done < "$doc"
    done
}
placeholder_violations
if [ -z "$PH_BAD" ]; then
    pass 'no <placeholder> tokens in runnable command blocks'
else
    fail 'no <placeholder> tokens in runnable command blocks'
    printf '%s' "$PH_BAD"
fi

# ---------------------------------------------------------------------------
# 5. relative links between docs
# ---------------------------------------------------------------------------
# Every *.md path token in a doc is treated as a link target and resolved
# relative to that doc's own directory (the same rule markdown uses). Anchors
# and external URLs are not relative file links and are skipped.
LINK_BAD=''
n_links=0
link_violations() {
    local doc toks tok target resolved
    for doc in "${DOCS[@]}"; do
        toks=$(grep -oE '[A-Za-z0-9_./-]+\.md' "$doc" | sort -u || true)
        while IFS= read -r tok; do
            [ -n "$tok" ] || continue
            case $tok in
                http://*|https://*|mailto:*) continue ;;
            esac
            target=${tok%%#*}
            [ -n "$target" ] || continue
            n_links=$((n_links + 1))
            if [ "${target#/}" != "$target" ]; then
                resolved=$target
            else
                resolved=$(cd -- "$(dirname -- "$doc")" && realpath -m -- "$target")
            fi
            if [ ! -e "$resolved" ]; then
                LINK_BAD+="${doc#"$repo_root"/}: $tok -> $resolved"$'\n'
            fi
        done <<< "$toks"
    done
}
link_violations
if [ -z "$LINK_BAD" ]; then
    pass "relative doc links resolve ($n_links distinct paths)"
else
    fail "relative doc links resolve ($n_links paths checked)"
    printf '%s' "$LINK_BAD"
fi

# ---------------------------------------------------------------------------
# 6. README states the limits in its security paragraph
# ---------------------------------------------------------------------------
security_section=''
insec=0
while IFS= read -r line || [ -n "$line" ]; do
    case $line in
        \#*)
            if [ "$insec" -eq 1 ]; then break; fi
            lower=${line,,}
            case $lower in
                *security*) insec=1 ;;
            esac
            continue
            ;;
    esac
    if [ "$insec" -eq 1 ]; then security_section+="$line"$'\n'; fi
done < "$README"
sec_ok=1
printf '%s\n' "$security_section" | grep -qi 'root' || sec_ok=0
printf '%s\n' "$security_section" | grep -qi 'group' || sec_ok=0
if [ "$sec_ok" -eq 1 ]; then
    pass 'README security paragraph mentions root and group'
else
    fail 'README security paragraph mentions root and group'
fi

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass_count" "$fail_count"
if [ "$fail_count" -eq 0 ]; then
    printf 'RESULT: PASS\n'
    exit 0
fi
printf 'RESULT: FAIL\n'
exit 1
