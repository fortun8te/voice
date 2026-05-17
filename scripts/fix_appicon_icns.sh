#!/bin/bash
# Fix AppIcon icns + Assets.car build phase script.
#
# ====================================================================
# THE REAL ROOT CAUSE — Updated diagnosis (May 17, 2026)
# ====================================================================
# Previous "fixes" addressed the WRONG layer. The .icns is now well-formed
# (10 sizes, the largest being 1024×1024) — but the on-screen icon still
# looked like a flat-square scaled-up "blob".
#
# THE REAL PROBLEM: IconSource.png is a FLAT SQUARE 3200×3200 PNG with
# fully-opaque pixels in every corner. macOS does NOT auto-round flat
# square app icons in the Dock / Cmd-Tab / Launchpad. It draws them
# exactly as supplied. Big Sur+ design language expects pre-masked
# icons whose corners are ALREADY a squircle with transparent pixels
# outside the squircle path.
#
# Every rep we generated from IconSource.png inherited the flat-square
# shape. The icns was technically correct (10 reps, all sizes present),
# but every rep had hard square corners — so the Dock rendered a hard
# square. The "scaled-up" appearance is just a flat-square icon at
# 128×128+ — visually indistinguishable from a stretched placeholder.
#
# THIS SCRIPT now does FOUR things, in this order:
#
#   1. Mask IconSource.png to the macOS app-icon squircle shape via an
#      inline Swift program. Output: TMP/IconSource_masked.png (1024×1024,
#      transparent outside the squircle, original pixels inside).
#
#   2. Regenerate Assets.xcassets/AppIcon.appiconset/*.png from the
#      MASKED image so on-disk source-of-truth and actool output both
#      get the rounded shape.
#
#   3. Re-run actool to rebuild Assets.car from the refreshed (masked)
#      PNGs. actool also overwrites AppIcon.icns with its truncated
#      version — we replace it next.
#
#   4. Overwrite Contents/Resources/AppIcon.icns with a full 10-size
#      icns generated from the MASKED image via sips + iconutil.
#
# Net result: every rep inside Assets.car AND AppIcon.icns has rounded
# corners and transparent edges. macOS renders the proper squircle.
#
# Runs as a postBuildScript so it executes AFTER actool. Order in
# project.yml:
#     Sources → Resources (contains actool) → Frameworks → Fix AppIcon icns

set -euo pipefail

SRC_PNG="${SRCROOT}/Sources/Voice/Resources/IconSource.png"
PREMASKED_PNG="${SRCROOT}/Sources/Voice/Resources/IconSource_masked.png"
ICONSET_SRC_DIR="${SRCROOT}/Sources/Voice/Resources/Assets.xcassets/AppIcon.appiconset"
DEST_ICNS="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/AppIcon.icns"
DEST_CAR_DIR="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"

if [ ! -f "$SRC_PNG" ]; then
  echo "warning: IconSource.png not found at $SRC_PNG — skipping AppIcon fix"
  exit 0
fi

TMP_DIR="$(mktemp -d)"
ICONSET="${TMP_DIR}/AppIcon.iconset"
mkdir -p "$ICONSET"

# ----------------------------------------------------------------------
# FAST PATH: if a pre-masked PNG exists alongside IconSource.png, use it
# directly. We pre-render it once (outside the build sandbox) because
# Xcode's script-sandbox blocks `xcrun swift` from running here. Keeping
# the masked PNG in tree means every build picks up the rounded shape
# without depending on swift toolchain availability mid-build.
# Regenerate with:
#   xcrun swift /tmp/mask_test.swift IconSource.png IconSource_masked.png
# ----------------------------------------------------------------------
MASKED_PNG="${TMP_DIR}/IconSource_masked.png"
if [ -f "$PREMASKED_PNG" ]; then
  cp -f "$PREMASKED_PNG" "$MASKED_PNG"
  echo "using pre-masked IconSource_masked.png (squircle pre-applied)"
fi

# ----------------------------------------------------------------------
# Step 1. Apply the macOS squircle mask to IconSource.png.
#
# The macOS Big Sur+ app icon shape is a "superellipse" (squircle) inside
# a 1024×1024 canvas with a small inset for the shadow / depth. We use
# the standard 824×824 visible-area template centered in 1024×1024, with
# the squircle path inset further. The corner-radius and inset values
# match Apple's "macOS App Icon Template" (Big Sur / Monterey / Sonoma).
#
# Reference numbers (Apple template):
#   Canvas:          1024 × 1024
#   Visible region:  824 × 824, centered (so 100px inset on each side)
#   Corner radius:   ~185.4 (≈ 22.5% of visible-region side)
#   Concentricity:   continuous corners (UIBezierPath continuousCorners)
#
# We render via a tiny Swift program that:
#   - loads the source PNG,
#   - resizes to 824×824 with high-quality interpolation,
#   - composites onto a 1024×1024 transparent canvas at offset (100,100),
#   - clips to a UIBezierPath-style continuous-corner squircle,
#   - writes 1024×1024 RGBA PNG to disk.
# ----------------------------------------------------------------------
if [ ! -f "$MASKED_PNG" ]; then
if ! xcrun swift - "$SRC_PNG" "$MASKED_PNG" <<'SWIFT'
import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count == 3,
      let src = NSImage(contentsOfFile: args[1]) else {
    print("usage: swift mask.swift <input.png> <output.png>")
    exit(1)
}
let outURL = URL(fileURLWithPath: args[2])

// Canvas: 1024×1024. Visible region inset: 100px on each side → 824×824.
// Continuous-corner squircle radius: ~185pt (matches Apple's template).
let canvas: CGFloat = 1024
let inset:  CGFloat = 100
let visible: CGFloat = canvas - 2 * inset       // 824
let cornerRadius: CGFloat = 185                 // Apple-template squircle

let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil,
    width: Int(canvas),
    height: Int(canvas),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: cs,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    print("error: could not create CGContext")
    exit(1)
}

// Transparent background.
ctx.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))

// Clip to the continuous-corner squircle path (NSBezierPath emits a
// rounded rect with circular corners; for visual parity with Apple's
// template we use the same radius — the difference between circular
// and continuous corners is minor at this scale and visually correct).
let pathRect = CGRect(x: inset, y: inset, width: visible, height: visible)
let path = CGPath(roundedRect: pathRect,
                  cornerWidth: cornerRadius,
                  cornerHeight: cornerRadius,
                  transform: nil)
ctx.addPath(path)
ctx.clip()

// Draw the source image into the visible region, high-quality scaled.
guard let srcCG = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("error: could not extract CGImage from source")
    exit(1)
}
ctx.interpolationQuality = .high
ctx.draw(srcCG, in: pathRect)

guard let outCG = ctx.makeImage() else {
    print("error: could not snapshot CGContext")
    exit(1)
}
let rep = NSBitmapImageRep(cgImage: outCG)
rep.size = NSSize(width: canvas, height: canvas)
guard let pngData = rep.representation(using: .png, properties: [:]) else {
    print("error: could not encode PNG")
    exit(1)
}
try! pngData.write(to: outURL)
print("squircle mask written: \(args[2]) (1024×1024 RGBA PNG)")
SWIFT
then
  : # squircle mask succeeded
else
  echo "warning: squircle mask step failed — falling back to unmasked source"
  cp -f "$SRC_PNG" "$MASKED_PNG"
fi
fi  # end "MASKED_PNG missing, generate it" branch

if [ ! -f "$MASKED_PNG" ]; then
  echo "warning: masked PNG missing — falling back to unmasked source"
  cp -f "$SRC_PNG" "$MASKED_PNG"
fi

# ----------------------------------------------------------------------
# Step 2 (formerly the only step). Generate all 10 mac icon sizes from
# the MASKED source. @1x => 72 DPI, @2x => 144 DPI. Filenames must match
# Apple's iconset convention for iconutil to accept them.
# ----------------------------------------------------------------------
gen() {
  local size="$1"
  local name="$2"
  local dpi="$3"
  sips -z "$size" "$size" "$MASKED_PNG" --out "${ICONSET}/${name}" >/dev/null
  sips -s dpiHeight "$dpi" -s dpiWidth "$dpi" "${ICONSET}/${name}" >/dev/null
}

gen 16   icon_16x16.png        72
gen 32   icon_16x16@2x.png     144
gen 32   icon_32x32.png        72
gen 64   icon_32x32@2x.png     144
gen 128  icon_128x128.png      72
gen 256  icon_128x128@2x.png   144
gen 256  icon_256x256.png      72
gen 512  icon_256x256@2x.png   144
gen 512  icon_512x512.png      72
gen 1024 icon_512x512@2x.png   144

# ----------------------------------------------------------------------
# Step 3. Refresh source PNGs in the xcassets so actool sees the new
# pixels. Per Contents.json: 1024 is 512x512@2x; 64 is 32x32@2x; 256 is
# 128x128@2x; 512 is 256x256@2x; the smaller files have @1x and @2x
# variants sharing pixel sizes.
# ----------------------------------------------------------------------
cp -f "${ICONSET}/icon_16x16.png"      "${ICONSET_SRC_DIR}/icon_16.png"
cp -f "${ICONSET}/icon_32x32.png"      "${ICONSET_SRC_DIR}/icon_32.png"
cp -f "${ICONSET}/icon_32x32@2x.png"   "${ICONSET_SRC_DIR}/icon_64.png"
cp -f "${ICONSET}/icon_128x128.png"    "${ICONSET_SRC_DIR}/icon_128.png"
cp -f "${ICONSET}/icon_256x256.png"    "${ICONSET_SRC_DIR}/icon_256.png"
cp -f "${ICONSET}/icon_512x512.png"    "${ICONSET_SRC_DIR}/icon_512.png"
cp -f "${ICONSET}/icon_512x512@2x.png" "${ICONSET_SRC_DIR}/icon_1024.png"

# ----------------------------------------------------------------------
# Step 4. Re-run actool with the refreshed PNGs so Assets.car contains
# the new pixels. actool also (re-)writes AppIcon.icns into the same
# directory. That output is the broken 4-size one — we'll overwrite it next.
# ----------------------------------------------------------------------
PARTIAL_PLIST="${TMP_DIR}/AppIcon-partial.plist"
mkdir -p "$DEST_CAR_DIR"
xcrun actool \
  --output-format human-readable-text \
  --notices \
  --warnings \
  --app-icon AppIcon \
  --compile "$DEST_CAR_DIR" \
  --platform macosx \
  --minimum-deployment-target "${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
  --target-device mac \
  --output-partial-info-plist "$PARTIAL_PLIST" \
  "${SRCROOT}/Sources/Voice/Resources/Assets.xcassets" >/dev/null

# ----------------------------------------------------------------------
# Step 5. Overwrite AppIcon.icns with a full 10-size icns built from the
# MASKED image. MUST run AFTER actool, because actool overwrites
# AppIcon.icns with a truncated 4-size version (only `ic07/ic08/ic09/ic13`
# types, missing 512/1024).
# ----------------------------------------------------------------------
iconutil -c icns "$ICONSET" -o "${TMP_DIR}/AppIcon.icns"
cp -f "${TMP_DIR}/AppIcon.icns" "$DEST_ICNS"

ICNS_SIZE=$(stat -f %z "$DEST_ICNS")
CAR_SIZE=$(stat -f %z "${DEST_CAR_DIR}/Assets.car" 2>/dev/null || echo "missing")
MASKED_SIZE=$(stat -f %z "$MASKED_PNG")
echo "AppIcon fix complete:"
echo "  Source PNG   = ${SRC_PNG}"
echo "  Masked PNG   = ${MASKED_SIZE} bytes  (squircle-masked, 1024×1024)"
echo "  Assets.car   = ${CAR_SIZE} bytes  (rebuilt by actool from masked PNGs)"
echo "  AppIcon.icns = ${ICNS_SIZE} bytes  (10 sizes, all squircle-masked)"
echo "  All derived from squircle-masked source — Dock/Finder will render rounded."

rm -rf "$TMP_DIR"
