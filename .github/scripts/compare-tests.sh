#!/usr/bin/env bash
# Run the upstream test suite on a candidate checkout and decide whether the
# merge introduced regressions.
#
# Upstream's own suite is not green (it ships with known failures), so "all
# tests pass" would block every sync forever. Instead: a merge is acceptable
# when every failing test also fails on the base checkout.
#
# usage: compare-tests.sh <candidate-dir> <base-dir>
# Writes result=pass|regression and new_failures to $GITHUB_OUTPUT (stdout
# when unset). The candidate/base dirs must each contain flightscnr/tests.
set -uo pipefail

CAND="${1:?candidate dir}"
BASE="${2:?base dir}"
OUT="${GITHUB_OUTPUT:-/dev/stdout}"
WORK="$(mktemp -d)"

# Prints "<failing test ids file>"; returns 1 when the suite did not run at all.
run_suite() {
    local dir="$1" name="$2"
    ( cd "$dir/flightscnr" \
        && SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
           python -m pytest tests -q -p no:cacheprovider --tb=no -rfE ) \
        > "$WORK/$name.log" 2>&1
    grep -E '^(FAILED|ERROR) ' "$WORK/$name.log" | sed -E 's/ - .*$//' | sort -u > "$WORK/$name.failures"
    # A crashed or empty run reports no failures; never mistake that for a pass.
    grep -Eq '[0-9]+ passed' "$WORK/$name.log"
}

finish() {
    local result="$1"
    echo "result=$result" >> "$OUT"
    { echo "new_failures<<EOF_NEW_FAILURES"; head -25 "$WORK/new.failures" 2>/dev/null; echo "EOF_NEW_FAILURES"; } >> "$OUT"
    {
        echo "### Upstream sync tests: $result"
        echo '```'
        tail -1 "$WORK/cand.log"
        echo '```'
        if [ -s "$WORK/new.failures" ]; then
            echo "New failures vs base:"; echo '```'; cat "$WORK/new.failures"; echo '```'
        fi
    } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
    [ "$result" = pass ]
}

: > "$WORK/new.failures"

if ! run_suite "$CAND" cand; then
    echo "Candidate suite did not run to completion:"; tail -20 "$WORK/cand.log"
    echo "suite did not run (see job log)" > "$WORK/new.failures"
    finish regression; exit 0
fi

if [ ! -s "$WORK/cand.failures" ]; then
    echo "All tests pass."; finish pass; exit 0
fi

echo "Candidate has failures; comparing with base."
if ! run_suite "$BASE" base; then
    echo "Base suite did not run to completion:"; tail -20 "$WORK/base.log"
    cp "$WORK/cand.failures" "$WORK/new.failures"
    finish regression; exit 0
fi

comm -23 "$WORK/cand.failures" "$WORK/base.failures" > "$WORK/new.failures"
if [ -s "$WORK/new.failures" ]; then
    echo "New failures:"; cat "$WORK/new.failures"
    finish regression
else
    echo "Only pre-existing failures ($(wc -l < "$WORK/cand.failures"))."
    finish pass
fi
exit 0
