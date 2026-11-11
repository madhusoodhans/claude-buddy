#!/usr/bin/env bash
# Checks the usage parser against every answer here (expected.txt holds the device lines).
set -euo pipefail
cd "$(dirname "$0")"
BIN="../dist/Claude Buddy.app/Contents/MacOS/ClaudeBuddy"
while read -r file time expected; do
  got=$("$BIN" --parse-usage "$file" "$time")
  if [[ "$got" == "$expected" ]]; then echo "ok    $file"; else echo "FAIL  $file"; echo "  want $expected"; echo "  got  $got"; fail=1; fi
done < expected.txt
exit ${fail:-0}
