#!/bin/sh
# Fixture snapshot test.
#
# Usage:
#   ./scripts/test-fixtures.sh            # check fixtures against the snapshot
#   ./scripts/test-fixtures.sh --update   # regenerate the snapshot
#
# The files under test/fixtures/ are deliberately broken: each exists to trip a
# specific rule (and each language has a valid.* that must stay clean). This
# runs jab over them in --format=json mode and diffs the diagnostics against a
# committed golden file. It catches regressions the unit tests can't — a rule
# that silently stops firing, a changed message or location, or a valid.*
# fixture that starts producing diagnostics.
#
# Requires a built binary (zig build). Override its path with JAB=.

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

jab="${JAB:-./zig-out/bin/jab}"
snapshot="test/fixtures/expected.ndjson"

test -x "$jab" || { echo "jab binary not found at $jab (run 'zig build' first)" >&2; exit 2; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# jab exits 1 when it finds diagnostics — expected here, so tolerate it.
"$jab" --format=json test/fixtures/ > "$work/raw" || true
# Directory-walk order isn't guaranteed across platforms; sort for determinism.
LC_ALL=C sort "$work/raw" > "$work/actual"

if [ "${1:-}" = "--update" ]; then
    cp "$work/actual" "$snapshot"
    echo "updated $snapshot ($(grep -c . "$snapshot") lines)"
    exit 0
fi

test -f "$snapshot" || { echo "snapshot $snapshot missing — run: $0 --update" >&2; exit 1; }

if diff -u "$snapshot" "$work/actual"; then
    echo "fixtures snapshot OK ($(grep -c . "$snapshot") diagnostics)"
else
    echo >&2
    echo "fixture diagnostics drifted from the snapshot (see diff above)." >&2
    echo "If this change is intended, run: $0 --update" >&2
    exit 1
fi
