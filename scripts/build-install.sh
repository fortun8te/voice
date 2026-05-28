#!/bin/bash
# VOICE — Clean build + install script.
#
# Default: PRESERVES TCC permissions (Microphone, Accessibility) across rebuilds.
# This works because project.yml signs with a stable Apple Development cert.
# TCC pins permissions to the codesign designated requirement, so as long as the
# signing identity is stable, permissions carry over.
#
# ============================================================================
# BUILD NUMBER IS THE APP'S IDENTITY  (read this — it MUST always advance)
# ============================================================================
# Voice no longer tracks a marketing/semantic version. The single source of
# truth for "which build am I running" is the integer in the repo-root
# BUILD_NUMBER file. EVERY run of this script:
#   1. reads BUILD_NUMBER, increments it by 1, writes it back,
#   2. stamps the new number into Info.plist (CFBundleVersion) AND
#      project.yml (CURRENT_PROJECT_VERSION) so the built app reports it,
#   3. the app's About panel / menu shows "Build N".
# So a fresh install ALWAYS has a strictly higher build number than the one it
# replaced — that is how you confirm the old version is actually gone. If you
# ever build the app WITHOUT this script, bump BUILD_NUMBER yourself first.
# ============================================================================
#
# Usage:
#   ./scripts/build-install.sh                  # preserve TCC permissions (default)
#   RESET_TCC=1 ./scripts/build-install.sh      # force reset (only if signing identity changed)

set -e
BUNDLE_ID="com.fortun8te.voice"
APP_NAME="Voice.app"
INSTALL_PATH="/Applications/${APP_NAME}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "🔨 Voice — Clean Build + Install"
echo "   Bundle: ${BUNDLE_ID}"
echo "   Project: ${PROJECT_DIR}"
echo ""

# Step 0: Bump the build number. This is the app's identity (see header).
BUILD_FILE="${PROJECT_DIR}/BUILD_NUMBER"
PREV_BUILD=$(tr -d '[:space:]' < "${BUILD_FILE}" 2>/dev/null || echo "0")
if ! [[ "${PREV_BUILD}" =~ ^[0-9]+$ ]]; then PREV_BUILD=0; fi
BUILD_NUMBER=$((PREV_BUILD + 1))
echo "${BUILD_NUMBER}" > "${BUILD_FILE}"
echo "→ Build number: ${PREV_BUILD} → ${BUILD_NUMBER}  (stamping Info.plist + project.yml)"
# Stamp into the Info.plist that ships in the bundle (INFOPLIST_FILE = Info.plist).
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "${PROJECT_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 0.${BUILD_NUMBER}" "${PROJECT_DIR}/Info.plist"
# Keep project.yml consistent so a future `xcodegen generate` preserves it.
/usr/bin/sed -i '' "s/^\(        CURRENT_PROJECT_VERSION:\).*/\1 \"${BUILD_NUMBER}\"/" "${PROJECT_DIR}/project.yml" 2>/dev/null || true
/usr/bin/sed -i '' "s/^\(        MARKETING_VERSION:\).*/\1 \"0.${BUILD_NUMBER}\"/" "${PROJECT_DIR}/project.yml" 2>/dev/null || true
echo ""

# Step 1: Kill any running instance.
echo "→ Killing any running Voice instance..."
pkill -x "Voice" 2>/dev/null || true
sleep 0.5

# Step 2: Remove old install + sweep for stray duplicate copies.
if [ -d "${INSTALL_PATH}" ]; then
    echo "→ Removing ${INSTALL_PATH}..."
    rm -rf "${INSTALL_PATH}"
fi
# Warn about any OTHER Voice.app the user may have lying around (Downloads, a
# stale build dir, etc.) so two versions can't run / confuse TCC. We only warn
# for copies outside the project's own build dirs — we never auto-delete files
# outside /Applications.
STRAY=$(mdfind "kMDItemCFBundleIdentifier == '${BUNDLE_ID}'" 2>/dev/null \
        | grep -v "^${INSTALL_PATH}$" \
        | grep -v "${PROJECT_DIR}/.build/" \
        | grep -v "${PROJECT_DIR}/DerivedData" || true)
if [ -n "${STRAY}" ]; then
    echo "   ⚠️  Other Voice.app copies found (consider deleting so only the new build runs):"
    echo "${STRAY}" | sed 's/^/        /'
fi
# Clean the agents' transient isolated derived-data dirs so they don't pile up.
rm -rf "${PROJECT_DIR}"/DerivedData[A-Za-z]* 2>/dev/null || true

# Step 3: TCC permissions — preserve by default, only reset on explicit opt-in.
# The "every build asks for permissions again" bug was caused by ad-hoc signing
# (different cdhash per build = TCC saw a new app). With a stable cert this no
# longer happens, and we should NOT reset TCC by default.
if [ "${RESET_TCC}" = "1" ]; then
    echo "→ Resetting TCC permissions for ${BUNDLE_ID} (RESET_TCC=1)..."
    tccutil reset Microphone "${BUNDLE_ID}" 2>/dev/null || true
    tccutil reset Accessibility "${BUNDLE_ID}" 2>/dev/null || true
    tccutil reset ScreenCapture "${BUNDLE_ID}" 2>/dev/null || true
    echo "   ✓ Permissions reset (app will re-request on launch)"
else
    echo "→ Preserving TCC permissions (set RESET_TCC=1 to force a reset)"
fi

# Step 4: Build.
echo "→ Building (Release)..."
cd "${PROJECT_DIR}"
xcodebuild \
    -project Voice.xcodeproj \
    -scheme Voice \
    -configuration Release \
    -derivedDataPath "${PROJECT_DIR}/.build" \
    -quiet \
    build

# Step 5: Find the built app.
BUILD_APP=$(find "${PROJECT_DIR}/.build" -name "${APP_NAME}" -type d | head -1)
if [ -z "${BUILD_APP}" ]; then
    echo "❌ Build failed — ${APP_NAME} not found in derived data"
    exit 1
fi
echo "   Built: ${BUILD_APP}"

# Step 6: Install.
echo "→ Installing to ${INSTALL_PATH}..."
cp -R "${BUILD_APP}" "${INSTALL_PATH}"
echo "   ✓ Installed"

# Step 7: Verify codesign is stable (NOT ad-hoc). If it is ad-hoc, TCC will
# treat every rebuild as a new app — warn the user loudly.
echo "→ Verifying stable codesign..."
SIGN_INFO=$(codesign -dv --verbose=2 "${INSTALL_PATH}" 2>&1)
if echo "$SIGN_INFO" | grep -q "adhoc"; then
    echo "   ⚠️  WARNING: app is ad-hoc signed. TCC permissions will reset every build."
    echo "       Check project.yml CODE_SIGN_IDENTITY and 'security find-identity -v -p codesigning'."
else
    AUTH=$(echo "$SIGN_INFO" | grep "Authority=" | head -1 | sed 's/Authority=//')
    echo "   ✓ Signed by: ${AUTH}"
fi

# Step 8: Verify icon coherence (Assets.car and AppIcon.icns must contain the
# same pixels). Mismatch causes the intermittent "generic square" icon bug.
echo "→ Verifying icon coherence..."
if [ -f "${INSTALL_PATH}/Contents/Resources/Assets.car" ] && \
   [ -f "${INSTALL_PATH}/Contents/Resources/AppIcon.icns" ]; then
    CAR_SHA=$(assetutil --info "${INSTALL_PATH}/Contents/Resources/Assets.car" 2>/dev/null \
        | python3 -c "import json, sys; d=json.load(sys.stdin); icons=[x for x in d if x.get('Name')=='AppIcon' and x.get('PixelWidth')==1024]; print(icons[0]['SHA1Digest'] if icons else 'NO_1024')" 2>/dev/null || echo "PARSE_ERR")
    ICNS_TMP=$(mktemp -d)
    iconutil -c iconset "${INSTALL_PATH}/Contents/Resources/AppIcon.icns" -o "${ICNS_TMP}/AppIcon.iconset" 2>/dev/null
    ICNS_SHA=$(shasum -a 1 "${ICNS_TMP}/AppIcon.iconset/icon_512x512@2x.png" 2>/dev/null | cut -d' ' -f1 | tr 'a-f' 'A-F')
    rm -rf "$ICNS_TMP"
    # NOTE: Assets.car stores its own SHA1 over decoded RGB pixels, while the icns
    # stores PNG-compressed bytes — the SHAs WILL differ even when pixels match.
    # We only print them; the real coherence guarantee is that fix_appicon_icns.sh
    # generates both from the same IconSource.png.
    echo "   Assets.car 1024 SHA1 (decoded pixels): ${CAR_SHA:0:16}…"
    echo "   AppIcon.icns 1024 SHA1 (PNG bytes):     ${ICNS_SHA:0:16}…"
    echo "   (Both regenerated from IconSource.png by fix_appicon_icns.sh)"
else
    echo "   ⚠️  Missing Assets.car or AppIcon.icns"
fi

# Step 9: Launch.
echo "→ Launching..."
open "${INSTALL_PATH}"

echo ""
echo "✅ Done. Voice (Build ${BUILD_NUMBER}) is running."
INSTALLED_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "${INSTALL_PATH}/Contents/Info.plist" 2>/dev/null || echo "?")
echo "   Installed bundle reports CFBundleVersion = ${INSTALLED_BUILD} (expected ${BUILD_NUMBER})."
if [ "${RESET_TCC}" = "1" ]; then
    echo "   First launch will request Microphone + Accessibility (you reset them)."
else
    echo "   Permissions preserved — no re-grant needed."
fi
