// VOICE — Aurora animated mesh-gradient background for the dictation pill.
// On macOS 15+ uses SwiftUI's `MeshGradient` with animated control points;
// older systems fall back to a slowly-shifting `LinearGradient`. Designed
// to be clipped to a Capsule by the caller (we draw the full rect).
//
// Aspect-aware: the pill is a wide capsule (~120×28, ~4.3:1). A neutral
// 3×3 mesh would render a thin horizontal slice and hide most of the
// color richness shown in the reference. We instead lay out the control
// points so the visible band of the mesh contains every color blob.
//
// VARIETY: 6 distinct mesh variants are defined (A–F). On view init we
// pick one at random, so every pill mount feels fresh instead of always
// staring at the same indigo-top-left arrangement. Each variant is a
// hand-tuned 3×3 control grid + 9-color matrix that keeps the palette
// readable and the indigo "anchor blob" in a different spot.
//
// SEAMLESS LOOP: the animation parameter t cycles 0→2π every 16s. All
// drift terms use sin/cos of t scaled by integer multipliers, so the
// position at t=0 exactly equals the position at t=2π — no visible jump
// when the loop wraps. The color breath shares the same 16s clock.

import SwiftUI

struct AuroraBackground: View {
    // Palette extracted from the reference image. Two slightly different
    // palettes (a/b) are interpolated over time for subtle color breathing.
    // Set "a" = vibrant baseline, "b" = slightly cooler/more saturated.

    // a-palette (baseline)
    private let vibrantBlueA = Color(red: 0.231, green: 0.482, blue: 1.0)   // #3B7BFF
    private let deepIndigoA  = Color(red: 0.302, green: 0.251, blue: 1.0)   // #4D40FF
    private let magentaA     = Color(red: 0.769, green: 0.361, blue: 0.878) // #C45CE0
    private let lightPinkA   = Color(red: 0.961, green: 0.702, blue: 0.851) // #F5B3D9
    private let palePinkA    = Color(red: 1.0,   green: 0.831, blue: 0.898) // #FFD4E5
    private let skyBlueA     = Color(red: 0.420, green: 0.690, blue: 1.0)   // #6BB0FF

    // b-palette (slight cool/saturation lift)
    private let vibrantBlueB = Color(red: 0.180, green: 0.520, blue: 1.0)
    private let deepIndigoB  = Color(red: 0.345, green: 0.220, blue: 0.965)
    private let magentaB     = Color(red: 0.820, green: 0.380, blue: 0.910)
    private let lightPinkB   = Color(red: 0.980, green: 0.730, blue: 0.875)
    private let palePinkB    = Color(red: 1.0,   green: 0.855, blue: 0.910)
    private let skyBlueB     = Color(red: 0.380, green: 0.730, blue: 1.0)

    // Pick a variant ONCE per app process (not per view mount). A plain
    // `@State` with `Int.random(...)` re-rolls every time SwiftUI remounts
    // the view — and the niche pill remounts on every phase change, every
    // panel reposition, every skin re-evaluation. The result was a visible
    // gradient "glitch" where the colors shuffled mid-recording. A static
    // let initializes exactly once per process, so the look is stable for
    // the entire session.
    @State private var variantIndex: Int = AuroraBackground.sessionVariant

    private static let sessionVariant: Int = Int.random(in: 0..<6)

    var body: some View {
        // TimelineView at the display refresh rate (60Hz+) was driving a
        // full MeshGradient + 6-color lerp every vsync. The aurora's motion
        // is slow (mesh oscillates ~0.3–0.4 Hz, breath ~16s), so 30fps is
        // visually identical and roughly halves main-thread cost during
        // recording. paused:false explicitly so the view never freezes
        // when offscreen-ish.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            // Absolute wall-clock time — `timeIntervalSinceReferenceDate` is
            // CONTINUOUS across view remounts. If we used a per-mount
            // `startDate` reference, the animation phase would jump every
            // time the view remounted (phase change, panel reposition),
            // which is the visible "glitch" the user reports.
            let t = context.date.timeIntervalSinceReferenceDate
            content(t: t)
        }
        // NOTE: drawingGroup intentionally removed from here. The caller
        // (GlassCapsule) applies clipShape AFTER AuroraBackground renders —
        // if drawingGroup rasterizes first, the clip then operates on a flat
        // Metal texture whose edges don't anti-alias with the capsule path,
        // producing the visible gradient clipping glitch. By removing it here,
        // SwiftUI can apply the clip before compositing, which gives clean edges.
        .onAppear {
            print("[VOICE-AURORA] mounted variant=\(variantIndex) sessionVariant=\(AuroraBackground.sessionVariant)")
        }
    }

    @ViewBuilder
    private func content(t: TimeInterval) -> some View {
        if #available(macOS 15.0, *) {
            meshBody(t: t)
        } else {
            fallback(t: t)
        }
    }

    /// Lerp a single Color in sRGB — MeshGradient interpolates internally
    /// but we need to drive its INPUT colors with a slow breathing curve.
    private func lerp(_ a: Color, _ b: Color, _ k: Double) -> Color {
        let na = NSColor(a).usingColorSpace(.sRGB) ?? NSColor(a)
        let nb = NSColor(b).usingColorSpace(.sRGB) ?? NSColor(b)
        let r = na.redComponent   + (nb.redComponent   - na.redComponent)   * CGFloat(k)
        let g = na.greenComponent + (nb.greenComponent - na.greenComponent) * CGFloat(k)
        let bl = na.blueComponent + (nb.blueComponent  - na.blueComponent)  * CGFloat(k)
        return Color(red: Double(r), green: Double(g), blue: Double(bl))
    }

    // MARK: - Mesh variants

    /// A static arrangement of 9 control points + 9 colors. Each variant
    /// expresses a different "where do the colors live" composition while
    /// reusing the same animated drift math + breathing palette.
    private struct MeshVariant {
        /// Base positions for the 3×3 grid in [0,1] coords (slightly inset
        /// on the outer ring is fine; the mesh extends past the visible
        /// rect to allow color to bleed off the edges).
        let basePoints: [SIMD2<Float>]
        /// Indices into the breathing palette for each of the 9 grid slots.
        /// `0 = vibrantBlue, 1 = deepIndigo, 2 = magenta, 3 = lightPink,
        ///  4 = palePink,    5 = skyBlue`.
        let colorIndices: [Int]
    }

    /// Six hand-tuned variants. Each one places the "indigo anchor blob"
    /// somewhere different so the overall vibe changes meaningfully:
    ///   A — indigo mid-left, magenta center-right (original look)
    ///   B — indigo bottom-right, blue dominating top, pink middle
    ///   C — indigo dead center, sky-blue + pink wrapping outside
    ///   D — indigo right edge, sky-blue dominating left half
    ///   E — indigo top-right corner, sky-blue floor, magenta accent
    ///   F — indigo bottom-left, magenta + pink diagonal sweep top-right
    private static let variants: [MeshVariant] = [
        // --- A: original layout (indigo mid-left, magenta sweep) ---
        MeshVariant(
            basePoints: [
                SIMD2(-0.05, -0.05), SIMD2(0.42, -0.02), SIMD2(1.05, -0.05),
                SIMD2(-0.05,  0.40), SIMD2(0.38,  0.42), SIMD2(0.95,  0.55),
                SIMD2(-0.05,  1.05), SIMD2(0.55,  1.02), SIMD2(1.05,  1.05),
            ],
            // vBlue, vBlue, magenta / sky, indigo, lightPink / sky, magenta, palePink
            colorIndices: [0, 0, 2,  5, 1, 3,  5, 2, 4]
        ),
        // --- B: indigo bottom-right, blue band across the top ---
        MeshVariant(
            basePoints: [
                SIMD2(-0.05, -0.05), SIMD2(0.50, -0.02), SIMD2(1.05, -0.05),
                SIMD2(-0.05,  0.45), SIMD2(0.45,  0.50), SIMD2(1.05,  0.42),
                SIMD2(-0.05,  1.05), SIMD2(0.42,  1.02), SIMD2(0.68,  1.05),
            ],
            // vBlue, vBlue, vBlue / lightPink, magenta, lightPink / sky, magenta, indigo
            colorIndices: [0, 0, 0,  3, 2, 3,  5, 2, 1]
        ),
        // --- C: indigo dead center, color wrapping outside ---
        MeshVariant(
            basePoints: [
                SIMD2(-0.05, -0.05), SIMD2(0.50, -0.02), SIMD2(1.05, -0.05),
                SIMD2(-0.05,  0.50), SIMD2(0.50,  0.50), SIMD2(1.05,  0.50),
                SIMD2(-0.05,  1.05), SIMD2(0.50,  1.02), SIMD2(1.05,  1.05),
            ],
            // vBlue, sky, lightPink / sky, indigo, lightPink / vBlue, magenta, palePink
            colorIndices: [0, 5, 3,  5, 1, 3,  0, 2, 4]
        ),
        // --- D: indigo right edge, sky-blue dominating left half ---
        MeshVariant(
            basePoints: [
                SIMD2(-0.05, -0.05), SIMD2(0.45, -0.02), SIMD2(1.05, -0.05),
                SIMD2(-0.05,  0.50), SIMD2(0.40,  0.48), SIMD2(0.78,  0.50),
                SIMD2(-0.05,  1.05), SIMD2(0.50,  1.02), SIMD2(1.05,  1.05),
            ],
            // sky, magenta, magenta / sky, vBlue, indigo / sky, lightPink, palePink
            colorIndices: [5, 2, 2,  5, 0, 1,  5, 3, 4]
        ),
        // --- E: indigo top-right corner, sky-blue floor, magenta accent ---
        MeshVariant(
            basePoints: [
                SIMD2(-0.05, -0.05), SIMD2(0.55, -0.02), SIMD2(1.05, -0.05),
                SIMD2(-0.05,  0.45), SIMD2(0.50,  0.50), SIMD2(0.78,  0.35),
                SIMD2(-0.05,  1.05), SIMD2(0.55,  1.02), SIMD2(1.05,  1.05),
            ],
            // sky, vBlue, indigo / sky, sky, magenta / sky, lightPink, palePink
            colorIndices: [5, 0, 1,  5, 5, 2,  5, 3, 4]
        ),
        // --- F: indigo bottom-left, diagonal pink/magenta sweep up-right ---
        MeshVariant(
            basePoints: [
                SIMD2(-0.05, -0.05), SIMD2(0.50, -0.02), SIMD2(1.05, -0.05),
                SIMD2(-0.05,  0.48), SIMD2(0.55,  0.50), SIMD2(1.05,  0.55),
                SIMD2(-0.05,  1.05), SIMD2(0.35,  1.02), SIMD2(1.05,  1.05),
            ],
            // vBlue, vBlue, palePink / sky, magenta, lightPink / indigo, magenta, lightPink
            colorIndices: [0, 0, 4,  5, 2, 3,  1, 2, 3]
        ),
    ]

    @available(macOS 15.0, *)
    private func meshBody(t: TimeInterval) -> some View {
        // ---- Seamless loop math ----
        // Map wall-clock time onto a single 2π phase that completes a
        // full cycle every `cycleDuration` seconds. Because every drift
        // term below is sin/cos of an INTEGER multiple of `theta` (1, 2,
        // or 3), each term completes a whole number of cycles per loop —
        // so the mesh at theta=0 exactly equals the mesh at theta=2π and
        // there is no visible jump on wrap-around.
        let cycleDuration: Double = 16.0
        let theta = (t.truncatingRemainder(dividingBy: cycleDuration)
                     / cycleDuration) * 2.0 * .pi

        // Per-point phase/frequency so motion looks organic but still loops.
        // Amplitudes are kept conservative (≤0.14 mid, ≤0.06 edge) so that
        // when combined with the base point positions, no control point
        // strays far outside [0,1]. MeshGradient tolerates a little overshoot
        // (the corners sit at -0.05/1.05 by design to bleed color off-edge),
        // but if a mid-point swings past ~-0.2 or 1.2 the gradient develops
        // visible discontinuities — the "bugging out" the user reported.
        let aMid: Float  = 0.14
        let aEdge: Float = 0.06

        // Middle point — biggest amplitude, the "anchor blob" we can see breathe.
        let mx = Float(sin(theta * 1.0 + 0.0)) * aMid
        let my = Float(cos(theta * 1.0 + 0.0)) * aMid * 0.85
        // Mid-left and mid-right — slightly smaller, offset phases.
        let lx = Float(sin(theta * 1.0 + 1.3)) * aMid * 0.75
        let ly = Float(cos(theta * 1.0 + 0.8)) * aMid * 0.60
        let rx = Float(sin(theta * 1.0 + 2.4)) * aMid * 0.75
        let ry = Float(cos(theta * 1.0 + 1.9)) * aMid * 0.60
        // Top and bottom edge mid-points — slow, low-amplitude wobble.
        let tx = Float(sin(theta * 1.0 + 0.4)) * aEdge
        let bx = Float(cos(theta * 1.0 + 1.7)) * aEdge

        // Pull the chosen variant. Bounds-checked via modulo in case the
        // variant count and the random range ever drift apart.
        let variant = Self.variants[variantIndex % Self.variants.count]
        let base = variant.basePoints

        // Apply drift to the same positions the old code did:
        //   row-1 cols 0/1/2 get lx/ly, mx/my, rx/ry
        //   row-0 col 1 gets tx, row-2 col 1 gets bx
        // Corner points stay exactly anchored so the rect always fills.
        // Defensive clamp: keep every control point inside a slightly-padded
        // unit square. Corners use [-0.05, 1.05] (intentional bleed); mid
        // points are clamped to [-0.15, 1.15] so the drift can't ever push
        // them into territory where MeshGradient produces visible glitches.
        func clampMid(_ v: Float) -> Float { min(max(v, -0.15), 1.15) }
        func clampEdge(_ v: Float) -> Float { min(max(v, -0.10), 1.10) }
        let points: [SIMD2<Float>] = [
            base[0],
            SIMD2(clampEdge(base[1].x + tx), base[1].y),
            base[2],
            SIMD2(clampMid(base[3].x + lx), clampMid(base[3].y + ly)),
            SIMD2(clampMid(base[4].x + mx), clampMid(base[4].y + my)),
            SIMD2(clampMid(base[5].x + rx), clampMid(base[5].y + ry)),
            base[6],
            SIMD2(clampEdge(base[7].x + bx), base[7].y),
            base[8],
        ]

        // Slow color breath — one full cycle per loop, so the colors also
        // return exactly to their starting values at theta=2π. The 0.5+0.5
        // wrap keeps k in [0,1] for the palette lerp.
        let k = 0.5 + 0.5 * sin(theta)

        let vibrantBlue = lerp(vibrantBlueA, vibrantBlueB, k)
        let deepIndigo  = lerp(deepIndigoA,  deepIndigoB,  k)
        let magenta     = lerp(magentaA,     magentaB,     k)
        let lightPink   = lerp(lightPinkA,   lightPinkB,   k)
        let palePink    = lerp(palePinkA,    palePinkB,    k)
        let skyBlue     = lerp(skyBlueA,     skyBlueB,     k)

        // Look up colors by the variant's index list.
        let palette: [Color] = [vibrantBlue, deepIndigo, magenta, lightPink, palePink, skyBlue]
        let colors: [Color] = variant.colorIndices.map { palette[$0] }

        return MeshGradient(
            width: 3,
            height: 3,
            points: points,
            colors: colors,
            smoothsColors: true
        )
    }

    private func fallback(t: TimeInterval) -> some View {
        // Pre-macOS 15: slowly rotate a multi-stop linear gradient between
        // the same palette. Less rich than the mesh, but visually consistent.
        let angle = Angle.degrees((t * 18.0).truncatingRemainder(dividingBy: 360))
        let pulse = 0.5 + 0.5 * sin(t * 0.6)
        return LinearGradient(
            stops: [
                .init(color: vibrantBlueA,                              location: 0.00),
                .init(color: deepIndigoA.opacity(0.85 + pulse * 0.15),  location: 0.25),
                .init(color: magentaA,                                  location: 0.50),
                .init(color: lightPinkA,                                location: 0.75),
                .init(color: palePinkA,                                 location: 1.00),
            ],
            startPoint: UnitPoint(x: 0.5 + 0.5 * cos(angle.radians),
                                  y: 0.5 + 0.5 * sin(angle.radians)),
            endPoint:   UnitPoint(x: 0.5 - 0.5 * cos(angle.radians),
                                  y: 0.5 - 0.5 * sin(angle.radians))
        )
    }
}
