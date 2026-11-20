# Canonical entry points for this repository.
#
# `just test` is the whole suite. Nothing else is authoritative, so this file
# cannot drift from the list of suites: it just calls the runner, which owns it.
set shell := ["bash", "-uc"]

_repo := justfile_directory()

# List the recipes
default:
    @just --list

# Run every suite (this is the one that must stay green)
test:
    @bash "{{_repo}}/tests/run-all.sh"

# Static checks: shell syntax, shellcheck when installed, python compile
lint:
    #!/usr/bin/env bash
    set -uo pipefail
    repo="{{_repo}}"
    fail=0
    for f in "$repo"/core/lib/*.sh "$repo"/core/bin/* "$repo"/tests/run-all.sh; do
        bash -n "$f" || { echo "syntax error: $f"; fail=1; }
    done
    if command -v shellcheck >/dev/null 2>&1; then
        shellcheck -x -S warning "$repo"/core/lib/*.sh "$repo"/core/bin/* "$repo"/tests/run-all.sh \
            || fail=1
    else
        echo "lint: shellcheck not installed, skipped"
    fi
    python3 -m py_compile "$repo"/core/tmux-share-stamp \
        "$repo"/hermes-plugin/tools.py "$repo"/hermes-plugin/tmux_share_reader/boundary.py || fail=1
    echo "lint: $([ "$fail" -eq 0 ] && echo ok || echo failed)"
    exit "$fail"

# Prove the suites can fail: seven deliberate regressions, each restored
mutate:
    @bash "{{_repo}}/tests/mutation/mutation_test.sh"

# The disposable end-to-end self-test against a scratch tmux server
selftest:
    @bash "{{_repo}}/core/bin/tmux-share-selftest"

# Check a live deployment without changing anything
verify:
    @bash "{{_repo}}/core/bin/tmux-share-verify"

# Remove build and interpreter leftovers
clean:
    @rm -rf "{{_repo}}/result" "{{_repo}}/__pycache__" "{{_repo}}"/hermes-plugin/__pycache__ \
        "{{_repo}}"/hermes-plugin/tmux_share_reader/__pycache__ "{{_repo}}"/tests/**/__pycache__
    @find "{{_repo}}" -name '*.pyc' -delete
    @echo "clean: done"
