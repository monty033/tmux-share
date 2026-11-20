#!/usr/bin/env bash
set -eu

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/../.." && pwd)
source_scanner="${script_dir}/scan.sh"

tmp_root=$(mktemp -d)
trap 'rm -rf -- "$tmp_root"' EXIT HUP INT TERM

# Build a temporary copy of the tree layout. The repository itself is never
# written to; all fixtures live under the temporary directory.
tree="${tmp_root}/tree"
mkdir -p "${tree}/tests/privacy"
scanner="${tree}/tests/privacy/scan.sh"
cp -- "$source_scanner" "$scanner"
cp -- "${repo_root}/.gitignore" "${tree}/.gitignore"

fixture="${tree}/leak.txt"

# Fixture contents are assembled at run time so no private-looking example
# is ever committed in this file.
dot='.'
at=$'\x40'
five='-----'
slash='/'

ip_line="address 10${dot}1${dot}2${dot}3"
pem_line="${five}BEGIN OPENSSH PRIVATE KEY${five}"
secret_key=$(printf 'TOK%s' EN)
secret_value=$(printf 'ab%s' c123)
token_line="${secret_key}=${secret_value}"
mail_line="some${at}test${dot}invalid"
home_line="${slash}home${slash}someone"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

expect_detected() {
  label=$1
  line=$2
  printf '%s\n' "$line" > "$fixture"
  if output=$("$BASH" "$scanner" 2>&1); then rc=0; else rc=$?; fi
  [ "$rc" -eq 1 ] || fail "${label}: expected exit 1, got ${rc}; output: ${output}"
  printf 'PASS: %s rejected (exit 1)\n' "$label"
}

expect_detected 'RFC1918 IPv4 address' "$ip_line"
expect_detected 'PEM private-key header' "$pem_line"
expect_detected 'token assignment' "$token_line"
expect_detected 'email address' "$mail_line"
expect_detected 'home path' "$home_line"

# A clean copy of the tree includes the scanner itself, so this also proves
# the scanner does not trigger on its own detection patterns.
rm -f -- "$fixture"
if output=$("$BASH" "$scanner" 2>&1); then rc=0; else rc=$?; fi
[ "$rc" -eq 0 ] || fail "clean tree: expected exit 0, got ${rc}; output: ${output}"
printf 'PASS: clean tree accepted (exit 0)\n'

# Some minimal hosts expose git outside PATH; resolve it without embedding a
# machine-specific location, then use the ordinary git command below.
git_bin=$(command -v git || true)
if [ -z "$git_bin" ] && [ -x "${BASH%/*}/git" ]; then
  git_bin="${BASH%/*}/git"
fi
[ -n "$git_bin" ] || fail 'git executable not found'
PATH="${git_bin%/*}:$PATH"
export PATH

if (cd -- "$repo_root" && git check-ignore -q evidence/configuration.nix); then
  printf 'PASS: evidence/configuration.nix is ignored\n'
else
  fail 'git check-ignore did not ignore evidence/configuration.nix'
fi

printf 'ALL PRIVACY GATE CHECKS PASSED\n'
