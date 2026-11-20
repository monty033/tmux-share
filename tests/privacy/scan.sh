#!/usr/bin/env bash
set -eu

# Resolve the repository root from this script's own location so the scanner
# works on a temporary copy of the tree just as it does on the checkout.
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/../.." && pwd)

# Detector definitions.
#
# Every pattern is assembled from fragments. The literal text that each
# detector searches for is therefore never written out in this file, so a
# scan of a clean tree (which includes this script) stays clean. The
# acceptance test asserts that property explicitly.
dot='\.'
oct='[0-9]{1,3}'
ip_a="10${dot}${oct}${dot}${oct}${dot}${oct}"
ip_b="172${dot}(1[6-9]|2[0-9]|3[01])${dot}${oct}${dot}${oct}"
ip_c="192${dot}168${dot}${oct}${dot}${oct}"

five='-----'
pem="^${five}BEGIN"

eq='='
val='[^[:space:]]+'
assign="([Tt][Oo][Kk][Ee][Nn]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd])[[:space:]]*${eq}[[:space:]]*${val}"

at=$'\x40'
email="[A-Za-z0-9._%+-]+${at}[A-Za-z0-9.-]+[.][A-Za-z]{2,}"

slash='/'
home="${slash}home${slash}[A-Za-z0-9._-]+"
varlib="${slash}var${slash}lib${slash}[A-Za-z0-9._-]+"

findings=''
count=0

add_matches() {
  # $1 = relative path, $2 = grep output (possibly empty).
  [ -n "$2" ] || return 0
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    findings="${findings}$1:${row}"$'\n'
    count=$((count + 1))
  done <<< "$2"
}

list_files() {
  find "$repo_root" \( -type d \( -name .git -o -name fixtures \) -prune \) -o -type f -print
}

while IFS= read -r file; do
  [ -n "$file" ] || continue
  rel=${file#"$repo_root"/}
  hits=$(grep -nE -e "$ip_a" -e "$ip_b" -e "$ip_c" -e "$pem" \
    -e "$assign" -e "$email" -e "$home" -e "$varlib" -- "$file" 2>/dev/null || true)
  add_matches "$rel" "$hits"
done < <(list_files)

# Optional, never-committed denylist of literal strings.
if [ -n "${TMUX_SHARE_DENYLIST:-}" ] && [ -r "$TMUX_SHARE_DENYLIST" ]; then
  while IFS= read -r needle || [ -n "$needle" ]; do
    case "$needle" in
      ''|'#'*) continue ;;
    esac
    while IFS= read -r file; do
      [ -n "$file" ] || continue
      rel=${file#"$repo_root"/}
      hits=$(grep -nF -e "$needle" -- "$file" 2>/dev/null || true)
      add_matches "$rel" "$hits"
    done < <(list_files)
  done < "$TMUX_SHARE_DENYLIST"
fi

if [ "$count" -gt 0 ]; then
  printf '%s' "$findings"
  exit 1
fi

printf 'privacy scan clean: no private data found in %s\n' "$repo_root"
exit 0
