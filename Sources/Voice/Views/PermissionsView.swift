// VOICE Permissions Onboarding View
// ============================================================
// Single-screen "set up VOICE" flow modeled after the iFurySt
// open-codex-computer-use PermissionOnboardingApp. Same skeleton:
//
//   1. Hero icon + serif title + sans subtitle.
//   2. A drag affordance row that visualizes the action: VOICE icon
//      -> arrow -> System Settings tile. The tile accepts a drop of
//      the Voice.app icon (or any .app) and opens the Privacy pane
//      for the first ungranted permission. This is mostly a visual
//      metaphor; every row also has an explicit button.
//   3. A vertical list of permission rows, one per
//      `PermissionsService.Kind`. Each row carries a status pill on
//      the right plus an action button when not granted.
//   4. A "Re-check permissions" button. The view also auto-polls via
//      `PermissionsService.startMonitoring()` while visible.
//
// When `service.allGranted` flips to true the view calls `onDone()`,
// letting the parent decide what to do (dismiss, navigate, etc.).
//
// Layout uses Sp (module-level spacing scale defined in
// BigMenuWindow.swift) and Typography tokens from Theme/Typography.swift.
// Card visuals match CleanupCard / PersonalityCard; 14pt radius,
// hairline border at Color.primary.opacity(0.06), and a 1.5pt accent
// border at Color.accentColor.opacity(0.55) when "active" (here: the
// next row a user should attend to).
// ============================================================

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PermissionsView: View {
    // MARK: Inputs

    /// Fired when every required permission is granted. The view does
    /// not navigate or close; the parent decides what "done" means in
    /// its surrounding context (collapse the section, push to the next
    /// onboarding step, etc.).
    var onDone: () -> Void

    // MARK: State

    @State private var service = PermissionsService.shared
    @State private var isDropTargeted = false
    @State private var lastCompletionNotified = false

    // MARK: Layout constants
    //
    // Pulled out so the hero numbers stay readable. The card radius is
    // re-used from BigMenuWindow's CardShape (14pt) but copied here as
    // a literal to avoid leaking that private type across the file. The
    // 14 / 1.0 / 1.5 / 0.06 / 0.55 values are the documented norms.

    private let cardCorner: CGFloat = 14
    private let cardBorderUnselected: CGFloat = 1.0
    private let cardBorderSelected: CGFloat = 1.5
    private let appIconSize: CGFloat = 80
    private let dragTileSize: CGFloat = 88

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Sp.xl) {
                heroSection
                dragAffordanceSection
                permissionRows
                footer
            }
            .padding(.horizontal, Sp.xxl)
            .padding(.vertical, Sp.xxl)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .task {
            service.startMonitoring()
        }
        .onDisappear {
            service.stopMonitoring()
        }
        .onChange(of: service.allGranted) { _, newValue in
            // Fire onDone exactly once when all required permissions go
            // from incomplete to complete. We re-arm if the user revokes
            // a permission and grants it again, so a single view
            // instance can drive multiple completion events.
            if newValue, !lastCompletionNotified {
                lastCompletionNotified = true
                onDone()
            } else if !newValue {
                lastCompletionNotified = false
            }
        }
    }

    // MARK: Hero

    @ViewBuilder
    private var heroSection: some View {
        VStack(alignment: .leading, spacing: Sp.sm) {
            HStack(alignment: .center, spacing: Sp.lg) {
                appIcon
                    .frame(width: appIconSize, height: appIconSize)

                VStack(alignment: .leading, spacing: Sp.xs) {
                    Text("Set up VOICE")
                        .font(.serifTitle)
                        .foregroundStyle(.primary)
                    Text("Grant a few permissions so VOICE can listen and paste.")
                        .font(.bodyLarge)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var appIcon: some View {
        if let nsImage = NSImage(named: NSImage.Name("AppIcon")) {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            // Fallback for the rare case that the asset catalog has not
            // baked the icon yet (e.g. running tests). We use a neutral
            // tile instead of a broken-image glyph.
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.primary.opacity(0.08))
                .overlay(
                    Image(systemName: "waveform")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(.secondary)
                )
        }
    }

    // MARK: Drag affordance
    //
    // Two tiles joined by an arrow. The left tile shows the VOICE
    // icon ("here is the app"), the right tile shows the destination
    // ("System Settings -> Privacy & Security"). The right tile accepts
    // a drop of file URLs. When the user drops a .app onto it, we open
    // the deep-link for the first ungranted permission. The drop is a
    // gimmick; the explicit per-row buttons below do the same thing
    // more reliably; but the affordance makes the relationship clear
    // to first-time users who do not yet know what "Privacy & Security"
    // means.

    @ViewBuilder
    private var dragAffordanceSection: some View {
        HStack(spacing: Sp.lg) {
            voiceDragSourceTile
            Image(systemName: "arrow.right")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            systemSettingsDropTile
        }
        .frame(maxWidth: .infinity)
        .padding(Sp.lg)
        .background(
            RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: cardBorderUnselected)
        )
    }

    @ViewBuilder
    private var voiceDragSourceTile: some View {
        VStack(spacing: Sp.sm) {
            appIcon
                .frame(width: dragTileSize - Sp.xl, height: dragTileSize - Sp.xl)
            Text("VOICE")
                .font(.label)
                .tracking(0.8)
                .foregroundStyle(.secondary)
        }
        .frame(width: dragTileSize + Sp.xl, height: dragTileSize + Sp.sm)
        .padding(Sp.sm)
        .background(
            RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: cardBorderUnselected)
        )
    }

    @ViewBuilder
    private var systemSettingsDropTile: some View {
        VStack(spacing: Sp.sm) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("System Settings")
                .font(.bodyMedium)
                .foregroundStyle(.primary)
            Text("Privacy & Security")
                .font(.bodySmall)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: dragTileSize + Sp.sm)
        .padding(Sp.sm)
        .background(
            RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                .fill(isDropTargeted
                      ? Color.accentColor.opacity(0.10)
                      : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.06),
                    style: StrokeStyle(
                        lineWidth: isDropTargeted ? cardBorderSelected : cardBorderUnselected,
                        dash: isDropTargeted ? [] : [4, 4]
                    )
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            openSettingsForFirstUnresolved()
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            // The drop payload is a file URL; could be the Voice.app
            // bundle the user dragged from /Applications, or any other
            // file. Either way the intent is "take me to the right
            // System Settings pane", so we route to the first
            // unresolved permission. We never read the URL contents.
            Task { @MainActor in
                openSettingsForFirstUnresolved()
            }
            _ = item
        }
        return true
    }

    private func openSettingsForFirstUnresolved() {
        // Prefer the first required permission that is not granted.
        // Falling back to Input Monitoring (optional) keeps the drop
        // target useful even after the user has granted the two
        // required permissions, in case they want to enable the
        // optional one via the drag affordance.
        for kind in PermissionsService.Kind.allCases where service.status(for: kind) != .granted {
            service.openSettings(for: kind)
            return
        }
    }

    // MARK: Permission rows

    @ViewBuilder
    private var permissionRows: some View {
        VStack(alignment: .leading, spacing: Sp.md) {
            Text("Permissions")
                .font(.label)
                .tracking(0.8)
                .foregroundStyle(.secondary)

            VStack(spacing: Sp.md) {
                ForEach(PermissionsService.Kind.allCases) { kind in
                    PermissionRow(
                        kind: kind,
                        status: service.status(for: kind),
                        isActive: kind == firstUnresolvedKind,
                        onPrimaryAction: { performPrimaryAction(for: kind) },
                        onOpenSettings: { service.openSettings(for: kind) }
                    )
                }
            }
        }
    }

    /// The first row a user should attend to. We highlight it with the
    /// accent border so the eye lands on it after the hero. Optional
    /// rows are included so the highlight steps onto Input Monitoring
    /// after both required permissions are done, surfacing the upsell
    /// without making it a blocker.
    private var firstUnresolvedKind: PermissionsService.Kind? {
        PermissionsService.Kind.allCases.first { service.status(for: $0) != .granted }
    }

    private func performPrimaryAction(for kind: PermissionsService.Kind) {
        switch kind {
        case .accessibility:
            if service.accessibility == .notDetermined {
                service.requestAccessibility()
            } else {
                service.openSettings(for: kind)
            }
        case .microphone:
            if service.microphone == .notDetermined {
                Task { await service.requestMicrophone() }
            } else {
                service.openSettings(for: kind)
            }
        case .inputMonitoring:
            // No first-party prompt API. Always route to settings.
            service.openSettings(for: kind)
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        HStack {
            Button {
                service.refresh()
            } label: {
                HStack(spacing: Sp.xs) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Re-check permissions")
                        .font(.bodyMedium)
                }
                .padding(.horizontal, Sp.md)
                .padding(.vertical, Sp.sm)
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: cardBorderUnselected)
            )

            Spacer()

            if service.allGranted {
                HStack(spacing: Sp.xs) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.green)
                    Text("All set")
                        .font(.bodyMedium)
                        .foregroundStyle(.primary)
                }
            }
        }
    }
}

// MARK: - PermissionRow

private struct PermissionRow: View {
    let kind: PermissionsService.Kind
    let status: PermissionsService.Status
    let isActive: Bool
    let onPrimaryAction: () -> Void
    let onOpenSettings: () -> Void

    @Environment(\.colorScheme) private var scheme

    private let cardCorner: CGFloat = 14
    private let cardBorderUnselected: CGFloat = 1.0
    private let cardBorderSelected: CGFloat = 1.5

    var body: some View {
        HStack(alignment: .center, spacing: Sp.md) {
            iconBadge

            VStack(alignment: .leading, spacing: Sp.xxs) {
                HStack(spacing: Sp.sm) {
                    Text(kind.displayName)
                        .font(.serifSection)
                        .foregroundStyle(.primary)
                    if !kind.isRequired {
                        Text("Optional")
                            .font(.badge)
                            .tracking(0.8)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Sp.sm)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(Color.primary.opacity(0.06))
                            )
                    }
                }
                Text(kind.requirementCopy)
                    .font(.bodyBase)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Sp.md)

            statusIndicator

            actionButton
        }
        .padding(Sp.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                .fill(scheme == .dark
                      ? Color.white.opacity(0.04)
                      : Color.black.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                .strokeBorder(
                    isActive && status != .granted
                        ? Color.accentColor.opacity(0.55)
                        : Color.primary.opacity(0.06),
                    lineWidth: isActive && status != .granted ? cardBorderSelected : cardBorderUnselected
                )
        )
    }

    @ViewBuilder
    private var iconBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .frame(width: 44, height: 44)
            Image(systemName: kind.symbolName)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch status {
        case .granted:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.green)
                .accessibilityLabel("Granted")
        case .denied:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.red)
                .accessibilityLabel("Denied")
        case .notDetermined:
            Circle()
                .fill(Color.orange)
                .frame(width: 10, height: 10)
                .accessibilityLabel("Not requested yet")
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if status == .granted {
            EmptyView()
        } else {
            Button(action: onPrimaryAction) {
                Text(primaryButtonTitle)
                    .font(.bodyMedium)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Sp.md)
                    .padding(.vertical, Sp.sm)
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor)
            )
        }
    }

    private var primaryButtonTitle: String {
        switch (kind, status) {
        case (.microphone, .notDetermined): return "Allow"
        case (.accessibility, .notDetermined): return "Request"
        default: return "Open Settings"
        }
    }
}
