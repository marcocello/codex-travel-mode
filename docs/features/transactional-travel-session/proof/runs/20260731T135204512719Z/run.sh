#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TEST_FILE="$ROOT/Tests/CodexTravelModeCoreTests/TravelSessionTransactionProofTests.swift"

if [[ ! -f "$TEST_FILE" ]]; then
  echo "Missing behavioral proof: $TEST_FILE" >&2
  exit 1
fi

cd "$ROOT"
printf 'Runtime: '
swift --version
printf 'Proof mode: deterministic CLI subprocess with file-backed outer system boundaries\n'
swift build --disable-sandbox --product travel-session-proof-host
bin_path="$(swift build --disable-sandbox --show-bin-path)"
worker="$bin_path/travel-session-proof-host"
if [[ ! -x "$worker" ]]; then
  echo "Missing built process proof host: $worker" >&2
  exit 1
fi
export TRAVEL_SESSION_PROOF_HOST="$worker"

set +e
output="$(swift test --disable-sandbox --filter TravelSessionTransactionProofTests 2>&1)"
status=$?
route_output="$(swift test --disable-sandbox --filter LocalTravelCommandGatewayTests/testSessionBaselineDoesNotPersistRouteOnlyConnectionLabelAsSSID 2>&1)"
route_status=$?
set -e

printf '%s\n' "$output"
printf '%s\n' "$route_output"
if [[ $status -ne 0 ]]; then
  exit "$status"
fi
if [[ $route_status -ne 0 ]]; then
  exit "$route_status"
fi

if ! /usr/bin/grep -Eq 'Executed [1-9][0-9]* tests?|Test run with [1-9][0-9]* tests?' <<<"$output"; then
  echo "Behavioral proof filter executed zero tests." >&2
  exit 1
fi

if ! /usr/bin/grep -Eq 'Executed [1-9][0-9]* tests?|Test run with [1-9][0-9]* tests?' <<<"$route_output"; then
  echo "Route-only SSID proof filter executed zero tests." >&2
  exit 1
fi
