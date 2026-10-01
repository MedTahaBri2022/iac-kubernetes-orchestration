#!/usr/bin/env bash
# Calls the application in a loop and reports which versions answered and how
# many requests failed. Run it in one terminal while a rolling update happens
# in another: a correct rollout shows both versions and zero failures.
#
#   scripts/watch-rollout.sh http://localhost:30080 60
set -euo pipefail

URL="${1:-http://localhost:30080}"
DURATION="${2:-60}"

declare -A versions=()
ok=0
failed=0
end=$((SECONDS + DURATION))

while ((SECONDS < end)); do
  if body=$(curl -sf --max-time 2 "$URL/"); then
    version=$(sed -E 's/.*"version":"([^"]+)".*/\1/' <<<"$body")
    versions[$version]=$((${versions[$version]:-0} + 1))
    ok=$((ok + 1))
  else
    failed=$((failed + 1))
  fi
  sleep 0.1
done

echo "requests ok: $ok, failed: $failed"
for version in "${!versions[@]}"; do
  echo "  version $version answered ${versions[$version]} times"
done
((failed == 0))
