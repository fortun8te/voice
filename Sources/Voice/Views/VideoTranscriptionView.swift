// VOICE — Videos tab.
// ============================================================
// Paste a YouTube / video URL → it gets ingested, transcribed (captions or
// local ASR), and summarized. The grid shows one card per video with a live
// status badge. Tapping a card opens a summary-first detail view: TLDR hero,
// thesis, action items, topics, then the full transcript as a secondary
// collapsible section.
//
// Visual language is borrowed from the Dictations/Meetings tabs — Sp spacing
// tokens, CardShape corner radius, the bodyMedium/bodySmall type ramp, and
// `.glassEffect` surfaces. No new visual vocabulary is introduced.
// ============================================================

import SwiftUI

struct VideoTranscriptionView: View {
    @State private var coordinator = VideoTranscriptionCoordinator.shared
    private var store = TranscribedVideoStore.shared

    @State private var urlInput: String = ""
    @State private var selectedID: TranscribedVideo.ID?

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: Sp.md)]

    var body: some View {
        VStack(spacing: 0) {
            entryBar

            Divider()

            if store.videos.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: Sp.xl) {
                        ForEach(store.groupedByDay, id: \.day) { group in
                            VStack(alignment: .leading, spacing: Sp.sm) {
                                Text(dayLabel(group.day))
                                    .font(.bodySmall)
                                    .foregroundStyle(.tertiary)
                                    .textCase(.uppercase)
                                    .padding(.horizontal, Sp.xs)

                                LazyVGrid(columns: columns, spacing: Sp.md) {
                                    ForEach(group.videos) { video in
                                        VideoCard(video: video)
                                            .onTapGesture { selectedID = video.id }
                                    }
                                }
                            }
                        }
                    }
                    .padding(Sp.lg)
                }
            }
        }
        .sheet(item: selectedVideoBinding) { video in
            VideoDetailView(video: video) {
                store.remove(id: video.id)
                selectedID = nil
            }
        }
    }

    /// Bridges the selected id to the (current) video value so the sheet always
    /// renders fresh data as the store mutates.
    private var selectedVideoBinding: Binding<TranscribedVideo?> {
        Binding(
            get: { store.videos.first { $0.id == selectedID } },
            set: { newValue in selectedID = newValue?.id }
        )
    }

    // MARK: - Entry bar

    private var entryBar: some View {
        HStack(spacing: Sp.sm) {
            Image(systemName: "link")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.tertiary)

            TextField("Paste a YouTube or video link", text: $urlInput)
                .textFieldStyle(.plain)
                .font(.bodyBase)
                .onSubmit(submit)

            Button(action: submit) {
                Text("Transcribe")
                    .font(.bodyMedium)
                    .padding(.horizontal, Sp.md)
                    .padding(.vertical, Sp.xs)
            }
            .buttonStyle(.borderedProminent)
            .disabled(urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, Sp.lg)
        .padding(.vertical, Sp.md)
    }

    private func submit() {
        let url = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        urlInput = ""
        Task { await coordinator.transcribeVideo(urlString: url) }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: Sp.lg) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 24))
                .foregroundStyle(.quaternary)
            Text("No videos yet")
                .font(.bodyMedium)
                .foregroundStyle(.primary)
            Text("Paste a YouTube or video link above to transcribe and summarize it.")
                .font(.bodySmall)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Sp.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Grid card

private struct VideoCard: View {
    let video: TranscribedVideo

    var body: some View {
        VStack(alignment: .leading, spacing: Sp.sm) {
            VideoThumbnail(path: video.thumbnailLocalPath)
                .frame(height: 124)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: CardShape.corner, style: .continuous))

            VStack(alignment: .leading, spacing: Sp.xxs) {
                Text(video.title)
                    .font(.bodyMedium)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: Sp.xs) {
                    if let channel = video.channel, !channel.isEmpty {
                        Text(channel)
                            .font(.bodySmall)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let duration = video.durationSeconds {
                        Text(formatDuration(duration))
                            .font(.bodySmall)
                            .foregroundStyle(.tertiary)
                    }
                }

                StatusBadge(status: video.status, errorMessage: video.errorMessage)
                    .padding(.top, Sp.xxs)
            }
            .padding(.horizontal, Sp.xs)
            .padding(.bottom, Sp.xs)
        }
        .padding(Sp.sm)
        .background(
            RoundedRectangle(cornerRadius: CardShape.corner, style: .continuous)
                .fill(.quaternary.opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: CardShape.corner, style: .continuous)
                .strokeBorder(.quaternary.opacity(0.5), lineWidth: CardShape.borderUnselected)
        )
        .contentShape(RoundedRectangle(cornerRadius: CardShape.corner, style: .continuous))
    }
}

// MARK: - Thumbnail

private struct VideoThumbnail: View {
    let path: String?

    var body: some View {
        if let path, let nsImage = loadImage(path) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if let path, let url = URL(string: path), url.scheme?.hasPrefix("http") == true {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default:
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(.quaternary.opacity(0.5))
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
        }
    }

    private func loadImage(_ path: String) -> NSImage? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return NSImage(contentsOfFile: path)
    }
}

// MARK: - Status badge

private struct StatusBadge: View {
    let status: TranscribedVideo.Status
    let errorMessage: String?

    var body: some View {
        HStack(spacing: Sp.xs) {
            switch status {
            case .ingesting, .transcribing, .summarizing:
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                Text(label)
                    .font(.bodySmall)
                    .foregroundStyle(.secondary)
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
                Text("Done")
                    .font(.bodySmall)
                    .foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Text(errorMessage ?? "Failed")
                    .font(.bodySmall)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var label: String {
        switch status {
        case .ingesting:    return "Ingesting…"
        case .transcribing: return "Transcribing…"
        case .summarizing:  return "Summarizing…"
        case .done:         return "Done"
        case .failed:       return "Failed"
        }
    }
}

// MARK: - Detail view

private struct VideoDetailView: View {
    let video: TranscribedVideo
    let onDelete: () -> Void

    // Explicit init: the `private` @State/store properties below otherwise
    // lower the synthesized memberwise init to `private`, making this view
    // un-constructable from the parent. This internal init fixes that.
    init(video: TranscribedVideo, onDelete: @escaping () -> Void) {
        self.video = video
        self.onDelete = onDelete
    }

    @Environment(\.dismiss) private var dismiss
    @State private var transcriptExpanded = false

    @State private var coordinator = VideoTranscriptionCoordinator.shared
    private var store = TranscribedVideoStore.shared

    // Chat state.
    @State private var chatInput: String = ""
    @State private var chatSending = false

    /// True while this video is mid-pipeline (a redo / reprocess in flight, or
    /// the initial ingest still running). Drives the redo-button disabled state.
    private var isProcessing: Bool {
        switch video.status {
        case .ingesting, .transcribing, .summarizing: return true
        case .done, .failed: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: Sp.xl) {
                    // TLDR hero.
                    if let tldr = video.tldr, !tldr.isEmpty {
                        VStack(alignment: .leading, spacing: Sp.sm) {
                            Text("TLDR")
                                .font(.bodySmall)
                                .foregroundStyle(.tertiary)
                                .textCase(.uppercase)
                            Text(displayClean(tldr))
                                .font(.title3)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    redoControls

                    if let thesis = video.thesis, !thesis.isEmpty {
                        VStack(alignment: .leading, spacing: Sp.xs) {
                            Text("Thesis")
                                .font(.bodySmall)
                                .foregroundStyle(.tertiary)
                                .textCase(.uppercase)
                            Text(displayClean(thesis))
                                .font(.bodyMedium)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if !video.actionItems.isEmpty {
                        VStack(alignment: .leading, spacing: Sp.sm) {
                            Text("Action Items")
                                .font(.bodySmall)
                                .foregroundStyle(.tertiary)
                                .textCase(.uppercase)
                            ForEach(Array(video.actionItems.enumerated()), id: \.offset) { _, item in
                                HStack(alignment: .top, spacing: Sp.sm) {
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: 5))
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 7)
                                    Text(displayClean(item))
                                        .font(.bodyBase)
                                        .foregroundStyle(.primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }

                    if !video.topics.isEmpty {
                        VStack(alignment: .leading, spacing: Sp.sm) {
                            Text("Topics")
                                .font(.bodySmall)
                                .foregroundStyle(.tertiary)
                                .textCase(.uppercase)
                            FlowChips(items: video.topics.map(displayClean))
                        }
                    }

                    // Full transcript — secondary, collapsible.
                    if !video.transcript.isEmpty {
                        VStack(alignment: .leading, spacing: Sp.sm) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    transcriptExpanded.toggle()
                                }
                            } label: {
                                HStack(spacing: Sp.xs) {
                                    Image(systemName: transcriptExpanded ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 10, weight: .semibold))
                                    Text("Full transcript")
                                        .font(.bodySmall)
                                        .textCase(.uppercase)
                                }
                                .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)

                            if transcriptExpanded {
                                Text(video.transcript)
                                    .font(.bodySmall)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    chatPanel
                }
                .padding(Sp.xl)
            }
        }
        .frame(minWidth: 460, minHeight: 420)
    }

    // MARK: - Redo controls

    private var redoControls: some View {
        HStack(spacing: Sp.sm) {
            Button {
                Task { await coordinator.redoSummary(video) }
            } label: {
                Label("Redo summary", systemImage: "arrow.clockwise")
                    .font(.bodyMedium)
                    .padding(.horizontal, Sp.sm)
                    .padding(.vertical, Sp.xs)
            }
            .buttonStyle(.bordered)
            .disabled(isProcessing)

            Button {
                Task { await coordinator.reprocess(video) }
            } label: {
                Label("Redo all", systemImage: "arrow.triangle.2.circlepath")
                    .font(.bodyMedium)
                    .padding(.horizontal, Sp.sm)
                    .padding(.vertical, Sp.xs)
            }
            .buttonStyle(.bordered)
            .disabled(isProcessing)

            // In-flight feedback reuses the existing status badge vocabulary.
            if isProcessing {
                StatusBadge(status: video.status, errorMessage: video.errorMessage)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Chat panel

    private var chatPanel: some View {
        VStack(alignment: .leading, spacing: Sp.sm) {
            Text("Ask about this video")
                .font(.bodySmall)
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)

            if !video.chatMessages.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: Sp.sm) {
                            ForEach(video.chatMessages) { message in
                                ChatBubble(message: message)
                                    .id(message.id)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 140, maxHeight: 400)
                    .onChange(of: video.chatMessages.count) {
                        scrollToLatest(proxy)
                    }
                    .onChange(of: chatSending) {
                        // A reply landing flips chatSending false — keep the
                        // newest turn in view after a send completes.
                        scrollToLatest(proxy)
                    }
                    .onAppear { scrollToLatest(proxy, animated: false) }
                }
            }

            HStack(spacing: Sp.sm) {
                TextField("Ask a question about this video", text: $chatInput)
                    .textFieldStyle(.plain)
                    .font(.bodyBase)
                    .onSubmit(sendChat)
                    .disabled(chatSending)

                if chatSending {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                }

                Button(action: sendChat) {
                    Text("Send")
                        .font(.bodyMedium)
                        .padding(.horizontal, Sp.md)
                        .padding(.vertical, Sp.xs)
                }
                .buttonStyle(.borderedProminent)
                .disabled(chatSending || chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(Sp.sm)
            .background(
                RoundedRectangle(cornerRadius: CardShape.corner, style: .continuous)
                    .fill(.quaternary.opacity(0.4))
            )
            .overlay(
                RoundedRectangle(cornerRadius: CardShape.corner, style: .continuous)
                    .strokeBorder(.quaternary.opacity(0.5), lineWidth: CardShape.borderUnselected)
            )
        }
    }

    /// Scrolls the chat list to the newest message so the latest reply is
    /// always visible without manual scrolling.
    private func scrollToLatest(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard let lastID = video.chatMessages.last?.id else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(lastID, anchor: .bottom)
        }
    }

    /// Cleans em/en-dashes out of already-saved text at render time so legacy
    /// summaries/chats look right without a redo. Leaves regular hyphens alone.
    private func displayClean(_ s: String) -> String {
        var out = s
        // Collapse a dash with optional surrounding spaces into ", ".
        out = out.replacingOccurrences(
            of: "\\s*[\\u{2014}\\u{2013}]\\s*",
            with: ", ",
            options: .regularExpression
        )
        // Tidy any artifacts: doubled spaces and a space before a comma.
        out = out.replacingOccurrences(of: " ,", with: ",")
        out = out.replacingOccurrences(
            of: " {2,}",
            with: " ",
            options: .regularExpression
        )
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sendChat() {
        let question = chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !chatSending else { return }

        // Capture Date() here in the action closure (always valid context) and
        // snapshot the prior history before we append the new user turn.
        let now = Date()
        let history = video.chatMessages
        let videoID = video.id
        let videoSnapshot = video

        chatInput = ""
        chatSending = true

        let userMessage = VideoChatMessage(role: "user", content: question, ts: now)
        store.appendChatMessage(userMessage, toVideoID: videoID)

        Task {
            do {
                let reply = try await VideoChatService.shared.ask(
                    question: question,
                    video: videoSnapshot,
                    history: history
                )
                let assistantMessage = VideoChatMessage(role: "assistant", content: reply, ts: Date())
                store.appendChatMessage(assistantMessage, toVideoID: videoID)
            } catch {
                let errorMessage = VideoChatMessage(
                    role: "assistant",
                    content: "Couldn't answer that: \(error.localizedDescription)",
                    ts: Date()
                )
                store.appendChatMessage(errorMessage, toVideoID: videoID)
            }
            chatSending = false
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Sp.md) {
            VStack(alignment: .leading, spacing: Sp.xxs) {
                Text(video.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                if let channel = video.channel, !channel.isEmpty {
                    Text(channel)
                        .font(.bodySmall)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: Sp.sm)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Delete this video")

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(Sp.lg)
    }
}

// MARK: - Chat bubble

private struct ChatBubble: View {
    let message: VideoChatMessage

    private var isUser: Bool { message.role == "user" }

    /// Display-time em/en-dash cleanup so legacy saved chats render cleanly.
    /// Mirrors `displayClean` on the detail view (ChatBubble is a sibling type).
    private func displayClean(_ s: String) -> String {
        var out = s.replacingOccurrences(
            of: "\\s*[\\u{2014}\\u{2013}]\\s*",
            with: ", ",
            options: .regularExpression
        )
        out = out.replacingOccurrences(of: " ,", with: ",")
        out = out.replacingOccurrences(
            of: " {2,}",
            with: " ",
            options: .regularExpression
        )
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: Sp.xl) }

            Text(displayClean(message.content))
                .font(.bodyBase)
                .foregroundStyle(isUser ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.horizontal, Sp.sm)
                .padding(.vertical, Sp.xs)
                .background(
                    RoundedRectangle(cornerRadius: CardShape.corner, style: .continuous)
                        .fill(.quaternary.opacity(isUser ? 0.6 : 0.35))
                )
                .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
                .multilineTextAlignment(.leading)

            if !isUser { Spacer(minLength: Sp.xl) }
        }
    }
}

// MARK: - Topic chips (simple wrapping layout)

private struct FlowChips: View {
    let items: [String]

    var body: some View {
        FlowLayout(spacing: Sp.xs) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, topic in
                Text(topic)
                    .font(.bodySmall)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Sp.sm)
                    .padding(.vertical, Sp.xs)
                    .background(
                        Capsule().fill(.quaternary.opacity(0.5))
                    )
            }
        }
    }
}

/// Minimal wrapping layout for the topic chips (avoids depending on any
/// app-specific flow helper).
private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[CGSize]] = [[]]
        var x: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                totalHeight += rowHeight + spacing
                rows.append([])
                x = 0
                rowHeight = 0
            }
            rows[rows.count - 1].append(size)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Helpers

/// Relative day header for the grid sections — "Today" / "Yesterday" for the
/// two most recent days, otherwise a short "May 28" style label (drops the
/// year for the current year).
private func dayLabel(_ day: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(day) { return "Today" }
    if cal.isDateInYesterday(day) { return "Yesterday" }

    let formatter = DateFormatter()
    if cal.isDate(day, equalTo: Date(), toGranularity: .year) {
        formatter.dateFormat = "MMM d"
    } else {
        formatter.dateFormat = "MMM d, yyyy"
    }
    return formatter.string(from: day)
}

private func formatDuration(_ seconds: Double) -> String {
    let total = Int(seconds)
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 {
        return String(format: "%d:%02d:%02d", h, m, s)
    }
    return String(format: "%d:%02d", m, s)
}
