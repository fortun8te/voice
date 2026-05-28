import SwiftUI

/// Toggle for the Meetings tab — list (default) or month-grid calendar.
/// Declared here so MeetingCalendarView and BigMenuWindow share the type.
enum MeetingsViewMode: String, CaseIterable, Identifiable {
    case list
    case calendar
    var id: String { rawValue }
    var label: String {
        switch self {
        case .list:     return "List"
        case .calendar: return "Calendar"
        }
    }
}

/// Month-grid view of meetings. 7-column weekday grid (Mon → Sun), dot
/// indicators per meeting, selected-day popover lists titles, and clicking a
/// title fires `onSelectMeeting` so the host can scroll the list to it.
///
/// Visual polish layered on the original implementation:
///   - Today cell: subtle accent tint + ring (not a heavy fill)
///   - Selected day: filled accent background, animates with matched geometry
///   - Out-of-month: 30% opacity
///   - Header: serif title centered, glass chevrons, "Today" pill when off
///     the current month
///   - Month transitions slide horizontally based on direction
///   - Container uses .glassEffect with containerCorner
struct MeetingCalendarView: View {
    let meetings: [Meeting]
    let onSelectMeeting: (UUID) -> Void

    @State private var anchorDate: Date = Date()
    @State private var popoverDay: Date? = nil
    /// +1 when navigating forward, -1 backward, 0 on initial appear. Drives
    /// the direction of the month-grid slide transition.
    @State private var slideDirection: Int = 0

    /// Shared namespace for the selected-day highlight so it morphs between
    /// cells inside the same month instead of cross-fading.
    @Namespace private var selectionNS

    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2 // Monday — week runs Mon → Sun
        return c
    }()

    /// Mirror of `BigMenuWindow.containerCorner` (which is `private` to that
    /// file). Kept identical so the calendar reads as part of the same
    /// rounded-rectangle family as stat / cleanup / personality cards.
    private let containerCorner: CGFloat = 14

    // MARK: - Computed

    private var monthLabel: String {
        let f = DateFormatter()
        f.dateFormat = "LLLL yyyy"
        return f.string(from: anchorDate)
    }

    /// True when `anchorDate` is in the same month as today. Drives whether
    /// the "Today" pill is shown in the header.
    private var viewingCurrentMonth: Bool {
        calendar.isDate(anchorDate, equalTo: Date(), toGranularity: .month)
    }

    /// All cells (6 weeks * 7 = 42) for the displayed month, including
    /// faded leading days from prev month and trailing days from next month.
    private var monthCells: [DayCell] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: anchorDate),
              let firstWeekday = calendar.dateComponents([.weekday], from: monthInterval.start).weekday
        else { return [] }

        let leading = firstWeekday - calendar.firstWeekday
        let normalizedLeading = (leading + 7) % 7

        let startDay = calendar.date(byAdding: .day, value: -normalizedLeading, to: monthInterval.start) ?? monthInterval.start

        var cells: [DayCell] = []
        for i in 0..<42 {
            guard let day = calendar.date(byAdding: .day, value: i, to: startDay) else { continue }
            let inMonth = calendar.isDate(day, equalTo: anchorDate, toGranularity: .month)
            let dayMeetings = meetingsOn(day)
            cells.append(DayCell(date: day, inMonth: inMonth, meetings: dayMeetings))
        }
        return cells
    }

    /// Stable key for the grid so SwiftUI swaps it (and runs the transition)
    /// when the visible month changes.
    private var monthKey: Date {
        calendar.dateInterval(of: .month, for: anchorDate)?.start ?? anchorDate
    }

    private func meetingsOn(_ day: Date) -> [Meeting] {
        meetings.filter { calendar.isDate($0.date, inSameDayAs: day) }
            .sorted { $0.date < $1.date }
    }

    // MARK: - View

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, Sp.lg)
                .padding(.vertical, Sp.md)

            weekdayHeader
                .padding(.horizontal, Sp.lg)

            // Grid swapped on month change so the slide transition runs.
            // ClipShape contains the slide inside the calendar bounds so the
            // outgoing month doesn't bleed into surrounding chrome.
            grid
                .padding(.horizontal, Sp.lg)
                .padding(.bottom, Sp.lg)
                .id(monthKey)
                .transition(monthTransition)
        }
        .clipShape(RoundedRectangle(cornerRadius: containerCorner, style: .continuous))
        .glassEffect(
            .regular,
            in: RoundedRectangle(cornerRadius: containerCorner, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: containerCorner, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Sp.sm) {
            chevronButton(systemName: "chevron.left") { shiftMonth(-1) }

            Spacer(minLength: 0)

            // Title + optional "Today" pill, centered. The pill sits to the
            // right of the title so the title itself stays visually centered.
            HStack(spacing: Sp.sm) {
                Text(monthLabel)
                    .font(.serifSection)
                    .foregroundStyle(.primary)
                    // contentTransition gives the digits/month name a soft
                    // morph as the title swaps with each month change.
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.18), value: monthKey)

                if !viewingCurrentMonth {
                    todayPill
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .animation(.easeOut(duration: 0.2), value: viewingCurrentMonth)

            Spacer(minLength: 0)

            chevronButton(systemName: "chevron.right") { shiftMonth(1) }
        }
    }

    /// Glass chevron button in a Circle. Uses the interactive variant so the
    /// surface deforms under the cursor and gives a press squish for free.
    private func chevronButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
    }

    /// "Today" pill — jumps the calendar back to the current month. Only
    /// shown when we're not already there.
    private var todayPill: some View {
        Button {
            jumpToToday()
        } label: {
            Text("Today")
                .font(.bodySmall.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, Sp.sm)
                .padding(.vertical, 4)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.tint(Color.accentColor.opacity(0.12)).interactive(),
            in: Capsule()
        )
        .help("Jump to the current month")
    }

    // MARK: Weekday header

    private var weekdayHeader: some View {
        // Matches `firstWeekday = 2` (Monday). Row reads Mon → Sun.
        let symbols = ["M", "T", "W", "T", "F", "S", "S"]
        return HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { i in
                Text(symbols[i])
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Sp.xs)
            }
        }
    }

    // MARK: Grid

    private var grid: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
        return LazyVGrid(columns: cols, spacing: 2) {
            ForEach(monthCells) { cell in
                dayCellView(cell)
            }
        }
    }

    /// Asymmetric slide based on `slideDirection`. Going forward, the new
    /// month enters from the right and the old one leaves to the left.
    private var monthTransition: AnyTransition {
        let dx: CGFloat = slideDirection >= 0 ? 24 : -24
        return .asymmetric(
            insertion: .offset(x: dx).combined(with: .opacity),
            removal: .offset(x: -dx).combined(with: .opacity)
        )
    }

    // MARK: Day cell

    private func dayCellView(_ cell: DayCell) -> some View {
        let isToday = calendar.isDateInToday(cell.date)
        let hasMeetings = !cell.meetings.isEmpty
        let isSelected = popoverDay.map { calendar.isDate($0, inSameDayAs: cell.date) } ?? false
        let dayNumber = calendar.component(.day, from: cell.date)

        // Foreground color hierarchy:
        //   - selected: solid accent (on the accent fill)
        //   - today (not selected): accent color
        //   - in-month: primary
        //   - out-of-month: secondary @ 30% (per spec)
        let dayColor: Color = {
            if isSelected { return Color.white }
            if isToday { return Color.accentColor }
            if cell.inMonth { return Color.primary }
            return Color.secondary.opacity(0.30)
        }()

        return VStack(spacing: 4) {
            // Day number sits inside a ZStack so the today-ring can hug it
            // without affecting layout.
            ZStack {
                if isToday && !isSelected {
                    Circle()
                        .fill(Color.accentColor.opacity(0.10))
                        .frame(width: 24, height: 24)
                    Circle()
                        .stroke(Color.accentColor.opacity(0.55), lineWidth: 1)
                        .frame(width: 24, height: 24)
                }
                Text("\(dayNumber)")
                    .font(.system(size: 12, weight: isToday || isSelected ? .semibold : .regular))
                    .foregroundStyle(dayColor)
            }
            .frame(height: 24)

            // Up to 3 dots, then "+N". Dot color shifts to white-ish when the
            // day is selected so it sits on the accent fill cleanly.
            HStack(spacing: 3) {
                let shown = min(cell.meetings.count, 3)
                ForEach(0..<shown, id: \.self) { _ in
                    Circle()
                        .fill(dotColor(selected: isSelected, inMonth: cell.inMonth))
                        .frame(width: 4, height: 4)
                }
                if cell.meetings.count > 3 {
                    Text("+\(cell.meetings.count - 3)")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : .secondary)
                }
            }
            .frame(height: 6)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 54)
        .background(selectionBackground(isSelected: isSelected, cell: cell))
        .contentShape(Rectangle())
        .onTapGesture {
            // Tap any day with meetings to open the popover. No-op for empty
            // days so we don't put up an empty bubble.
            if hasMeetings {
                withAnimation(.easeOut(duration: 0.18)) {
                    popoverDay = cell.date
                }
            }
        }
        .popover(isPresented: Binding(
            get: { isSelected },
            set: { if !$0 { popoverDay = nil } }
        ), arrowEdge: .bottom) {
            popoverContent(for: cell)
        }
    }

    private func dotColor(selected: Bool, inMonth: Bool) -> Color {
        if selected { return Color.white.opacity(0.95) }
        if !inMonth { return Color.secondary.opacity(0.35) }
        return Color.accentColor.opacity(0.85)
    }

    /// Selection background uses `matchedGeometryEffect` so the accent fill
    /// glides between the previously-selected cell and the new one within
    /// the same month.
    @ViewBuilder
    private func selectionBackground(isSelected: Bool, cell: DayCell) -> some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor)
                .matchedGeometryEffect(id: "selection", in: selectionNS)
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.clear)
        }
    }

    // MARK: Popover

    private func popoverContent(for cell: DayCell) -> some View {
        let dayLabel: String = {
            let f = DateFormatter()
            f.dateFormat = "EEEE, MMM d"
            return f.string(from: cell.date)
        }()

        return VStack(alignment: .leading, spacing: Sp.sm) {
            Text(dayLabel)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.4)

            Divider().opacity(0.4)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(cell.meetings) { m in
                    miniRow(meeting: m)
                }
            }
        }
        .padding(Sp.md)
        .frame(minWidth: 260, maxWidth: 340)
    }

    /// Single meeting row inside the day popover. Tapping it dismisses the
    /// popover and fires `onSelectMeeting` so the host can scroll the main
    /// list to the chosen meeting.
    private func miniRow(meeting m: Meeting) -> some View {
        Button {
            popoverDay = nil
            onSelectMeeting(m.id)
        } label: {
            HStack(alignment: .center, spacing: Sp.sm) {
                // Time column — fixed width so titles align across rows.
                Text(timeLabel(m.date))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .leading)

                Text(m.title.isEmpty ? "Untitled Meeting" : m.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: Sp.sm)

                Text(durationLabel(m.duration))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: Helpers

    private func timeLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: d)
    }

    /// Compact duration label: "12m", "1h 04m", "—" if zero. Kept short so
    /// the popover row stays tight even on small windows.
    private func durationLabel(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "—" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 {
            return String(format: "%dh %02dm", h, m)
        }
        if m > 0 {
            return "\(m)m"
        }
        return "\(total)s"
    }

    private func shiftMonth(_ delta: Int) {
        guard let new = calendar.date(byAdding: .month, value: delta, to: anchorDate) else { return }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            slideDirection = delta
            anchorDate = new
            popoverDay = nil
        }
    }

    private func jumpToToday() {
        let today = Date()
        // Direction: if today is later than current anchor, slide forward.
        let delta = calendar.compare(today, to: anchorDate, toGranularity: .month)
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            slideDirection = delta == .orderedDescending ? 1 : (delta == .orderedAscending ? -1 : 0)
            anchorDate = today
            popoverDay = nil
        }
    }
}

private struct DayCell: Identifiable {
    let date: Date
    let inMonth: Bool
    let meetings: [Meeting]
    var id: TimeInterval { date.timeIntervalSince1970 }
}
