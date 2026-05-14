#!/usr/bin/env python3
"""Generate Voice app icon - dark background with waveform bars (stdlib only)"""
import struct, zlib, os

def make_png(width, height, pixels):
    """pixels is a flat list of (r,g,b) tuples"""
    def chunk(name, data):
        c = struct.pack('>I', len(data)) + name + data
        return c + struct.pack('>I', zlib.crc32(name + data) & 0xffffffff)

    sig = b'\x89PNG\r\n\x1a\n'
    ihdr = chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))  # RGB

    # Build image data
    raw = bytearray()
    for y in range(height):
        raw.append(0)  # filter byte
        for x in range(width):
            r, g, b = pixels[y * width + x]
            raw.extend([r, g, b])

    idat = chunk(b'IDAT', zlib.compress(bytes(raw), 9))
    iend = chunk(b'IEND', b'')
    return sig + ihdr + idat + iend

def make_icon(size):
    pixels = []
    cx, cy = size // 2, size // 2

    # Waveform bars: 9 bars with organic asymmetric pattern (voice intensity profile)
    bar_heights = [0.2, 0.4, 0.7, 0.9, 0.95, 0.8, 0.5, 0.3, 0.15]
    n_bars = len(bar_heights)
    bar_w = max(1, int(size * 0.08))
    gap = max(1, int(size * 0.045))
    total_w = n_bars * bar_w + (n_bars - 1) * gap
    start_x = cx - total_w // 2

    # Rounded bar caps: compute bar rects
    bars = []
    for i, bh in enumerate(bar_heights):
        bx = start_x + i * (bar_w + gap)
        bar_height_px = int(size * 0.58 * bh)
        bar_top = cy - bar_height_px // 2
        bar_bottom = cy + bar_height_px // 2
        bars.append((bx, bar_top, bx + bar_w, bar_bottom, bar_height_px))

    for y in range(size):
        for x in range(size):
            # Background: #0F1117
            r, g, b = 15, 17, 23

            # Check if pixel is inside a waveform bar (with rounded caps)
            for (bx0, bt, bx1, bb, bh) in bars:
                if bx0 <= x < bx1 and bt <= y <= bb:
                    # Rounded top cap
                    radius = bar_w // 2
                    # Top half-circle
                    if y < bt + radius:
                        dx = x - (bx0 + bx1) // 2
                        dy = y - (bt + radius)
                        if dx * dx + dy * dy > radius * radius:
                            continue
                    # Bottom half-circle
                    elif y > bb - radius:
                        dx = x - (bx0 + bx1) // 2
                        dy = y - (bb - radius)
                        if dx * dx + dy * dy > radius * radius:
                            continue
                    # Soft white bars: #E8E8F0
                    r, g, b = 232, 232, 240
                    break

            pixels.append((r, g, b))

    return make_png(size, size, pixels)

iconset = "/Users/mk/Downloads/Voice/Sources/Voice/Resources/Assets.xcassets/AppIcon.appiconset"
sizes = [16, 32, 64, 128, 256, 512, 1024]
filenames = {
    16: "icon_16",
    32: "icon_32",
    64: "icon_64",
    128: "icon_128",
    256: "icon_256",
    512: "icon_512",
    1024: "icon_1024",
}

for size in sizes:
    data = make_icon(size)
    path = os.path.join(iconset, filenames[size] + ".png")
    with open(path, 'wb') as f:
        f.write(data)
    print(f"Generated {size}x{size} -> {filenames[size]}.png")

print("Done!")
