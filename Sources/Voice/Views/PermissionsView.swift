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
        VStack(alignment: .leading, spacing: Sp.md) {
            HStack(alignment: .center, spacing: Sp.lg) {
                appIcon
                    .frame(width: appIconSize, height: appIconSize)

                VStack(alignment: .leading, spacing: Sp.xs) {
                    Text(heroTitle)
                        .font(.serifTitle)
                        .foregroundStyle(.primary)
                    Text(heroSubtitle)
                        .font(.bodyLarge)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            // Stale-grant banner: shown only when a permission was previously
            // granted but currently isn't. Means the macOS TCC binding was
            // invalidated (typical after an unsigned-app rebuild). Plain
            // language: "permissions reset, re-grant once".
            if service.anyPermissionNeedsReGrant {
                staleGrantBanner
            }

            progressStrip
        }
    }

    private var heroTitle: String {
        if service.allGranted { return "You're all set" }
        if service.anyPermissionNeedsReGrant { return "Re-grant after update" }
        return "Set up VOICE"
    }

    private var heroSubtitle: String {
        if service.allGranted { return "Hit your hotkey and start dictating." }
        if service.anyPermissionNeedsReGrant {
            return "macOS reset VOICE's permissions after an app update. Drag VOICE back into each list below."
        }
        return "Grant a few permissions so VOICE can listen and paste."
    }

    @ViewBuilder
    private var staleGrantBanner: some View {
        HStack(alignment: .top, spacing: Sp.sm) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("Permissions reset after update")
                    .font(.bodyMedium)
                    .foregroundStyle(.primary)
                Text("If VOICE is already in the System Settings list, remove it (click −) then drag the icon back in.")
                    .font(.bodySmall)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(Sp.md)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var progressStrip: some View {
        let required = PermissionsService.Kind.allCases.filter { $0.isRequired }
        let granted = required.filter { service.status(for: $0) == .granted }.count
        let total = required.count

        HStack(spacing: Sp.sm) {
            HStack(spacing: 4) {
                ForEach(0..<total, id: \.self) { i in
                    Capsule()
                        .fill(i < granted ? Color.accentColor : Color.primary.opacity(0.10))
                        .frame(width: 32, height: 4)
                        .animation(.easeOut(duration: 0.25), value: granted)
                }
            }
            Text("\(granted) of \(total) granted")
                .font(.bodySmall)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
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
        VStack(alignment: .leading, spacing: Sp.md) {
            HStack(spacing: Sp.xs) {
                Image(systemName: "hand.draw.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("FAST SETUP")
                    .font(.label)
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
            }
            Text("Drag VOICE into the System Settings list")
                .font(.serifSection)
                .foregroundStyle(.primary)
            Text("Open Privacy & Security → Accessibility (or Input Monitoring), then drop the icon below into the list. Faster than tapping the + button.")
                .font(.bodyBase)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Sp.lg) {
                voiceDragSourceTile
                AnimatedArrow()
                    .frame(width: 32, height: 22)
                    .foregroundStyle(.secondary)
                systemSettingsDropTile
            }
            .frame(maxWidth: .infinity)
            .padding(.top, Sp.xs)
        }
        .padding(Sp.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                .fill(Color.accentColor.opacity(service.allGranted ? 0.03 : 0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                .strokeBorder(
                    service.allGranted ? Color.primary.opacity(0.06) : Color.accentColor.opacity(0.35),
                    lineWidth: cardBorderUnselected
                )
        )
        .animation(.easeOut(duration: 0.25), value: service.allGranted)
    }

    @ViewBuilder
    private var voiceDragSourceTile: some View {
        // The bundle URL of Voice.app — what gets dragged out when the
        // user picks up this tile. Dropping it onto System Settings'
        // Accessibility / Input Monitoring lists is the modern macOS
        // shortcut for adding an app.
        let appURL = Bundle.main.bundleURL
        let needsAttention = !service.allGranted

        VStack(spacing: Sp.sm) {
            appIcon
                .frame(width: dragTileSize - Sp.xl, height: dragTileSize - Sp.xl)
            HStack(spacing: 4) {
                Image(systemName: "hand.draw.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(needsAttention ? Color.accentColor : .secondary)
                Text("Drag")
                    .font(.bodySmall)
                    .foregroundStyle(needsAttention ? Color.accentColor : .secondary)
            }
        }
        .frame(width: dragTileSize + Sp.xl, height: dragTileSize + Sp.sm)
        .padding(Sp.sm)
        .background(
            RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                .strokeBorder(
                    needsAttention ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.06),
                    lineWidth: needsAttention ? cardBorderSelected : cardBorderUnselected
                )
        )
        // SwiftUI's .draggable hands a transferable to the OS drag session.
        .draggable(appURL) {
            appIcon
                .frame(width: 48, height: 48)
        }
        .help("Drag into the System Settings accessibility list")
    }

    // MARK: - Animated arrow

    /// Right-pointing arrow that subtly drifts on the X axis to suggest
    /// "drag this way". Pure visual — no other state.
    private struct AnimatedArrow: View {
        var body: some View {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate
                let t = phase.truncatingRemainder(dividingBy: 1.4) / 1.4
                let s = sin(t * 2 * .pi)
                let offset = s * 3       // ±3pt drift
                let opacity = 0.55 + 0.30 * (0.5 + 0.5 * s)
                Image(systemName: "arrow.right")
                    .font(.system(size: 18, weight: .semibold))
                    .offset(x: offset)
                    .opacity(opacity)
            }
        }
    }

    @ViewBuilder
    private var systemSettingsDropTile: some View {
        // No more in-app drop target — the drag is meant to land on the REAL
        // System Settings list. This tile is just a tap-target that opens
        // System Settings to the right pane so the user can see the list
        // they need to drop the icon into.
        Button(action: openSettingsForFirstUnresolved) {
            VStack(spacing: Sp.sm) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("System Settings")
                    .font(.bodyMedium)
                    .foregroundStyle(.primary)
                Text("Tap to open the right pane")
                    .font(.bodySmall)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .frame(height: dragTileSize + Sp.sm)
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
        .buttonStyle(.plain)
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
        VStack(alignment: .leading, spacing: Sp.sm) {
            // Troubleshooting affordance: shown only when at least one
            // required permission is missing. Catches the "stale TCC after
            // app rebuild" case — Settings shows VOICE in the list but
            // the API still returns false. Removing and re-adding fixes it.
            if !service.allGranted {
                HStack(alignment: .top, spacing: Sp.xs) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 1)
                    Text("If VOICE is already in the System Settings list but a permission still shows red, remove the entry (click the −) and drag VOICE back in.")
                        .font(.bodySmall)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, Sp.xs)
            }

            footerButtons
        }
    }

    @ViewBuilder
    private var footerButtons: some View {
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
