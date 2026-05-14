#!/bin/bash
# Regenerate all AppIcon sizes from the 1024 master using sips.
# Run after replacing icon_1024.png with a new master image.

ICONSET_DIR="/Users/mk/Downloads/Voice/Sources/Voice/Resources/Assets.xcassets/AppIcon.appiconset"
MASTER="$ICONSET_DIR/icon_1024.png"

if [ ! -f "$MASTER" ]; then
    echo "ERROR: master icon not found at $MASTER"
    exit 1
fi

sips -z 16 16     "$MASTER" --out "$ICONSET_DIR/icon_16.png"
sips -z 32 32     "$MASTER" --out "$ICONSET_DIR/icon_32.png"
sips -z 64 64     "$MASTER" --out "$ICONSET_DIR/icon_64.png"
sips -z 128 128   "$MASTER" --out "$ICONSET_DIR/icon_128.png"
sips -z 256 256   "$MASTER" --out "$ICONSET_DIR/icon_256.png"
sips -z 512 512   "$MASTER" --out "$ICONSET_DIR/icon_512.png"

echo "Icons regenerated from master"
