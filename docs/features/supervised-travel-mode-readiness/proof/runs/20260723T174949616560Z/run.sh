#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
DRIVER="$ROOT/scripts/run_live_travel_mode_proof"
ATTEMPT_DIR="${PROOF_ATTEMPT_DIR:?proof_run_capture must set PROOF_ATTEMPT_DIR}"
OUTPUT="$ATTEMPT_DIR/live-evidence"
TTY_PATH="/dev/tty"

cd "$ROOT"
echo "Runtime: $(swift --version | head -n 1)"
echo "Mode: supervised-live; deterministic harness precedes guarded physical acceptance"

swift build --disable-sandbox --product codex-travel-mode-readiness
swift build --disable-sandbox --product codex-travel-mode-readiness-observer
swift build --disable-sandbox --product codex-travel-mode-readiness-oracle
swift test \
  --disable-sandbox \
  --filter LiveTravelModeProofHarnessTests
swift test \
  --disable-sandbox \
  --filter ReadinessCoreHardeningTests

if [[ ! -x "$DRIVER" ]]; then
  echo "NEED_INPUT: live proof driver is unavailable at its committed production path" >&2
  exit 3
fi
if [[ ! -r "$TTY_PATH" || ! -w "$TTY_PATH" ]]; then
  echo "NEED_INPUT: run the captured proof from a supervised controlling TTY" >&2
  exit 3
fi

read -r -p "Signed app bundle path: " app_bundle < "$TTY_PATH"
read -r -p "Mode-0600 provider configuration path: " heartbeat_config < "$TTY_PATH"
if [[ "$app_bundle" != /* || "$heartbeat_config" != /* ]]; then
  echo "NEED_INPUT: app and provider configuration paths must be absolute" >&2
  exit 3
fi

mkdir -m 0700 "$OUTPUT"
"$DRIVER" \
  --preflight \
  --app "$app_bundle" \
  --heartbeat-config "$heartbeat_config" \
  --output "$OUTPUT"

receipt="$OUTPUT/arming-receipt.json"
if [[ ! -s "$receipt" ]]; then
  echo "Preflight did not create the bound arming receipt" >&2
  exit 1
fi

"$DRIVER" \
  --live \
  --receipt "$receipt" \
  --app "$app_bundle" \
  --output "$OUTPUT"

required=(
  preflight-readback.json
  arming-receipt.json
  command-events.json
  operator-events.json
  cleanup-events.json
  provider-transport-events.json
  provider-receipts.json
  observer-events.json
  observer-seal.json
  seal-manifest.json
  oracle-report.json
)
for name in "${required[@]}"; do
  if [[ ! -s "$OUTPUT/$name" ]]; then
    echo "Live proof omitted required sealed artifact: $name" >&2
    exit 1
  fi
done

echo "Live evidence: retained attempt/live-evidence"
