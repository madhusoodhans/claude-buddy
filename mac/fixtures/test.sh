#!/usr/bin/env bash
# Checks both usage parsers (the Mac app's and the remote agent's) against every answer here
# (expected.txt holds the device lines).
set -euo pipefail
cd "$(dirname "$0")"
BIN="../dist/Claude Buddy.app/Contents/MacOS/ClaudeBuddy"
while read -r file time expected; do
  for who in app agent; do
    if [[ $who == app ]]; then got=$("$BIN" --parse-usage "$file" "$time")
    else got=$(python3 ../../remote/buddy-agent.py --parse-usage "$file" "$time"); fi
    if [[ "$got" == "$expected" ]]; then echo "ok    $who  $file"; else echo "FAIL  $who  $file"; echo "  want $expected"; echo "  got  $got"; fail=1; fi
  done
done < expected.txt
exit ${fail:-0}
