#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
DRIVER="$ROOT/scripts/run_lifecycle_ui_proof"
FEATURE_DIR="$ROOT/docs/features/safe-menu-bar-lifecycle"

resolve_attempt_dir() {
  if [[ -n "${PROOF_ATTEMPT_DIR:-}" ]]; then
    printf '%s\n' "$PROOF_ATTEMPT_DIR"
    return
  fi

  local marker
  for marker in "$FEATURE_DIR"/proof/runs/*/attempt-start.json; do
    [[ -f "$marker" ]] || continue
    if jq -e --argjson runner_pid "$$" '.runner_pid == $runner_pid' "$marker" >/dev/null; then
      dirname "$marker"
      return
    fi
  done

  mktemp -d "${TMPDIR:-/tmp}/codex-travel-mode-ui-proof.XXXXXX"
}

ATTEMPT_DIR="$(resolve_attempt_dir)"
OUTPUT="${PROOF_OUTPUT_DIR:-$ATTEMPT_DIR/screenshots}"

require_png() {
  local file="$1"
  if [[ ! -s "$file" ]] || ! /usr/bin/sips -g format "$file" 2>/dev/null | /usr/bin/grep -q 'format: png'; then
    echo "Missing or invalid PNG proof artifact: $file" >&2
    exit 1
  fi
}

if [[ ! -x "$DRIVER" ]]; then
  echo "Missing native UI proof driver: $DRIVER" >&2
  exit 1
fi

SWIFT_EXECUTABLE="$(command -v swift)"
echo "Swift executable: $SWIFT_EXECUTABLE"
"$SWIFT_EXECUTABLE" --version | head -n 1
echo "GUI readiness: AppKit proof app will render the production NSPopover in the current macOS session."
echo "Codex readiness: the live macOS workspace must expose bundle identifier com.openai.codex."
echo "Proof output: $OUTPUT"

mkdir -p "$OUTPUT"
"$DRIVER" --output "$OUTPUT"

retained_app="$('/usr/bin/find' "$OUTPUT" -type d -name '*.app' -print -quit)"
if [[ -n "$retained_app" ]]; then
  echo "Proof retained a Spotlight-searchable app bundle: $retained_app" >&2
  exit 1
fi

set +e
gateway_test_output="$({ REQUIRE_LIVE_CODEX_RUNNING=1 swift test --disable-sandbox --filter LocalTravelCommandGatewayTests; } 2>&1)"
gateway_test_status=$?
set -e
printf '%s\n' "$gateway_test_output"
if [[ $gateway_test_status -ne 0 ]]; then
  exit "$gateway_test_status"
fi
if ! /usr/bin/grep -Eq 'Executed [1-9][0-9]* tests?|Test run with [1-9][0-9]* tests?' <<<"$gateway_test_output"; then
  echo "Codex workspace proof filter executed zero tests." >&2
  exit 1
fi

for artifact in off.png preparing.png active.png restoring.png recovery.png cleanup-required.png; do
  require_png "$OUTPUT/$artifact"
done

readback="$OUTPUT/lifecycle-readback.json"
if [[ ! -s "$readback" ]]; then
  echo "Missing lifecycle-readback.json" >&2
  exit 1
fi
if ! /usr/bin/plutil -extract schema_version raw -o - "$readback" 2>/dev/null \
  | /usr/bin/grep -qx 1; then
  echo "Invalid lifecycle read-back schema." >&2
  exit 1
fi

required_scenarios=(
  clean-off-quit
  pre-start-cancel
  preparing-quit-before-journal
  preparing-quit-after-journal
  preparing-quit-after-lease
  preparing-quit-after-lease-failure
  active-dismiss-reopen
  stop-success
  stop-failure-retry-success
  quit-failure-retry-success
  repeated-quit-delayed-success
  repeated-quit-failure
  startup-recovery-success
  startup-recovery-failure
  quit-during-startup-recovery
  quit-during-startup-recovery-failure
)
for scenario in "${required_scenarios[@]}"; do
  if ! jq -e --arg scenario "$scenario" '
    .scenarios | any(.name == $scenario)
  ' "$readback" >/dev/null; then
    echo "Missing required lifecycle scenario: $scenario" >&2
    exit 1
  fi
done

if ! jq -e '
  (.scenarios | length == 16)
  and (.screenshots | length == 6)
  and all(.screenshots[];
    (.popover_content_view_id | type == "string" and length > 0)
    and (.popover_window_number | type == "number" and . > 0)
    and (.accessibility_snapshot_id | type == "string" and length > 0)
  )
  and (.release_inventory | length >= 5)
  and (.release_binary_records | length == 18)
  and all(.release_binary_records[]; .occurrences == 0)
  and (.release_bundle_records | length == 9)
  and all(.release_bundle_records[];
    .occurrences == 0 and (.matching_paths | length == 0)
  )
' "$readback" >/dev/null; then
  echo "Lifecycle read-back is missing actual-popover or release-exclusion evidence." >&2
  exit 1
fi
