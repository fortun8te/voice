// VOICE — Pill skin picker. Shown in the main BigMenuWindow above recents.
//
// Each thumb is a TRUE-SCALE preview of the skin — the card itself is the
// surface, with a sample pill rendered on top centered. The previous design
// used a small inner capsule on a dark card, which made every skin look the
// same from across the room. Now the card's background IS the skin's signature
// look (aurora mesh for aurora skins, dark glass for default, etc) and a small
// "VOICE" text-label pill sits inside as a recognizable affordance.
//
// Selection persisted via @AppStorage("pillSkin") with values:
//   "default" / "black" / "glass" / "niche" / "verdant" / "midnight"

import SwiftUI

struct PillSkinSelector: View {
    @AppStorage("pillSkin") private var pillSkin: String = "default"

    /// Bigger cards so the skin actually reads. 76×52pt landscape — closer
    /// to the real pill's aspect ratio than a square, lets you see the
    /// capsule shape more obviously.
    private let thumbW: CGFloat = 84
    private let thumbH: CGFloat = 56

    var body: some View {
        HStack(spacing: 12) {
            thumb(id: "glass",  label: "Glass",  kind: .glass)
            thumb(id: "black",  label: "Black",  kind: .black)
            thumb(id: "niche",  label: "Niche",  kind: .aurora(.iris))
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private enum SkinKind {
        case aurora(AuroraPalette)
        case black
        case glass
    }

    @ViewBuilder
    private func thumb(id: String, label: String, kind: SkinKind) -> some View {
        let selected = pillSkin == id

        VStack(spacing: 8) {
            ZStack {
                // CARD = the skin surface itself. The skin IS the preview;
                // the small inner capsule from the previous design read as
                // "container for a tiny pill" rather than "this is the look."
                preview(for: kind)
                    .frame(width: thumbW, height: thumbH)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                // A subtle pill silhouette so the user understands "this is
                // a pill skin." Sized to about 2/3 of the card, low-opacity
                // outline only — doesn't fight the skin surface behind it.
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.32), lineWidth: 0.8)
                    .frame(width: thumbW * 0.62, height: thumbH * 0.36)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            }
            // Selected indicator: soft accent ring + checkmark badge in the
            // top-right. Way less aggressive than the old fat red border.
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        selected ? Color.accentColor : Color.white.opacity(0.10),
                        lineWidth: selected ? 1.5 : 0.5
                    )
            )
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(4)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .scaleEffect(selected ? 1.03 : 1.0)
            .animation(.spring(response: 0.32, dampingFraction: 0.72), value: selected)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }
            .onTapGesture { pillSkin = id }

            Text(label)
                .font(.system(size: 11, weight: .medium))
                .tracking(0.2)
                .foregroundStyle(selected ? .primary : .secondary)
        }
    }

    /// The card's background — this IS the skin look at thumb size. No nested
    /// capsule; the whole thumb surface communicates the skin.
    @ViewBuilder
    private func preview(for kind: SkinKind) -> some View {
        switch kind {
        case .aurora(let palette):
            AuroraBackground(palette: palette)
                .padding(-4)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .allowsHitTesting(false)
                .overlay(
                    // Same glass-over-color treatment the real pill uses.
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                )
        case .black:
            // Pure matte obsidian — no glass, no gradient. High contrast.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black)
        case .glass:
            // Real Liquid Glass over a colorful gradient so the refraction is
            // actually visible — matches what the user will see when the pill
            // sits over their wallpaper.
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.32, green: 0.20, blue: 0.55),
                        Color(red: 0.55, green: 0.25, blue: 0.40),
                        Color(red: 0.20, green: 0.30, blue: 0.50),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .glassEffect(.clear.interactive(), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }
}
