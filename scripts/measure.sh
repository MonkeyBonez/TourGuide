#!/bin/bash
# Reproduce the 6 Oct 2026 Kanazawa measurement from the bundled snapshot and diff it against
# the golden output. Timings (ms) and tag order are not compared; everything else must match.
#   scripts/measure.sh            → prints the table, exits 1 on any difference
set -eu
cd "$(dirname "$0")/.."
GOLDEN=Core/Tests/TourGuideCoreTests/Fixtures/kanazawa/expected_table.txt
OUT=$(swift run -c release --package-path Core tgtool route kanazawa --slacks 0,0.1,0.2,0.3,0.5 --view 30 --cap 20)
normalise() {
  grep -v '^wrote ' | grep -v '^$' \
  | sed -E 's/; labels [0-9.]+ ms//' \
  | sed -E 's/^( [0-9]\.[0-9]{2} .*[0-9]+)  +[0-9]+\.[0-9]$/\1/' \
  | sed -E 's/^(  - .*\])  .*$/\1/'
}
printf '%s\n' "$OUT" | sed -n '/^slack   metres/,/^$/p'
if diff <(normalise < "$GOLDEN") <(printf '%s\n' "$OUT" | normalise) > /dev/null 2>&1; then
  echo "measure: matches $GOLDEN"
else
  diff <(normalise < "$GOLDEN") <(printf '%s\n' "$OUT" | normalise) || true
  echo "measure: DIFFERS from $GOLDEN"; exit 1
fi
