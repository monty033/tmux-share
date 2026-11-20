#!/usr/bin/env bash
# Parity: the NixOS module and the plain systemd templates must deploy the
# same thing, or the two install paths drift apart without anyone noticing.
#
# The module is evaluated in a minimal NixOS configuration (nix/module.nix,
# through the flake's nixosModules.default). The units, the tmpfiles rules and
# the tmux and env files it renders are read back and compared, property by
# property, with the files in systemd/.
#
# Comparison is of meaning, not of text: whitespace is trimmed, and a time
# span is compared in seconds, so 20s, 20 and 20 seconds all agree.
#
# The one allowed difference: the command path. The module runs store paths
# (/nix/store/...-tmux-3.7b/bin/tmux) and the templates run /usr/bin and
# /usr/local/bin paths. So ExecStart and ExecStartPost are compared by the
# command's basename and by their arguments, never by the full string. The
# leading "-" of ExecStartPost is compared on its own.
#
# Needs nix with flakes. Without nix on PATH every check is SKIPped with the
# reason "nix not available", and the suite exits 0: a missing tool is not a
# failure, but it must stay visible.
#
# Offline: set TMUX_SHARE_NIXPKGS to a local nixpkgs checkout (an absolute
# path). It is passed as --override-input nixpkgs path:... Without it, the
# suite asks nix for the pinned nixpkgs, which needs the network: a download
# failure is a SKIP with that reason, any other failure is a FAIL.
#
# Exit status: 0 PASS or SKIP; 1 at least one check failed.
set -u

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)

# Read the one variable this suite takes from the environment before the
# environment is cleaned: a TMUX_SHARE_* value from an earlier shell must not
# steer the evaluation, except the nixpkgs path that is asked for on purpose.
nixpkgs_src=${TMUX_SHARE_NIXPKGS:-}
for v in $(env | grep -o '^TMUX_SHARE_[A-Z_]*' || true); do unset "$v"; done

# A stock NixOS login may not have the usual PATH; nix and git live there.
case ":$PATH:" in
    *:/run/current-system/sw/bin:*) ;;
    *) [ -d /run/current-system/sw/bin ] && PATH="/run/current-system/sw/bin:$PATH" ;;
esac
export PATH

# shellcheck source=../../core/lib/checks.sh
. "$repo_root/core/lib/checks.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/parity-test.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# The network-failure signatures of nix. A failed download is the offline
# host, which is a SKIP; anything else is a FAIL.
NETWORK_RE='unable to download|could not resolve|couldn.t resolve|temporary failure in name resolution|network is unreachable|failed to connect|connection (timed out|refused|reset)|failed to download|cannot download|timed out'

# The sections the module expression prints, named as the unit files are, so
# that a module file and its template are compared by the same name.
SECTIONS=(
    tmux-share-server.service
    tmux-share-tap.service
    tmux-share-tap.timer
    tmux-share-trim.service
    tmux-share-trim.timer
    tmux-share.tmpfiles
    tmux-share.conf
    tmux-share.env
)
UNITS=(
    tmux-share-server.service
    tmux-share-tap.service
    tmux-share-tap.timer
    tmux-share-trim.service
    tmux-share-trim.timer
)
MOD_DIR=$work/mod
TPL_DIR=$repo_root/systemd

# The module, applied to the flake's nixosModules.default. It builds a minimal
# NixOS system around the module (the same settings as the flake's own
# module-renders check) and prints each rendered file as a "@@ NAME" section.
# Store paths are discarded from the string context: this reads text and runs
# nothing. The nixpkgs tree comes from TMUX_SHARE_PARITY_NIXPKGS, which the
# suite sets to the same tree the flake was locked against.
read -r -d '' APPLY <<'NIX' || true
mod:
let
  p = builtins.getEnv "TMUX_SHARE_PARITY_NIXPKGS";
  lib = import (p + "/lib");
  sys = import (p + "/nixos/lib/eval-config.nix") {
    system = builtins.currentSystem;
    modules = [
      mod
      {
        services.tmux-share.enable = true;
        boot.loader.grub.enable = false;
        fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
        system.stateVersion = lib.versions.majorMinor lib.version;
      }
    ];
  };
  c = sys.config;
  text = builtins.unsafeDiscardStringContext;
  section = name: body: "@@ ${name}\n${body}\n";
  unit = name: text c.systemd.units.${name}.text;
in
lib.concatStrings [
  (section "tmux-share-server.service" (unit "tmux-share-server.service"))
  (section "tmux-share-tap.service" (unit "tmux-share-tap.service"))
  (section "tmux-share-tap.timer" (unit "tmux-share-tap.timer"))
  (section "tmux-share-trim.service" (unit "tmux-share-trim.service"))
  (section "tmux-share-trim.timer" (unit "tmux-share-trim.timer"))
  (section "tmux-share.tmpfiles" (text (lib.concatStringsSep "\n" c.systemd.tmpfiles.rules)))
  (section "tmux-share.conf" (text c.environment.etc."tmux-share/tmux.conf".text))
  (section "tmux-share.env" (text c.environment.etc."tmux-share/env".text))
]
NIX

# ---- the outcome of the whole suite -----------------------------------------
# When set, every check is recorded as SKIP (SKIP_ALL) or FAIL (FAIL_ALL) with
# that reason, instead of being run. begin() does it, so the list of checks
# lives in one place.
SKIP_ALL=''
FAIL_ALL=''
nixpkgs_dir=''
override=()

# begin NAME: open a check. Returns 1 when the check is already settled.
begin() {
    check_begin "$1"
    if [ -n "$SKIP_ALL" ]; then check_skip "$SKIP_ALL"; return 1; fi
    if [ -n "$FAIL_ALL" ]; then check_fail "$FAIL_ALL"; return 1; fi
    return 0
}

# eval_failure WHAT ERRFILE: a failed nix call is a SKIP when it is a download
# (the offline host), and a FAIL otherwise.
eval_failure() {
    local first
    if grep -qiE "$NETWORK_RE" -- "$2"; then
        SKIP_ALL="$1 needs the network to download nixpkgs; set TMUX_SHARE_NIXPKGS to a local nixpkgs checkout to run offline"
    else
        first=$(head -c 300 -- "$2" | tr '\n' ' ')
        FAIL_ALL="$1 failed: ${first:-no output from nix}"
    fi
}

# resolve_nixpkgs: find the nixpkgs tree that both the flake and the
# evaluation read. The override is named explicitly, as --override-input.
resolve_nixpkgs() {
    local rc=0
    if [ -n "$nixpkgs_src" ]; then
        case $nixpkgs_src in
            /*) ;;
            *) FAIL_ALL="TMUX_SHARE_NIXPKGS must be an absolute path, got '$nixpkgs_src'"; return 0 ;;
        esac
        if [ ! -f "$nixpkgs_src/nixos/lib/eval-config.nix" ]; then
            FAIL_ALL="TMUX_SHARE_NIXPKGS=$nixpkgs_src is not a nixpkgs tree (nixos/lib/eval-config.nix is missing)"
            return 0
        fi
        nixpkgs_dir=$nixpkgs_src
        override=(--override-input nixpkgs "path:$nixpkgs_dir")
        return 0
    fi
    # Plain: ask nix which nixpkgs the flake lock pins. Needs the network
    # unless the store already holds that tree.
    nixpkgs_dir=$(cd -- "$repo_root" && nix --extra-experimental-features 'nix-command flakes' \
        eval --raw --no-write-lock-file --impure \
        --expr '(builtins.getFlake (toString ./.)).inputs.nixpkgs.outPath' 2> "$work/plain.err") || rc=$?
    if [ "$rc" -ne 0 ]; then
        eval_failure 'resolving the pinned nixpkgs' "$work/plain.err"
    fi
    return 0
}

# evaluate_module: render the module into $work/module.txt. --no-write-lock-file
# keeps the flake lock untouched whatever the override says.
evaluate_module() {
    local rc=0
    (cd -- "$repo_root" && TMUX_SHARE_PARITY_NIXPKGS=$nixpkgs_dir nix \
        --extra-experimental-features 'nix-command flakes' \
        eval --raw --no-write-lock-file --impure ${override[@]+"${override[@]}"} \
        '.#nixosModules.default' --apply "$APPLY" \
        > "$work/module.txt" 2> "$work/eval.err") || rc=$?
    if [ "$rc" -ne 0 ]; then
        eval_failure 'evaluating the module' "$work/eval.err"
    fi
    return 0
}

# load_module: split the printed sections into files under $MOD_DIR.
load_module() {
    local line name='' s
    mkdir -p -- "$MOD_DIR"
    while IFS= read -r line || [ -n "$line" ]; do
        case $line in
            '@@ '*) name=${line#@@ }; : > "$MOD_DIR/$name"; continue ;;
        esac
        if [ -n "$name" ]; then printf '%s\n' "$line" >> "$MOD_DIR/$name"; fi
    done < "$work/module.txt"
    for s in "${SECTIONS[@]}"; do
        if [ ! -f "$MOD_DIR/$s" ]; then
            FAIL_ALL="the module output has no $s section"
            return 0
        fi
    done
}

# ---- parsing ------------------------------------------------------------------

# trim TEXT: TEXT without leading and trailing blanks.
trim() {
    local v=$1
    v=${v#"${v%%[![:space:]]*}"}
    v=${v%"${v##*[![:space:]]}"}
    printf '%s' "$v"
}

# ini FILE KEY: the last value of KEY outside comments, trimmed; empty when
# the key is absent.
ini() {
    local line=''
    line=$(grep -E "^[[:space:]]*$2=" -- "$1" | tail -n 1) || true
    trim "${line#*=}"
}

# exec_split VALUE: sets EX_PREFIX ("-" or empty), EX_CMD (the command's
# basename) and EX_ARGS (the arguments, single-spaced). The command's
# directory is dropped here: that is the one allowed difference.
exec_split() {
    local -a words=()
    read -r -a words <<< "$1" || true
    EX_PREFIX=''
    EX_CMD=''
    EX_ARGS=''
    [ "${#words[@]}" -gt 0 ] || return 0
    EX_CMD=${words[0]}
    case $EX_CMD in
        -*) EX_PREFIX=-; EX_CMD=${EX_CMD#-} ;;
    esac
    EX_CMD=${EX_CMD##*/}
    EX_ARGS=${words[*]:1}
}

# to_secs VALUE: a systemd time span as whole seconds. "20s", "20" are 20 and
# "5min" is 300. Anything else prints "?VALUE", which never agrees.
to_secs() {
    local v=$1 n mult=1
    case $v in
        *min) mult=60; n=${v%min} ;;
        *s) n=${v%s} ;;
        *) n=$v ;;
    esac
    case $n in
        ''|*[!0-9]*) printf '?%s' "$v" ;;
        *) printf '%s' $((n * mult)) ;;
    esac
}

# as_bool VALUE: a systemd boolean. An absent key reads as "no".
as_bool() {
    case $1 in
        ''|no|false|off|0) printf 'no' ;;
        yes|true|on|1) printf 'yes' ;;
        *) printf '?%s' "$1" ;;
    esac
}

# count_umask FILE: the number of UMask= lines outside comments.
count_umask() {
    grep -cE '^[[:space:]]*UMask=' -- "$1" || true
}

# tmpfiles_rule FILE PATH: the rule for PATH with its fields single-spaced;
# empty when there is none.
tmpfiles_rule() {
    local line
    local -a f=()
    while IFS= read -r line || [ -n "$line" ]; do
        case $line in
            ''|'#'*) continue ;;
        esac
        read -r -a f <<< "$line"
        if [ "${f[1]:-}" = "$2" ]; then
            printf '%s\n' "${f[*]}"
            return 0
        fi
    done < "$1"
}

# script_session_default FILE: the session name a script falls back to.
script_session_default() {
    local line='' re=':-([^}]*)}'
    line=$(grep -E '^[A-Z_]*SESSION=[$][{]TMUX_SHARE_SESSION:-' -- "$1" | head -n 1) || true
    if [[ $line =~ $re ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    fi
}

# ---- comparisons (each records into the open check) -----------------------------

# agree WHAT MODULE TEMPLATE: one pass when the two values are equal.
agree() {
    if [ "$2" = "$3" ]; then
        check_pass
    else
        check_fail "$1: module has '$2', template has '$3'"
    fi
}

# want WHAT GOT EXPECTED: one pass when the value is the one the contract names.
want() {
    if [ "$2" = "$3" ]; then
        check_pass
    else
        check_fail "$1: is '$2', expected '$3'"
    fi
}

# secs_agree LABEL UNIT KEY WANT_SECONDS: KEY of UNIT agrees between the module
# and the template, in seconds, and equals WANT_SECONDS.
secs_agree() {
    local m t
    m=$(to_secs "$(ini "$MOD_DIR/$2" "$3")")
    t=$(to_secs "$(ini "$TPL_DIR/$2" "$3")")
    agree "$1 $3" "$m" "$t"
    want "$1 $3 (seconds)" "$t" "$4"
}

# oneshot_agree LABEL UNIT COMMAND: a oneshot service in the module and the
# template has the same type, runs COMMAND, keeps no RemainAfterExit, and
# reads the same environment file (checked by c_env_file).
oneshot_agree() {
    local label=$1 unit=$2 cmd=$3 mcmd margs tcmd targs ttype rae
    agree "$label Type" "$(ini "$MOD_DIR/$unit" Type)" "$(ini "$TPL_DIR/$unit" Type)"
    ttype=$(ini "$TPL_DIR/$unit" Type)
    want "$label Type" "$ttype" oneshot
    exec_split "$(ini "$MOD_DIR/$unit" ExecStart)"
    mcmd=$EX_CMD
    margs=$EX_ARGS
    exec_split "$(ini "$TPL_DIR/$unit" ExecStart)"
    tcmd=$EX_CMD
    targs=$EX_ARGS
    agree "$label ExecStart command (basename)" "$mcmd" "$tcmd"
    agree "$label ExecStart arguments" "$margs" "$targs"
    want "$label ExecStart runs $cmd" "$tcmd" "$cmd"
    agree "$label RemainAfterExit" \
        "$(as_bool "$(ini "$MOD_DIR/$unit" RemainAfterExit)")" \
        "$(as_bool "$(ini "$TPL_DIR/$unit" RemainAfterExit)")"
    rae=$(as_bool "$(ini "$TPL_DIR/$unit" RemainAfterExit)")
    want "$label RemainAfterExit is no (the next timer tick must run it again)" "$rae" no
}

# rule_agree PATH MODE LABEL: the tmpfiles rule for PATH agrees between the
# module and the template, and its mode is MODE.
rule_agree() {
    local mrule trule tmode
    mrule=$(tmpfiles_rule "$MOD_DIR/tmux-share.tmpfiles" "$1")
    trule=$(tmpfiles_rule "$TPL_DIR/tmux-share.tmpfiles" "$1")
    agree "$3 rule" "$mrule" "$trule"
    read -r _ _ tmode _ <<< "$trule" || true
    want "$3 mode in the template" "$tmode" "$2"
}

# ---- the checks ---------------------------------------------------------------

c_server_exec() {
    begin 'module and template agree: server ExecStart' || return 0
    exec_split "$(ini "$MOD_DIR/tmux-share-server.service" ExecStart)"
    local mcmd=$EX_CMD margs=$EX_ARGS
    exec_split "$(ini "$TPL_DIR/tmux-share-server.service" ExecStart)"
    local tcmd=$EX_CMD targs=$EX_ARGS
    # The allowed difference (see the header): the command by basename.
    agree 'server ExecStart command (basename)' "$mcmd" "$tcmd"
    agree 'server ExecStart arguments' "$margs" "$targs"
    want 'server ExecStart arguments are the foreground server' "$targs" \
        '-D -S /run/tmux-share/tmux.sock -f /etc/tmux-share/tmux.conf'
}

c_server_post() {
    begin 'module and template agree: server ExecStartPost' || return 0
    exec_split "$(ini "$MOD_DIR/tmux-share-server.service" ExecStartPost)"
    local mpre=$EX_PREFIX mcmd=$EX_CMD margs=$EX_ARGS
    exec_split "$(ini "$TPL_DIR/tmux-share-server.service" ExecStartPost)"
    local tpre=$EX_PREFIX tcmd=$EX_CMD targs=$EX_ARGS
    agree 'server ExecStartPost starts with "-"' "$mpre" "$tpre"
    want 'server ExecStartPost starts with "-" (a failed tap must not stop the server)' "$tpre" '-'
    agree 'server ExecStartPost command (basename)' "$mcmd" "$tcmd"
    agree 'server ExecStartPost arguments' "$margs" "$targs"
    want 'server ExecStartPost runs the tap' "$tcmd" tmux-share-tap-start
}

c_server_restart() {
    begin 'module and template agree: server Restart' || return 0
    agree 'server Restart' \
        "$(ini "$MOD_DIR/tmux-share-server.service" Restart)" \
        "$(ini "$TPL_DIR/tmux-share-server.service" Restart)"
    want 'server Restart' "$(ini "$TPL_DIR/tmux-share-server.service" Restart)" on-failure
}

c_env_file() {
    begin 'module and template agree: EnvironmentFile' || return 0
    agree 'server EnvironmentFile' \
        "$(ini "$MOD_DIR/tmux-share-server.service" EnvironmentFile)" \
        "$(ini "$TPL_DIR/tmux-share-server.service" EnvironmentFile)"
    want 'server EnvironmentFile (the "-" lets the server start without it)' \
        "$(ini "$TPL_DIR/tmux-share-server.service" EnvironmentFile)" '-/etc/tmux-share/env'
    local u
    for u in tmux-share-tap.service tmux-share-trim.service; do
        agree "$u EnvironmentFile" "$(ini "$MOD_DIR/$u" EnvironmentFile)" "$(ini "$TPL_DIR/$u" EnvironmentFile)"
        want "$u EnvironmentFile (no '-': a missing file fails the pass)" \
            "$(ini "$TPL_DIR/$u" EnvironmentFile)" /etc/tmux-share/env
    done
}

c_no_umask() {
    begin 'module and template agree: no UMask' || return 0
    # A UMask on any unit would become the umask of every shell the operator
    # opens inside the server.
    local u
    for u in "${UNITS[@]}"; do
        want "module $u has no UMask=" "$(count_umask "$MOD_DIR/$u")" 0
        want "template $u has no UMask=" "$(count_umask "$TPL_DIR/$u")" 0
    done
}

c_session() {
    begin 'module and template agree: session name' || return 0
    local line re mconf='' menv='' s d
    re='^new-session -d -s ([^ ]+)'
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ $line =~ $re ]]; then mconf=${BASH_REMATCH[1]}; fi
    done < "$MOD_DIR/tmux-share.conf"
    re="^TMUX_SHARE_SESSION='([^']*)'"
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ $line =~ $re ]]; then menv=${BASH_REMATCH[1]}; fi
    done < "$MOD_DIR/tmux-share.env"
    agree 'session: tmux.conf new-session vs env TMUX_SHARE_SESSION' "$mconf" "$menv"
    # The plain path has no tmux.conf template: its session is the default the
    # scripts fall back to, and the module must name the same one.
    for s in tmux-share-tap-start tmux-share-watchdog tmux-share-trim; do
        d=$(script_session_default "$repo_root/core/bin/$s")
        agree "session: module vs the default in $s" "$mconf" "$d"
    done
    want 'session name is the contract default' "$mconf" tmux-hermes
}

c_tap_service() {
    begin 'module and template agree: tap service' || return 0
    oneshot_agree tap tmux-share-tap.service tmux-share-watchdog
}

c_trim_service() {
    begin 'module and template agree: trim service' || return 0
    oneshot_agree trim tmux-share-trim.service tmux-share-trim
}

c_timer_interval() {
    begin 'module and template agree: timer interval' || return 0
    secs_agree 'tap timer' tmux-share-tap.timer OnBootSec 20
    secs_agree 'tap timer' tmux-share-tap.timer OnUnitActiveSec 20
    secs_agree 'trim timer' tmux-share-trim.timer OnUnitActiveSec 300
}

c_timer_accuracy() {
    begin 'module and template agree: timer accuracy' || return 0
    secs_agree 'tap timer' tmux-share-tap.timer AccuracySec 1
    secs_agree 'trim timer' tmux-share-trim.timer AccuracySec 1
}

c_dir_mode() {
    begin 'module and template agree: directory mode 0710' || return 0
    rule_agree /run/tmux-share 0710 'runtime directory'
}

c_transcript_mode() {
    begin 'module and template agree: transcript mode 0640' || return 0
    rule_agree /run/tmux-share/transcript.log 0640 transcript
}

c_lock_mode() {
    begin 'module and template agree: lock mode 0600' || return 0
    rule_agree /run/tmux-share.lock 0600 lock
}

CHECKS=(
    c_server_exec
    c_server_post
    c_server_restart
    c_env_file
    c_no_umask
    c_session
    c_tap_service
    c_trim_service
    c_timer_interval
    c_timer_accuracy
    c_dir_mode
    c_transcript_mode
    c_lock_mode
)

# ---- run ------------------------------------------------------------------------

if ! command -v nix >/dev/null 2>&1; then
    SKIP_ALL='nix not available'
else
    resolve_nixpkgs
    if [ -z "$SKIP_ALL" ] && [ -z "$FAIL_ALL" ]; then
        evaluate_module
    fi
    if [ -z "$SKIP_ALL" ] && [ -z "$FAIL_ALL" ]; then
        load_module
    fi
fi

for c in "${CHECKS[@]}"; do
    "$c"
done

rc=0
check_summary || rc=1
exit "$rc"
