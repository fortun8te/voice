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
//
// OVER-COVER (no-clip): a MeshGradient's colored field only exists inside
// the convex hull of its outer control ring. To guarantee the field always
// fills (and over-fills) the capsule/circle the caller clips it to, the
// entire 8-point outer ring is pinned WELL outside the unit square (corners
// at ±0.25 beyond [0,1], edge midpoints at -0.2 / 1.2 on their outer axis).
// Only the single CENTER control point animates. The interior color blobs
// still breathe, but the field can never recede inside the frame on any
// phase or palette — so there is no visible clipping/seam. See `meshBody`.

import SwiftUI

/// Color theme for the aurora mesh. Each case maps to a 6-color × 2-palette
/// (a/b breathing) palette. All three palettes share the SAME mesh layout
/// and animation curves — only the colors differ.
enum AuroraPalette {
    case iris        // original pink/indigo/sky (default)
    case verdant     // jungle/forest greens + tropical teals
    case midnight    // deep navy/cobalt + ice highlights
    case ember       // smoldering charcoal + iron-orange embers
    case opaline     // mother-of-pearl, cool lilac over oyster graphite
    case saffron     // spice-market dusk, turmeric + rose + ink
}

struct AuroraBackground: View {
    /// Pick the color theme. Caller passes one of `.iris` / `.verdant` /
    /// `.midnight` based on user's selected skin. Default keeps the original
    /// pink/indigo aurora so all existing call sites keep working unchanged.
    var palette: AuroraPalette = .iris

    // MARK: - Palette pairs (a = baseline, b = slight saturation/temp lift)

    private var vibrantBlueA: Color { Self.color(for: palette, slot: .vibrant,    variant: .a) }
    private var deepIndigoA:  Color { Self.color(for: palette, slot: .deep,       variant: .a) }
    private var magentaA:     Color { Self.color(for: palette, slot: .magenta,    variant: .a) }
    private var lightPinkA:   Color { Self.color(for: palette, slot: .lightPink,  variant: .a) }
    private var palePinkA:    Color { Self.color(for: palette, slot: .palePink,   variant: .a) }
    private var skyBlueA:     Color { Self.color(for: palette, slot: .skyBlue,    variant: .a) }

    private var vibrantBlueB: Color { Self.color(for: palette, slot: .vibrant,    variant: .b) }
    private var deepIndigoB:  Color { Self.color(for: palette, slot: .deep,       variant: .b) }
    private var magentaB:     Color { Self.color(for: palette, slot: .magenta,    variant: .b) }
    private var lightPinkB:   Color { Self.color(for: palette, slot: .lightPink,  variant: .b) }
    private var palePinkB:    Color { Self.color(for: palette, slot: .palePink,   variant: .b) }
    private var skyBlueB:     Color { Self.color(for: palette, slot: .skyBlue,    variant: .b) }

    private enum Slot { case vibrant, deep, magenta, lightPink, palePink, skyBlue }
    private enum Variant { case a, b }

    /// Centralised palette table. Comments give the role each slot plays —
    /// `vibrant` is the bright punch, `deep` is the anchor blob, `magenta` is
    /// the accent, `lightPink` / `palePink` are the soft washes, `skyBlue` is
    /// the cool transition tone.
    private static func color(for p: AuroraPalette, slot: Slot, variant: Variant) -> Color {
        switch p {
        case .iris:
            switch (slot, variant) {
            case (.vibrant,   .a): return Color(red: 0.231, green: 0.482, blue: 1.0)   // #3B7BFF
            case (.vibrant,   .b): return Color(red: 0.180, green: 0.520, blue: 1.0)
            case (.deep,      .a): return Color(red: 0.302, green: 0.251, blue: 1.0)   // #4D40FF
            case (.deep,      .b): return Color(red: 0.345, green: 0.220, blue: 0.965)
            case (.magenta,   .a): return Color(red: 0.769, green: 0.361, blue: 0.878) // #C45CE0
            case (.magenta,   .b): return Color(red: 0.820, green: 0.380, blue: 0.910)
            case (.lightPink, .a): return Color(red: 0.961, green: 0.702, blue: 0.851) // #F5B3D9
            case (.lightPink, .b): return Color(red: 0.980, green: 0.730, blue: 0.875)
            case (.palePink,  .a): return Color(red: 1.0,   green: 0.831, blue: 0.898) // #FFD4E5
            case (.palePink,  .b): return Color(red: 1.0,   green: 0.855, blue: 0.910)
            case (.skyBlue,   .a): return Color(red: 0.420, green: 0.690, blue: 1.0)   // #6BB0FF
            case (.skyBlue,   .b): return Color(red: 0.380, green: 0.730, blue: 1.0)
            }
        case .verdant:
            // Jungle/forest theme. Bright leafy lime + deep moss anchor + a
            // tropical teal accent in the "magenta" slot. The pink slots
            // become soft fern/mist tints; sky slot becomes sage.
            switch (slot, variant) {
            case (.vibrant,   .a): return Color(red: 0.231, green: 0.847, blue: 0.451) // #3BD873 lush lime-green
            case (.vibrant,   .b): return Color(red: 0.180, green: 0.812, blue: 0.502)
            case (.deep,      .a): return Color(red: 0.063, green: 0.349, blue: 0.231) // #105938 deep forest moss (anchor)
            case (.deep,      .b): return Color(red: 0.094, green: 0.392, blue: 0.243)
            case (.magenta,   .a): return Color(red: 0.180, green: 0.769, blue: 0.690) // #2EC4B0 tropical teal accent
            case (.magenta,   .b): return Color(red: 0.220, green: 0.800, blue: 0.706)
            case (.lightPink, .a): return Color(red: 0.706, green: 0.949, blue: 0.784) // #B4F2C8 pale fern
            case (.lightPink, .b): return Color(red: 0.745, green: 0.961, blue: 0.808)
            case (.palePink,  .a): return Color(red: 0.882, green: 0.961, blue: 0.871) // #E1F5DE soft mist wash
            case (.palePink,  .b): return Color(red: 0.902, green: 0.973, blue: 0.890)
            case (.skyBlue,   .a): return Color(red: 0.420, green: 0.847, blue: 0.690) // #6BD8B0 sage-cyan
            case (.skyBlue,   .b): return Color(red: 0.380, green: 0.812, blue: 0.722)
            }
        case .midnight:
            // Deep navy theme. Cobalt punch + near-black abyss anchor + a
            // slight purple in the magenta slot for depth. Soft ice/azure
            // tints for the highlight slots.
            switch (slot, variant) {
            case (.vibrant,   .a): return Color(red: 0.180, green: 0.349, blue: 0.969) // #2E59F7 cobalt punch
            case (.vibrant,   .b): return Color(red: 0.141, green: 0.396, blue: 1.0)
            case (.deep,      .a): return Color(red: 0.027, green: 0.063, blue: 0.243) // #07103E abyss navy anchor
            case (.deep,      .b): return Color(red: 0.039, green: 0.094, blue: 0.290)
            case (.magenta,   .a): return Color(red: 0.318, green: 0.247, blue: 0.706) // #513FB4 royal-violet accent
            case (.magenta,   .b): return Color(red: 0.349, green: 0.275, blue: 0.749)
            case (.lightPink, .a): return Color(red: 0.620, green: 0.776, blue: 0.949) // #9EC6F2 pale azure
            case (.lightPink, .b): return Color(red: 0.659, green: 0.804, blue: 0.961)
            case (.palePink,  .a): return Color(red: 0.871, green: 0.918, blue: 0.969) // #DEEAF7 ice white
            case (.palePink,  .b): return Color(red: 0.890, green: 0.937, blue: 0.980)
            case (.skyBlue,   .a): return Color(red: 0.290, green: 0.561, blue: 0.847) // #4A8FD8 steel sky
            case (.skyBlue,   .b): return Color(red: 0.243, green: 0.522, blue: 0.890)
            }
        case .ember:
            // Smoldering charcoal + iron-orange embers. Glows from within without
            // ever turning into a generic sunset; the anchor is near-black coal.
            switch (slot, variant) {
            case (.vibrant,   .a): return Color(red: 0.961, green: 0.435, blue: 0.149) // #F56F26 ember orange
            case (.vibrant,   .b): return Color(red: 0.984, green: 0.482, blue: 0.122)
            case (.deep,      .a): return Color(red: 0.106, green: 0.063, blue: 0.078) // #1B1014 coal anchor
            case (.deep,      .b): return Color(red: 0.137, green: 0.078, blue: 0.090)
            case (.magenta,   .a): return Color(red: 0.706, green: 0.196, blue: 0.231) // #B4323B oxidized cinnabar
            case (.magenta,   .b): return Color(red: 0.745, green: 0.220, blue: 0.212)
            case (.lightPink, .a): return Color(red: 0.961, green: 0.706, blue: 0.471) // #F5B478 warm ash glow
            case (.lightPink, .b): return Color(red: 0.973, green: 0.733, blue: 0.494)
            case (.palePink,  .a): return Color(red: 0.980, green: 0.847, blue: 0.706) // #FAD8B4 pale ember haze
            case (.palePink,  .b): return Color(red: 0.988, green: 0.867, blue: 0.733)
            case (.skyBlue,   .a): return Color(red: 0.553, green: 0.302, blue: 0.227) // #8D4D3A scorched bronze
            case (.skyBlue,   .b): return Color(red: 0.596, green: 0.329, blue: 0.235)
            }
        case .opaline:
            // Mother-of-pearl: cool lilac shimmer over a deep oyster-graphite anchor.
            switch (slot, variant) {
            case (.vibrant,   .a): return Color(red: 0.541, green: 0.776, blue: 0.890) // #8AC6E3 cool nacre
            case (.vibrant,   .b): return Color(red: 0.580, green: 0.812, blue: 0.918)
            case (.deep,      .a): return Color(red: 0.137, green: 0.149, blue: 0.196) // #232632 oyster graphite anchor
            case (.deep,      .b): return Color(red: 0.157, green: 0.169, blue: 0.220)
            case (.magenta,   .a): return Color(red: 0.737, green: 0.620, blue: 0.831) // #BC9ED4 lilac shimmer
            case (.magenta,   .b): return Color(red: 0.776, green: 0.651, blue: 0.859)
            case (.lightPink, .a): return Color(red: 0.918, green: 0.871, blue: 0.890) // #EADEE3 pearl wash
            case (.lightPink, .b): return Color(red: 0.937, green: 0.886, blue: 0.902)
            case (.palePink,  .a): return Color(red: 0.949, green: 0.937, blue: 0.918) // #F2EFEA bone cream
            case (.palePink,  .b): return Color(red: 0.961, green: 0.953, blue: 0.937)
            case (.skyBlue,   .a): return Color(red: 0.620, green: 0.706, blue: 0.776) // #9EB4C6 silver-mist
            case (.skyBlue,   .b): return Color(red: 0.655, green: 0.737, blue: 0.808)
            }
        case .saffron:
            // Spice-market dusk: turmeric punch, dried-rose accent, indigo-black anchor.
            switch (slot, variant) {
            case (.vibrant,   .a): return Color(red: 0.945, green: 0.690, blue: 0.196) // #F1B032 turmeric punch
            case (.vibrant,   .b): return Color(red: 0.961, green: 0.722, blue: 0.176)
            case (.deep,      .a): return Color(red: 0.071, green: 0.055, blue: 0.122) // #120E1F ink anchor
            case (.deep,      .b): return Color(red: 0.090, green: 0.071, blue: 0.149)
            case (.magenta,   .a): return Color(red: 0.706, green: 0.275, blue: 0.318) // #B44651 dried rose
            case (.magenta,   .b): return Color(red: 0.745, green: 0.298, blue: 0.302)
            case (.lightPink, .a): return Color(red: 0.949, green: 0.792, blue: 0.561) // #F2CA8F saffron cream
            case (.lightPink, .b): return Color(red: 0.965, green: 0.812, blue: 0.580)
            case (.palePink,  .a): return Color(red: 0.965, green: 0.890, blue: 0.769) // #F6E3C4 pale clove
            case (.palePink,  .b): return Color(red: 0.973, green: 0.906, blue: 0.788)
            case (.skyBlue,   .a): return Color(red: 0.392, green: 0.275, blue: 0.435) // #64466F bruised plum
            case (.skyBlue,   .b): return Color(red: 0.420, green: 0.290, blue: 0.471)
            }
        }
    }

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
        // is slow (mesh oscillates ~0.3–0.4 Hz, breath ~16s) — the mesh
        // control points only meaningfully shift at ~3 Hz, so 15fps is
        // visually identical and quarter the main-thread cost vs. 60fps.
        // paused:false explicitly so the view never freezes when offscreen-ish.
        TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: false)) { context in
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
            #if DEBUG
            if voiceVerbose { print("[VOICE-AURORA] mounted variant=\(variantIndex) sessionVariant=\(AuroraBackground.sessionVariant)") }
            #endif
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
        /// Base positions for the 3×3 grid in [0,1]-ish coords. NOTE: only the
        /// INNER components of the edge-midpoints (base[1].x / base[7].x for
        /// the top/bottom mids, base[3].y / base[5].y for the left/right mids)
        /// and the CENTER point (base[4]) are actually used at render time —
        /// `meshBody` pins the whole outer ring far outside the unit square
        /// for over-cover (see the OVER-COVER note at the top of this file).
        /// The corner entries and the outer-axis edge components are retained
        /// only as documentation of each variant's original composition.
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

        // ---- Over-cover geometry (the clipping fix) ----
        // A MeshGradient's COLORED FIELD only exists inside the convex hull of
        // its outer control ring. The previous layout pinned the corners at
        // only -0.05/1.05 and let the mid/edge points oscillate INWARD, so on
        // some phases/palettes the field receded inside the capsule frame and
        // the corners revealed the underlying material — the "clipping" the
        // user saw. Overscan via scaleEffect was a partial patch.
        //
        // Fix: shove the ENTIRE outer ring (all 8 perimeter points) well
        // outside the unit square so the field always extends past the visible
        // capsule on every frame and every palette. Only the CENTER point
        // breathes — the interior blobs still move, but the field never
        // recedes. Geometry, not color, so this is palette-agnostic.
        let outerLo: Float = -0.25   // corner outer coordinate (top/left)
        let outerHi: Float =  1.25   // corner outer coordinate (bottom/right)
        let edgeLo:  Float = -0.20   // edge-midpoint outer coordinate
        let edgeHi:  Float =  1.20

        // Center point — the only animated control point now. Keep the
        // original conservative amplitude so the "anchor blob" still breathes.
        // Because the whole outer ring sits far outside [0,1], the center can
        // swing freely within the interior without ever creating a seam.
        let aMid: Float = 0.14
        let mx = Float(sin(theta * 1.0 + 0.0)) * aMid
        let my = Float(cos(theta * 1.0 + 0.0)) * aMid * 0.85

        // Pull the chosen variant. Bounds-checked via modulo in case the
        // variant count and the random range ever drift apart.
        let variant = Self.variants[variantIndex % Self.variants.count]
        let base = variant.basePoints

        // Build the grid. The outer ring's OUTER axis is pinned far outside
        // the frame; we preserve each variant's INNER axis on the edge mids
        // (e.g. base[1].x, base[7].x, base[3].y, base[5].y) so the per-variant
        // colour sweep / anchor placement still reads. Only base[4] (center)
        // gets the drift, then it's clamped to the interior as a guard.
        //   [0]=TL [1]=TM [2]=TR
        //   [3]=ML [4]=C  [5]=MR
        //   [6]=BL [7]=BM [8]=BR
        func clampCenter(_ v: Float) -> Float { min(max(v, 0.12), 0.88) }
        let points: [SIMD2<Float>] = [
            SIMD2(outerLo, outerLo),                       // TL
            SIMD2(base[1].x, edgeLo),                      // TM (keep variant x, push y up)
            SIMD2(outerHi, outerLo),                       // TR
            SIMD2(edgeLo, base[3].y),                       // ML (push x left, keep variant y)
            SIMD2(clampCenter(base[4].x + mx),
                  clampCenter(base[4].y + my)),             // C  (the only breather)
            SIMD2(edgeHi, base[5].y),                       // MR (push x right, keep variant y)
            SIMD2(outerLo, outerHi),                        // BL
            SIMD2(base[7].x, edgeHi),                       // BM (keep variant x, push y down)
            SIMD2(outerHi, outerHi),                        // BR
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
