#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
OUTPUT="${PROOF_OUTPUT_DIR:?Set PROOF_OUTPUT_DIR to a unique writable directory}"
BUILD_DRIVER="$ROOT/scripts/build-hotspot-configuration-proof-app"
UI_DRIVER="$ROOT/scripts/run_hotspot_configuration_ui_proof"
READBACK="$OUTPUT/provider-readback.json"
PASSWORD_SENTINEL="hotspot-proof-password-sentinel-7f3c"

if /usr/bin/grep -R -E -q 'Apple80211|PrivateFrameworks/.*/airport|/airport(["[:space:]]|$)' "$ROOT/Sources"; then
  echo "Private Wi-Fi discovery path is still referenced by production sources." >&2
  exit 1
fi

for executable in "$BUILD_DRIVER" "$UI_DRIVER"; do
  if [[ ! -x "$executable" ]]; then
    echo "Missing executable proof asset: $executable" >&2
    exit 1
  fi
done

mkdir -p "$OUTPUT/private"
export HOTSPOT_PROOF_PASSWORD_SENTINEL="$PASSWORD_SENTINEL"
export HOTSPOT_PROOF_WORKSPACE="$OUTPUT/workspace"

"$BUILD_DRIVER" --output "$OUTPUT/build"
"$UI_DRIVER" --app "$OUTPUT/build/Codex Travel Mode Proof.app" --output "$OUTPUT"

if [[ ! -s "$READBACK" ]]; then
  echo "Missing raw provider read-back: $READBACK" >&2
  exit 1
fi

jq -e '
  .schema_version == 1
  and (.scenarios | type == "array" and length >= 32)
  and (all(.scenarios[];
    (.name | type == "string" and length > 0)
    and (.launch_id | type == "string" and length > 0)
    and (.pid | type == "number" and . > 0)
    and (.operations | type == "array" and length > 0)
    and (.options | type == "array")
  ))
' "$READBACK" >/dev/null

if jq -e '.. | objects | select(has("verdict") or has("passed") or has("checks"))' "$READBACK" >/dev/null; then
  echo "Raw provider read-back contains self-attested verdict/check fields." >&2
  exit 1
fi

required_scenarios=(
  fresh-loading
  exact-discovery-order
  discovery-status-matrix
  stale-refresh
  manual-save-after-denial
  saved-selection-after-failure
  unsaved-draft-start
  keychain-stage-failure
  keychain-verification-failure
  pointer-commit-failure
  crash-before-staging
  crash-after-staging
  crash-after-pointer-commit
  crash-during-cleanup
  credential-cleanup-failure
  legacy-migration
  lifecycle-lock-matrix
  double-save-race
  save-start-race
  quit-save-race
)
for scenario in "${required_scenarios[@]}"; do
  if ! jq -e --arg scenario "$scenario" '.scenarios | any(.name == $scenario)' "$READBACK" >/dev/null; then
    echo "Missing proof scenario: $scenario" >&2
    exit 1
  fi
done
for variant in save-first quit-first; do
  if ! jq -e --arg variant "$variant" '
    .scenarios | any(.name == "quit-save-race" and .variant == $variant)
  ' "$READBACK" >/dev/null; then
    echo "Missing quit-save-race proof variant: $variant" >&2
    exit 1
  fi
done

for artifact in \
  loading-state.png \
  results-state.png \
  empty-state.png \
  permission-state.png \
  unavailable-state.png \
  manual-selection.png \
  discovery-error.png \
  saved-state.png \
  locked-state.png; do
  file="$OUTPUT/$artifact"
  if [[ ! -s "$file" ]] || ! /usr/bin/sips -g format "$file" 2>/dev/null | /usr/bin/grep -q 'format: png'; then
    echo "Missing or invalid PNG proof artifact: $file" >&2
    exit 1
  fi
  width="$(/usr/bin/sips -g pixelWidth "$file" 2>/dev/null | /usr/bin/awk '/pixelWidth:/ {print $2}')"
  height="$(/usr/bin/sips -g pixelHeight "$file" 2>/dev/null | /usr/bin/awk '/pixelHeight:/ {print $2}')"
  if [[ -z "$width" || -z "$height" || "$width" -lt 280 || "$height" -lt 180 ]]; then
    echo "PNG proof artifact has implausible dimensions: $file (${width:-?}x${height:-?})" >&2
    exit 1
  fi
done

if /usr/bin/grep -R -F -q --exclude-dir=private "$PASSWORD_SENTINEL" "$OUTPUT"; then
  echo "Password sentinel escaped the fake-Keychain vault." >&2
  exit 1
fi

set +e
test_output="$(
  HOTSPOT_CONFIGURATION_PROOF_OUTPUT="$OUTPUT" \
    swift test --disable-sandbox --filter HotspotConfigurationProofTests 2>&1
)"
test_status=$?
set -e
printf '%s\n' "$test_output"
if [[ $test_status -ne 0 ]]; then
  exit "$test_status"
fi
if ! /usr/bin/grep -Eq 'Executed [1-9][0-9]* tests?|Test run with [1-9][0-9]* tests?' <<<"$test_output"; then
  echo "Hotspot configuration proof filter executed zero tests." >&2
  exit 1
fi

release_output="$OUTPUT/release"
BUILD_OUTPUT_DIR="$release_output" "$ROOT/scripts/build-local-app.sh"
if /usr/bin/grep -R -E -q 'HOTSPOT_PROOF|hotspot-configuration-proof|RecordingKeychain' "$release_output/Codex Travel Mode.app"; then
  echo "Proof composition leaked into the release app bundle." >&2
  exit 1
fi
