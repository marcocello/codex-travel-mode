#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Codex Travel Mode"
EXECUTABLE_NAME="codex-travel-mode"
BUNDLE_ID="com.codex.travelmode"
VERSION="0.1.0"
MIN_MACOS="13.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIST_DIR="${REPO_ROOT}/dist"
APP_DIR="${DIST_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
SWIFTPM_CACHE="${REPO_ROOT}/.swiftpm-home/cache"
SWIFTPM_CONFIG="${REPO_ROOT}/.swiftpm-home/config"
SWIFTPM_SECURITY="${REPO_ROOT}/.swiftpm-home/security"
mkdir -p "${SWIFTPM_CACHE}" "${SWIFTPM_CONFIG}" "${SWIFTPM_SECURITY}"

echo "==> Building release binary"
swift build -c release \
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
BIN_PATH="${BIN_DIR}/${EXECUTABLE_NAME}"

if [[ ! -x "${BIN_PATH}" ]]; then
  echo "Error: release binary not found at ${BIN_PATH}" >&2
  exit 1
fi

echo "==> Creating app bundle"
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"
cp "${BIN_PATH}" "${MACOS_DIR}/${EXECUTABLE_NAME}"
chmod +x "${MACOS_DIR}/${EXECUTABLE_NAME}"

cp "${REPO_ROOT}/CodexTravelMode-Info.plist" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName ${APP_NAME}" "${CONTENTS_DIR}/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleName string ${APP_NAME}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLE_ID}" "${CONTENTS_DIR}/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string ${BUNDLE_ID}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable ${EXECUTABLE_NAME}" "${CONTENTS_DIR}/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string ${EXECUTABLE_NAME}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundlePackageType APPL" "${CONTENTS_DIR}/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${CONTENTS_DIR}/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string ${VERSION}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion ${MIN_MACOS}" "${CONTENTS_DIR}/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string ${MIN_MACOS}" "${CONTENTS_DIR}/Info.plist"

echo "Done: ${APP_DIR}"
