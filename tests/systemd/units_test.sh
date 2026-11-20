#!/usr/bin/env bash
# Static test for the five systemd unit templates in systemd/. No root, no
# systemd needed (systemd-analyze verify is used only if it exists), no
# network. Exit 0 only if every case passes.
#
# The units are the plain-systemd path and must mirror the NixOS module, so
# the test pins the directives that exist because of a measured trap:
#   * the leading "-" on ExecStartPost (a failed tap must not kill the session)
#   * no UMask (it would become the operator shell's umask)
#   * no RuntimeDirectory (tmpfiles owns the 0710 directory)
#   * AccuracySec=1s on both timers (the default is one minute)
set -eu

script_dir=$(cd -- "${BASH_SOURCE[0]%/*}" && pwd)
repo_root=$(cd -- "${script_dir}/../.." && pwd)
units_dir=$repo_root/systemd

work=$(mktemp -d "${TMPDIR:-/tmp}/units-test.XXXXXX")
cleanup() { rm -rf -- "$work"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Clean environment: nothing leaked from an earlier shell reaches the checks.
for v in $(env | grep -o '^TMUX_SHARE_[A-Z_]*' || true); do unset "$v"; done

pass_count=0
fail_count=0
skip_count=0
pass() { pass_count=$((pass_count + 1)); printf 'PASS: %s\n' "$1"; }
fail() { fail_count=$((fail_count + 1)); printf 'FAIL: %s\n' "$1"; }
skip() { skip_count=$((skip_count + 1)); printf 'SKIP: %s\n' "$1"; }

SERVER=tmux-share-server.service
TAP=tmux-share-tap.service
TAP_TIMER=tmux-share-tap.timer
TRIM=tmux-share-trim.service
TRIM_TIMER=tmux-share-trim.timer
ALL_UNITS="$SERVER $TAP $TAP_TIMER $TRIM $TRIM_TIMER"

# ---- helpers (each takes the directory to look in, so a broken copy can be
# ---- fed through exactly the same assertion) ---------------------------------

# values DIR UNIT KEY: every value of KEY in the unit, one per line. Comment
# lines are ignored; the section is not (keys are unique across sections here).
values() {
    awk -v key="$3" '
        /^[[:space:]]*#/ { next }
        index($0, key "=") == 1 { print substr($0, length(key) + 2) }
    ' "$1/$2"
}

# first DIR UNIT KEY: the first value, or empty.
first() { values "$1" "$2" "$3" | head -n 1; }

# parses DIR UNIT: every line is blank, a "#" comment, a "[section]" or
# Key=Value. Prints the offending lines and fails otherwise.
parses() {
    local bad
    bad=$(awk '
        /^$/ { next }
        /^#/ { next }
        /^\[[A-Za-z]+\]$/ { next }
        /^[A-Za-z][A-Za-z0-9]*=/ { next }
        { printf "line %d: %s\n", NR, $0 }
    ' "$1/$2")
    [ -z "$bad" ] || { printf '%s\n' "$bad"; return 1; }
}

# has_key DIR UNIT SECTION KEY: KEY= occurs inside [SECTION].
has_key() {
    awk -v sec="[$3]" -v key="$4" '
        /^\[/ { cur = $0; next }
        cur == sec && index($0, key "=") == 1 { found = 1 }
        END { exit !found }
    ' "$1/$2"
}

# required DIR UNIT: the keys every unit of this type needs.
required() {
    local dir=$1 unit=$2 missing='' spec sec key
    local specs
    case $unit in
        *.timer)
            specs='Unit:Description Timer:OnUnitActiveSec Timer:AccuracySec Install:WantedBy' ;;
        "$SERVER")
            specs='Unit:Description Unit:After Service:Type Service:ExecStart Service:ExecStartPost Service:Restart Install:WantedBy' ;;
        *)
            specs='Unit:Description Unit:After Service:Type Service:ExecStart' ;;
    esac
    for spec in $specs; do
        sec=${spec%%:*}
        key=${spec#*:}
        has_key "$dir" "$unit" "$sec" "$key" || missing="$missing [$sec]$key"
    done
    [ -z "$missing" ] || { printf 'missing:%s\n' "$missing"; return 1; }
}

# Assertions over a directory. Return 0 if the property holds.
a_server_post_dash() {
    [ "$(first "$1" "$SERVER" ExecStartPost | cut -c 1-1)" = '-' ]
}
a_server_post_target() {
    [ "$(first "$1" "$SERVER" ExecStartPost)" = '-/usr/local/bin/tmux-share-tap-start' ]
}
a_no_umask() {
    local u
    for u in $ALL_UNITS; do
        if grep -qi 'UMask=' "$1/$u"; then printf '%s contains UMask=\n' "$u"; return 1; fi
    done
}
a_accuracy() {
    local t
    for t in $TAP_TIMER $TRIM_TIMER; do
        [ "$(first "$1" "$t" AccuracySec)" = '1s' ] || { printf '%s: AccuracySec is "%s"\n' "$t" "$(first "$1" "$t" AccuracySec)"; return 1; }
    done
}
a_tap_interval() {
    [ "$(first "$1" "$TAP_TIMER" OnUnitActiveSec)" = '20s' ] \
        && [ "$(first "$1" "$TAP_TIMER" OnBootSec)" = '20s' ]
}
a_trim_interval() {
    [ "$(first "$1" "$TRIM_TIMER" OnUnitActiveSec)" = '5min' ]
}
a_oneshot() {
    [ "$(first "$1" "$TAP" Type)" = oneshot ] && [ "$(first "$1" "$TRIM" Type)" = oneshot ]
}

# ---- 0. the files exist ------------------------------------------------------
for u in $ALL_UNITS; do
    if [ -f "$units_dir/$u" ]; then pass "exists: $u"; else fail "exists: $u (not found in $units_dir)"; fi
done

# ---- 1. INI-ish and required keys --------------------------------------------
for u in $ALL_UNITS; do
    [ -f "$units_dir/$u" ] || continue
    if out=$(parses "$units_dir" "$u"); then pass "syntax: $u is blank/comment/[section]/Key=Value only"; else fail "syntax: $u: $out"; fi
    if out=$(required "$units_dir" "$u"); then pass "required keys: $u"; else fail "required keys: $u: $out"; fi
done

# ---- 2. server unit ----------------------------------------------------------
if a_server_post_dash "$units_dir"; then pass 'server: ExecStartPost starts with "-"'; else fail 'server: ExecStartPost starts with "-"'; fi
if a_server_post_target "$units_dir"; then pass 'server: ExecStartPost is -/usr/local/bin/tmux-share-tap-start'; else fail 'server: ExecStartPost is -/usr/local/bin/tmux-share-tap-start'; fi
if [ "$(first "$units_dir" "$SERVER" Type)" = simple ]; then pass 'server: Type=simple'; else fail 'server: Type=simple'; fi
if [ "$(first "$units_dir" "$SERVER" ExecStart)" = '/usr/bin/tmux -D -S /run/tmux-share/tmux.sock -f /etc/tmux-share/tmux.conf' ]; then pass 'server: ExecStart is the foreground tmux server'; else fail 'server: ExecStart is the foreground tmux server'; fi
if [ "$(first "$units_dir" "$SERVER" Restart)" = on-failure ]; then pass 'server: Restart=on-failure'; else fail 'server: Restart=on-failure'; fi
if [ -z "$(values "$units_dir" "$SERVER" RuntimeDirectory)" ]; then pass 'server: no RuntimeDirectory= (tmpfiles owns the 0710 directory)'; else fail 'server: no RuntimeDirectory='; fi
if [ "$(values "$units_dir" "$SERVER" ExecStartPost | wc -l)" -eq 1 ]; then pass 'server: exactly one ExecStartPost'; else fail 'server: exactly one ExecStartPost'; fi

# ---- 3. no UMask anywhere ------------------------------------------------------
if out=$(a_no_umask "$units_dir"); then pass 'no unit contains UMask='; else fail "no unit contains UMask=: $out"; fi

# ---- 4. timers -----------------------------------------------------------------
if out=$(a_accuracy "$units_dir"); then pass 'timers: both set AccuracySec=1s'; else fail "timers: both set AccuracySec=1s: $out"; fi
if a_tap_interval "$units_dir"; then pass 'tap timer: 20 seconds (OnBootSec=20s, OnUnitActiveSec=20s)'; else fail 'tap timer: 20 seconds (OnBootSec=20s, OnUnitActiveSec=20s)'; fi
if a_trim_interval "$units_dir"; then pass 'trim timer: OnUnitActiveSec=5min'; else fail 'trim timer: OnUnitActiveSec=5min'; fi
if [ -n "$(values "$units_dir" "$TRIM_TIMER" OnBootSec)" ]; then pass 'trim timer: has a starter (OnUnitActiveSec alone never fires the first time)'; else fail 'trim timer: has a starter (OnBootSec)'; fi

# ---- 5. tap and trim services ----------------------------------------------------
if a_oneshot "$units_dir"; then pass 'tap and trim services: Type=oneshot'; else fail 'tap and trim services: Type=oneshot'; fi
if [ "$(first "$units_dir" "$TAP" ExecStart)" = /usr/local/bin/tmux-share-watchdog ]; then pass 'tap service: ExecStart is the watchdog'; else fail 'tap service: ExecStart is the watchdog'; fi
if [ "$(first "$units_dir" "$TRIM" ExecStart)" = /usr/local/bin/tmux-share-trim ]; then pass 'trim service: ExecStart is the trimmer'; else fail 'trim service: ExecStart is the trimmer'; fi
bad=''
for u in $TAP $TRIM; do
    [ -z "$(values "$units_dir" "$u" RemainAfterExit)" ] || bad="$bad $u"
done
if [ -z "$bad" ]; then pass 'tap and trim services: no RemainAfterExit'; else fail "no RemainAfterExit:$bad"; fi
bad=''
for u in $TAP $TRIM; do
    for k in Requires Wants BindsTo PartOf Restart; do
        [ -z "$(values "$units_dir" "$u" "$k")" ] || bad="$bad $u:$k"
    done
done
if [ -z "$bad" ]; then pass 'tap and trim services: cannot start, bind or restart the server'; else fail "tap and trim services must not declare:$bad"; fi
bad=''
for u in $TAP $TRIM; do
    for k in ExecStart ExecStartPre ExecStartPost ExecStop; do
        if values "$units_dir" "$u" "$k" | grep -Eq 'systemctl|tmux-share-server'; then bad="$bad $u:$k"; fi
    done
done
if [ -z "$bad" ]; then pass 'tap and trim services: no command touches systemctl or the server unit'; else fail "no command may touch the server:$bad"; fi
for u in $TAP $TRIM; do
    if values "$units_dir" "$u" After | grep -q "$SERVER"; then pass "ordering: $u is After=$SERVER"; else fail "ordering: $u is After=$SERVER"; fi
done

# ---- 6. no unit calls "pipe-pane -o" (it toggles) ----------------------------------
bad=''
for u in $ALL_UNITS; do
    if grep -v '^[[:space:]]*#' "$units_dir/$u" | grep -q -- 'pipe-pane'; then bad="$bad $u"; fi
done
if [ -z "$bad" ]; then pass 'no unit directive calls pipe-pane (the scripts own that, never with -o)'; else fail "directive calls pipe-pane:$bad"; fi

# ---- 7. every directive has a comment directly above it --------------------------
for u in $ALL_UNITS; do
    undocumented=$(awk '
        /^#/ { c = 1; next }
        /^$/ { c = 0; next }
        /^\[/ { c = 0; next }
        { if (c == 0) print "line " NR ": " $0; c = 0 }
    ' "$units_dir/$u")
    # A comment covers the directive right under it; several directives under
    # one comment are not allowed, so each needs its own line above.
    if [ -z "$undocumented" ]; then pass "comments: every directive in $u has a comment above"; else fail "comments: $u: $undocumented"; fi
done
for u in $ALL_UNITS; do
    case $u in
        *.service) sec=Service ;;
        *) sec=Timer ;;
    esac
    if ! has_key "$units_dir" "$u" "$sec" "$( [ "$sec" = Timer ] && echo AccuracySec || echo Type )"; then
        continue
    fi
done
if grep -q 'tmpfiles' "$units_dir/$SERVER" && grep -qi 'UMask' "$units_dir/$SERVER" && grep -q 'leading -' "$units_dir/$SERVER"; then
    pass 'server: comments explain the "-" prefix, the missing UMask and tmpfiles'
else
    fail 'server: comments explain the "-" prefix, the missing UMask and tmpfiles'
fi
for t in $TAP_TIMER $TRIM_TIMER; do
    if grep -q '^# AccuracySec:.*1min' "$units_dir/$t"; then pass "comments: $t explains AccuracySec"; else fail "comments: $t explains AccuracySec"; fi
done

# ---- 8. systemd-analyze verify ---------------------------------------------------
# It checks that every ExecStart exists. The deployment paths (/usr/bin/tmux,
# /usr/local/bin/...) exist only on an installed host, so "is not executable:
# No such file" alone is a SKIP; any other complaint is a FAIL.
if command -v systemd-analyze >/dev/null 2>&1; then
    vdir=$work/verify
    mkdir -p "$vdir"
    for u in $ALL_UNITS; do cp -- "$units_dir/$u" "$vdir/$u"; done
    vrc=0
    vout=$(cd "$vdir" && systemd-analyze verify $(for u in $ALL_UNITS; do printf './%s ' "$u"; done) 2>&1) || vrc=$?
    other=$(printf '%s\n' "$vout" | grep -v '^$' | grep -v 'is not executable: No such file or directory' || true)
    if [ "$vrc" -eq 0 ] && [ -z "$vout" ]; then
        pass 'systemd-analyze verify: clean'
    elif [ -z "$other" ]; then
        skip "systemd-analyze verify: only missing deployment binaries (not installed on this host): $(printf '%s' "$vout" | tr '\n' ';')"
    else
        fail "systemd-analyze verify (rc=$vrc): $(printf '%s' "$vout" | tr '\n' ';')"
    fi
else
    skip 'systemd-analyze verify: systemd-analyze is not installed'
fi

# ---- 9. prove the test can fail ---------------------------------------------------
# Each broken copy must make its assertion fail; a test that cannot fail proves nothing.
broken=$work/broken
mkdir -p "$broken"
mutate() { # mutate NAME SED-EXPR UNIT ASSERTION: expect ASSERTION to fail on the mutated copy
    local name=$1 expr=$2 unit=$3 assertion=$4
    rm -rf -- "$broken"; mkdir -p "$broken"
    for u in $ALL_UNITS; do cp -- "$units_dir/$u" "$broken/$u"; done
    sed -i -e "$expr" "$broken/$unit"
    if cmp -s -- "$units_dir/$unit" "$broken/$unit"; then
        fail "negative control: $name (the mutation changed nothing)"
    elif "$assertion" "$broken" >/dev/null 2>&1; then
        fail "negative control: $name (assertion still passed on the broken copy)"
    else
        pass "negative control: $name makes the assertion fail"
    fi
}
# Sanity: the same assertions pass on the real files.
if a_accuracy "$units_dir" && a_no_umask "$units_dir" && a_server_post_dash "$units_dir" && a_tap_interval "$units_dir" && a_oneshot "$units_dir"; then
    pass 'negative control: assertions pass on the real files'
else
    fail 'negative control: assertions pass on the real files'
fi
mutate 'dropping AccuracySec from the tap timer' '/^AccuracySec=/d' $TAP_TIMER a_accuracy
mutate 'dropping AccuracySec from the trim timer' '/^AccuracySec=/d' $TRIM_TIMER a_accuracy
mutate 'AccuracySec=1min' 's/^AccuracySec=.*/AccuracySec=1min/' $TRIM_TIMER a_accuracy
mutate 'ExecStartPost without the "-"' 's|^ExecStartPost=-|ExecStartPost=|' $SERVER a_server_post_dash
mutate 'adding UMask=0077' '/^Restart=/a UMask=0077' $SERVER a_no_umask
mutate 'tap interval 60s' 's/^OnUnitActiveSec=.*/OnUnitActiveSec=60s/' $TAP_TIMER a_tap_interval
mutate 'tap service as Type=simple' 's/^Type=oneshot/Type=simple/' $TAP a_oneshot
# The required-keys check itself, on a copy with AccuracySec dropped.
rm -rf -- "$broken"; mkdir -p "$broken"
for u in $ALL_UNITS; do cp -- "$units_dir/$u" "$broken/$u"; done
sed -i '/^AccuracySec=/d' "$broken/$TAP_TIMER"
if required "$broken" "$TAP_TIMER" >/dev/null 2>&1; then fail 'negative control: required keys notice a missing AccuracySec'; else pass 'negative control: required keys notice a missing AccuracySec'; fi
printf 'not a directive\n' >> "$broken/$TAP_TIMER"
if parses "$broken" "$TAP_TIMER" >/dev/null 2>&1; then fail 'negative control: syntax check rejects a junk line'; else pass 'negative control: syntax check rejects a junk line'; fi

# ---- summary ------------------------------------------------------------------------
printf '\n%d passed, %d failed, %d skipped\n' "$pass_count" "$fail_count" "$skip_count"
if [ "$fail_count" -eq 0 ]; then printf 'RESULT: PASS\n'; exit 0; fi
printf 'RESULT: FAIL\n'
exit 1
