#!/usr/bin/env bash
# Every command in core/bin and core/ must be executable and carry a shebang
# naming a portable interpreter.
#
# The verifier shipped non-executable once. Nothing caught it: the unit tests
# invoked it through bash explicitly, so the missing mode only surfaced when
# the self-test tried to exec it and got exit 126. This test is the guard.
set -u

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo=$(cd -- "$here/../.." && pwd -P)
. "$repo/core/lib/checks.sh"

files=0
for f in "$repo"/core/bin/*; do
    [ -e "$f" ] || continue
    files=$((files + 1))
    name=$(basename "$f")

    check_begin "bash command $name: executable and portable"
    if [ -x "$f" ]; then
        check_pass
    else
        check_fail "mode is $(stat -c '%a' "$f")"
    fi
    first=$(head -n 1 "$f")
    if [ "$first" = '#!/usr/bin/env bash' ]; then
        check_pass
    else
        check_fail "shebang is not '#!/usr/bin/env bash': $first"
    fi
done

check_begin "core/bin is populated"
if [ "$files" -ge 6 ]; then check_pass; else check_fail "only $files commands found"; fi

# The stamp filter is Python, and it must ask the environment for it: a store
# path or a distro-specific python is not portable.
stamp="$repo/core/tmux-share-stamp"
check_begin "python command tmux-share-stamp: executable and portable"
if [ -x "$stamp" ]; then
    check_pass
else
    check_fail "mode is $(stat -c '%a' "$stamp")"
fi
first=$(head -n 1 "$stamp")
if [ "$first" = '#!/usr/bin/env python3' ]; then
    check_pass
else
    check_fail "shebang is not '#!/usr/bin/env python3': $first"
fi

# Libraries are sourced, never executed; they only have to be readable.
for lib in "$repo"/core/lib/*.sh; do
    check_begin "lib $(basename "$lib") readable"
    if [ -r "$lib" ]; then check_pass; else check_fail "not readable"; fi
done

check_summary "core command modes"
