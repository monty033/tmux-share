#!/usr/bin/env bash
# notready.sh: bounded grace for "the tmux server is not ready yet".
#
# Source this file from the watchdog or the trimmer; do not execute it.
# It sets no shell options and is safe to source into `set -eu` scripts.
# Always call the functions from an `if`, `||` or `&&` context so that a
# return of 1 (fail) is handled rather than aborting under `set -e`.
#
# Why: during activation or a server restart the tmux server is briefly
# absent. Failing at once makes systemd report a failed unit for a harmless
# blip; excusing every error forever hides a real outage. So the first pass
# that sees "not ready" records a marker with the time it was first seen,
# passes inside the grace window are excused, and once the window has
# expired the pass fails. Any successful pass clears the marker.
#
# API
#   notready_check   Call when a pass observed the server NOT ready.
#                    Returns 0 = excuse this pass (inside the grace window),
#                    1 = fail this pass. The first call stamps the marker.
#   server_ready     Call when a pass succeeded. Removes the marker.
#                    Returns 0 on success, 1 if the marker cannot be removed.
#
# Environment
#   TMUX_SHARE_NOTREADY_MARKER  Required. Path of the marker file. The caller
#                               picks it (for example beside the transcript);
#                               the library never invents a location.
#   TMUX_SHARE_NOTREADY_GRACE   Grace length in whole seconds. Default 300.
#   TMUX_SHARE_UPTIME_FILE      Clock source. Default /proc/uptime. Only the
#                               integer part before the first space is used.
#                               Tests inject a file here.
#
# Design notes
#   * Wall-clock time is never used: a clock step (NTP, manual set, resume)
#     would stretch or shrink the grace. Uptime only moves forward.
#   * The marker holds one decimal integer: the uptime second at first sight.
#   * The marker is written atomically: mktemp in the marker's own directory
#     (a unique name per writer, so concurrent watchdog and trimmer passes
#     cannot break each other's rename), write, chmod 0600, rename.
#   * A marker that is empty, non-numeric, longer than 10 digits, multi-line,
#     or in the future relative to the clock is not trusted. It is re-stamped
#     and the pass is excused once, so a corrupt marker never fails the very
#     first pass.
#   * Fail closed: if the clock, the configuration or the marker write is
#     unusable, notready_check returns 1. An unwritable marker that excused
#     forever would hide an outage.

# Print a diagnostic on stderr.
_notready_warn() {
  printf 'notready: %s\n' "$1" >&2
}

# Print the current uptime second (integer part) on stdout.
_notready_now() {
  local clock=${TMUX_SHARE_UPTIME_FILE:-/proc/uptime}
  local first=''
  if ! { IFS=' ' read -r first _ < "$clock"; } 2>/dev/null; then
    # A final line without a newline still fills $first; accept that.
    [ -n "$first" ] || return 1
  fi
  first=${first%%.*}
  if [[ ! $first =~ ^[0-9]{1,10}$ ]]; then
    return 1
  fi
  printf '%s\n' "$((10#$first))"
}

# Print the stamp stored in the marker on stdout.
# Returns 1 if the marker is missing or not a plain integer of 1-10 digits.
_notready_read() {
  local marker=$1 content=''
  [ -f "$marker" ] || return 1
  # Read at most 32 bytes: enough to reject anything over-long, and bounded
  # even if the file is huge. NUL bytes are discarded with a warning that is
  # silenced here; the result then fails the digit check anyway.
  { IFS= read -r -N 32 content < "$marker"; } 2>/dev/null || true
  content=${content%$'\n'}
  if [[ ! $content =~ ^[0-9]{1,10}$ ]]; then
    return 1
  fi
  printf '%s\n' "$((10#$content))"
}

# Atomically write the integer $2 to marker $1 with mode 0600.
_notready_stamp() {
  local marker=$1 stamp=$2 tmp=''
  [ ! -d "$marker" ] || return 1
  tmp=$(mktemp "$marker.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$stamp" > "$tmp" 2>/dev/null \
    || ! chmod 0600 "$tmp" 2>/dev/null \
    || ! mv -f -- "$tmp" "$marker" 2>/dev/null; then
    rm -f -- "$tmp" 2>/dev/null || true
    return 1
  fi
}

notready_check() {
  local marker=${TMUX_SHARE_NOTREADY_MARKER:-}
  local grace=${TMUX_SHARE_NOTREADY_GRACE:-300}
  local now='' start=''

  if [ -z "$marker" ]; then
    _notready_warn 'TMUX_SHARE_NOTREADY_MARKER is not set'
    return 1
  fi
  if [[ ! $grace =~ ^[0-9]{1,9}$ ]]; then
    _notready_warn 'TMUX_SHARE_NOTREADY_GRACE must be whole seconds'
    return 1
  fi
  grace=$((10#$grace))

  if ! now=$(_notready_now); then
    _notready_warn 'cannot read a usable clock'
    return 1
  fi

  # Trust the marker only if it is a sane stamp that is not in the future.
  if start=$(_notready_read "$marker") && [ "$start" -le "$now" ]; then
    [ "$((now - start))" -lt "$grace" ]
    return
  fi

  # Missing, corrupt or future stamp: start the window now.
  if ! _notready_stamp "$marker" "$now"; then
    _notready_warn 'cannot write marker; failing the pass'
    return 1
  fi
  [ 0 -lt "$grace" ]
}

server_ready() {
  local marker=${TMUX_SHARE_NOTREADY_MARKER:-}
  if [ -z "$marker" ]; then
    _notready_warn 'TMUX_SHARE_NOTREADY_MARKER is not set'
    return 1
  fi
  rm -f -- "$marker" 2>/dev/null || return 1
}
