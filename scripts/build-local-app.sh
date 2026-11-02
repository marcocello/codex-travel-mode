#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Codex Travel Mode"
APP_EXECUTABLE_NAME="codex-travel-mode"
HELPER_EXECUTABLE_NAME="codex-travel-mode-sleep-helper"
APP_BUNDLE_ID="com.codex.travelmode"
HELPER_BUNDLE_ID="com.codex.travelmode.sleep-helper"
HELPER_PLIST_NAME="com.codex.travelmode.sleep-helper.plist"
VERSION="0.1.0"
MIN_MACOS="13.0"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIST_DIR="${BUILD_OUTPUT_DIR:-${REPO_ROOT}/dist}"
APP_DIR="${DIST_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
LAUNCH_DAEMONS_DIR="${CONTENTS_DIR}/Library/LaunchDaemons"
SWIFTPM_CACHE="${REPO_ROOT}/.swiftpm-home/cache"
SWIFTPM_CONFIG="${REPO_ROOT}/.swiftpm-home/config"
SWIFTPM_SECURITY="${REPO_ROOT}/.swiftpm-home/security"
mkdir -p "${SWIFTPM_CACHE}" "${SWIFTPM_CONFIG}" "${SWIFTPM_SECURITY}"

echo "==> Building release binary"
swift build -c release \
  --product "${APP_EXECUTABLE_NAME}" \
  --disable-sandbox \
  --manifest-cache local \
  --cache-path "${SWIFTPM_CACHE}" \
  --config-path "${SWIFTPM_CONFIG}" \
  --security-path "${SWIFTPM_SECURITY}" \
  --package-path "${REPO_ROOT}"
swift build -c release \
  --product "${HELPER_EXECUTABLE_NAME}" \
  --disable-sandbox \
  --manifest-cache local \
  --cache-path "${SWIFTPM_CACHE}" \
  --config-path "${SWIFTPM_CONFIG}" \
  --security-path "${SWIFTPM_SECURITY}" \
  --package-path "${REPO_ROOT}"
BIN_DIR="$(
  swift build -c release \
    --disable-sandbox \
    --manifest-cache local \
    --cache-path "${SWIFTPM_CACHE}" \
    --config-path "${SWIFTPM_CONFIG}" \
    --security-path "${SWIFTPM_SECURITY}" \
    --show-bin-path \
    --package-path "${REPO_ROOT}"
)"
APP_BIN_PATH="${BIN_DIR}/${APP_EXECUTABLE_NAME}"
HELPER_BIN_PATH="${BIN_DIR}/${HELPER_EXECUTABLE_NAME}"

if [[ ! -x "${APP_BIN_PATH}" ]]; then
  echo "Error: release binary not found at ${APP_BIN_PATH}" >&2
  exit 1
fi
if [[ ! -x "${HELPER_BIN_PATH}" ]]; then
  echo "Error: sleep helper binary not found at ${HELPER_BIN_PATH}" >&2
  exit 1
fi

echo "==> Creating app bundle"
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}" "${LAUNCH_DAEMONS_DIR}"
cp "${APP_BIN_PATH}" "${MACOS_DIR}/${APP_EXECUTABLE_NAME}"
chmod +x "${MACOS_DIR}/${APP_EXECUTABLE_NAME}"
cp "${HELPER_BIN_PATH}" "${RESOURCES_DIR}/${HELPER_EXECUTABLE_NAME}"
chmod +x "${RESOURCES_DIR}/${HELPER_EXECUTABLE_NAME}"
cp "${REPO_ROOT}/Packaging/${HELPER_PLIST_NAME}" "${LAUNCH_DAEMONS_DIR}/${HELPER_PLIST_NAME}"

cp "${REPO_ROOT}/CodexTravelMode-Info.plist" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName ${APP_NAME}" "${CONTENTS_DIR}/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleName string ${APP_NAME}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${APP_BUNDLE_ID}" "${CONTENTS_DIR}/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string ${APP_BUNDLE_ID}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable ${APP_EXECUTABLE_NAME}" "${CONTENTS_DIR}/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string ${APP_EXECUTABLE_NAME}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundlePackageType APPL" "${CONTENTS_DIR}/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${CONTENTS_DIR}/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string ${VERSION}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion ${MIN_MACOS}" "${CONTENTS_DIR}/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string ${MIN_MACOS}" "${CONTENTS_DIR}/Info.plist"

/usr/bin/plutil -lint "${CONTENTS_DIR}/Info.plist" "${LAUNCH_DAEMONS_DIR}/${HELPER_PLIST_NAME}"

HELPER_SIGN_ARGS=(
  --force
  --sign "${CODE_SIGN_IDENTITY}"
  --identifier "${HELPER_BUNDLE_ID}"
  --options runtime
)
APP_SIGN_ARGS=(
  --force
  --sign "${CODE_SIGN_IDENTITY}"
  --options runtime
)
if [[ "${CODE_SIGN_IDENTITY}" != "-" ]]; then
  HELPER_SIGN_ARGS+=(--timestamp)
  APP_SIGN_ARGS+=(--timestamp)
fi

echo "==> Signing nested sleep helper"
/usr/bin/codesign "${HELPER_SIGN_ARGS[@]}" "${RESOURCES_DIR}/${HELPER_EXECUTABLE_NAME}"
echo "==> Signing outer app bundle"
/usr/bin/codesign "${APP_SIGN_ARGS[@]}" "${APP_DIR}"

/usr/bin/codesign --verify --strict --verbose=2 "${RESOURCES_DIR}/${HELPER_EXECUTABLE_NAME}"
/usr/bin/codesign --verify --deep --strict --verbose=2 "${APP_DIR}"
if [[ "${CODE_SIGN_IDENTITY}" != "-" ]]; then
  helper_team="$({ /usr/bin/codesign -d --verbose=4 "${RESOURCES_DIR}/${HELPER_EXECUTABLE_NAME}"; } 2>&1 \
    | /usr/bin/sed -n 's/^TeamIdentifier=//p')"
  app_team="$({ /usr/bin/codesign -d --verbose=4 "${APP_DIR}"; } 2>&1 \
    | /usr/bin/sed -n 's/^TeamIdentifier=//p')"
  if [[ -z "${helper_team}" || "${helper_team}" != "${app_team}" ]]; then
    echo "Error: app and helper must use the same non-empty signing team." >&2
    exit 1
  fi
fi

echo "Done: ${APP_DIR}"
