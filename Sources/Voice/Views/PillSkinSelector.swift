// VOICE — Pill skin picker. Shown in the main BigMenuWindow above recents.
// Two SQUARE thumbnails using the actual reference images for "Default" and "Niche".
// Selection is persisted via @AppStorage("pillSkin") with values
// "default" and "niche".

import SwiftUI

struct PillSkinSelector: View {
    @AppStorage("pillSkin") private var pillSkin: String = "default"

    /// Edge length of each square thumbnail. ~100pt fits the 440pt window nicely
    /// (two squares + 14pt gap + horizontal padding still leaves breathing room).
    private let thumbSize: CGFloat = 100

    var body: some View {
        HStack(spacing: 14) {
            thumb(id: "default", label: "Default", imageName: "SkinDefault")
            thumb(id: "niche",   label: "Niche",   imageName: "SkinNiche")
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func thumb(id: String, label: String, imageName: String) -> some View {
        let selected = pillSkin == id
        VStack(spacing: 6) {
            Image(imageName)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: thumbSize, height: thumbSize)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            selected ? Color.accentColor : Color.white.opacity(0.12),
                            lineWidth: selected ? 3 : 0.5
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .onTapGesture {
                    pillSkin = id
                }

            Text(label)
                .font(.system(size: 11, weight: .medium, design: .default))
                .tracking(0.2)
                .foregroundStyle(selected ? .primary : .secondary)
        }
    }
}
