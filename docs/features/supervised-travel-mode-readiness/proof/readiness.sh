#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
DRIVER="$ROOT/scripts/run_live_travel_mode_proof"

usage() {
  echo "Usage: $0 --app ABSOLUTE_APP_BUNDLE --heartbeat-config MODE_0600_JSON --output NEW_DIRECTORY" >&2
}

app=""
heartbeat_config=""
output=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      app="$2"
      shift 2
      ;;
    --heartbeat-config)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      heartbeat_config="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      output="$2"
      shift 2
      ;;
    --live|--receipt)
      echo "readiness.sh is read-only and never accepts live authorization." >&2
      exit 2
      ;;
    *)
      echo "Unknown preflight argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$app" || -z "$heartbeat_config" || -z "$output" ]]; then
  usage
  exit 2
fi
if [[ ! -x "$DRIVER" ]]; then
  echo "Missing readiness driver: $DRIVER" >&2
  exit 1
fi

exec "$DRIVER" \
  --preflight \
  --app "$app" \
  --heartbeat-config "$heartbeat_config" \
  --output "$output"
