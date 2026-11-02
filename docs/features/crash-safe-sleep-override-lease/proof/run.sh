#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TEST_FILE="$ROOT/Tests/CodexTravelModeCoreTests/SleepOverrideLeaseProcessProofTests.swift"

if [[ ! -f "$TEST_FILE" ]]; then
  echo "Missing behavioral proof: $TEST_FILE" >&2
  exit 1
fi

cd "$ROOT"
swift build --disable-sandbox --product sleep-override-lease-proof-helper
swift build --disable-sandbox --product sleep-override-lease-proof-owner
swift build --disable-sandbox --product sleep-override-lease-fake-power
bin_path="$(swift build --disable-sandbox --show-bin-path)"
helper="$bin_path/sleep-override-lease-proof-helper"
owner="$bin_path/sleep-override-lease-proof-owner"
fake_power="$bin_path/sleep-override-lease-fake-power"
for executable in "$helper" "$owner" "$fake_power"; do
  if [[ ! -x "$executable" ]]; then
    echo "Missing built process proof executable: $executable" >&2
    exit 1
  fi
done
export SLEEP_OVERRIDE_LEASE_PROOF_HELPER="$helper"
export SLEEP_OVERRIDE_LEASE_PROOF_OWNER="$owner"
export SLEEP_OVERRIDE_LEASE_FAKE_POWER="$fake_power"

set +e
output="$(swift test --disable-sandbox --filter SleepOverrideLeaseProcessProofTests 2>&1)"
status=$?
set -e

printf '%s\n' "$output"
if [[ $status -ne 0 ]]; then
  exit "$status"
fi

if ! /usr/bin/grep -Eq 'Executed [1-9][0-9]* tests?|Test run with [1-9][0-9]* tests?' <<<"$output"; then
  echo "Behavioral proof filter executed zero tests." >&2
  exit 1
fi
