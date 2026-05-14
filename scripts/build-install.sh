#!/bin/bash
# VOICE — Clean build + install script
# Kills existing instance, resets TCC permissions, builds fresh, installs.
# Usage: ./scripts/build-install.sh
# Optional: SKIP_TCC=1 ./scripts/build-install.sh  (skip TCC reset if you want to preserve permissions)

set -e
BUNDLE_ID="com.fortun8te.voice"
APP_NAME="Voice.app"
INSTALL_PATH="/Applications/${APP_NAME}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "🔨 Voice — Clean Build + Install"
echo "   Bundle: ${BUNDLE_ID}"
echo "   Project: ${PROJECT_DIR}"
echo ""

# Step 1: Kill any running instance
echo "→ Killing any running Voice instance..."
pkill -x "Voice" 2>/dev/null || true
sleep 0.5

# Step 2: Remove old install
if [ -d "${INSTALL_PATH}" ]; then
    echo "→ Removing ${INSTALL_PATH}..."
    rm -rf "${INSTALL_PATH}"
fi

# Step 3: Reset TCC permissions (unless SKIP_TCC=1)
if [ "${SKIP_TCC}" != "1" ]; then
    echo "→ Resetting TCC permissions for ${BUNDLE_ID}..."
    tccutil reset Microphone "${BUNDLE_ID}" 2>/dev/null || true
    tccutil reset Accessibility "${BUNDLE_ID}" 2>/dev/null || true
    tccutil reset ScreenCapture "${BUNDLE_ID}" 2>/dev/null || true
    echo "   ✓ Permissions reset (app will re-request on launch)"
else
    echo "→ Skipping TCC reset (SKIP_TCC=1)"
fi

# Step 4: Build
echo "→ Building (Release)..."
cd "${PROJECT_DIR}"
xcodebuild \
    -project Voice.xcodeproj \
    -scheme Voice \
    -configuration Release \
    -derivedDataPath "${PROJECT_DIR}/.build" \
    -quiet \
    build

# Step 5: Find the built app
BUILD_APP=$(find "${PROJECT_DIR}/.build" -name "${APP_NAME}" -type d | head -1)
if [ -z "${BUILD_APP}" ]; then
    echo "❌ Build failed — ${APP_NAME} not found in derived data"
    exit 1
fi
echo "   Built: ${BUILD_APP}"

# Step 6: Install
echo "→ Installing to ${INSTALL_PATH}..."
cp -R "${BUILD_APP}" "${INSTALL_PATH}"
echo "   ✓ Installed"

# Step 7: Launch
echo "→ Launching..."
open "${INSTALL_PATH}"

echo ""
echo "✅ Done. Voice is running."
echo "   First launch will request Microphone + Accessibility permissions."
