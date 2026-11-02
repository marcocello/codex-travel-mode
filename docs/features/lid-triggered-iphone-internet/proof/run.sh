#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TEST_FILE="$ROOT/Tests/CodexTravelModeCoreTests/IPhoneInternetHandoffProofTests.swift"
OUTPUT="${PROOF_OUTPUT_DIR:?Set PROOF_OUTPUT_DIR to a unique writable directory}"
DRIVER="$ROOT/scripts/run_iphone_internet_handoff_proof"

if [[ ! -f "$TEST_FILE" ]]; then
  echo "Missing behavioral proof: $TEST_FILE" >&2
  exit 1
fi
if [[ ! -x "$DRIVER" ]]; then
  echo "Missing executable proof driver: $DRIVER" >&2
  exit 1
fi

"$DRIVER" --output "$OUTPUT"
