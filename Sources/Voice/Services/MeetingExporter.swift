// VOICE — MeetingExporter
// ============================================================
// Pure-formatting Markdown export for a Meeting. No LLM calls.
//
// Produces an Obsidian-friendly document with:
//   • YAML front-matter (title, ISO date, duration, source_app, participants,
//     language, model) — kept for Obsidian/Dataview consumers
//   • Polished readable header (title + Date / Duration / Source / Participants)
//   • TL;DR section pulled from the summary overview
//   • Decisions as a checked task list (`- [x]`)
//   • Action items as an unchecked task list (`- [ ]`) with `@assignee` and
//     `by <due>` inline
//   • Open questions as a plain bulleted "Questions" section
//   • Transcript section with **Speaker:** prefixes and paragraph breaks
//     between turns. Timestamps surface as a leading `[HH:MM:SS]` only when
//     the meeting is long enough to need wayfinding (> 20 segments).
//   • Italic footer line
//   • Audio file path as a trailing HTML comment
//
// Three entry points:
//   • renderMarkdown(_:)             — returns the rendered string
//   • exportToFile(_:storage:)       — NSSavePanel + write + persist path
//   • copyToClipboard(_:)            — copies the markdown to NSPasteboard
// ============================================================

import Foundation
import AppKit

@MainActor
final class MeetingExporter {

    // MARK: - Public API

    /// Build the markdown body for `meeting`. Pure function — no I/O.
    func renderMarkdown(_ meeting: Meeting) -> String {
        var out = ""

        let participantsList = resolveParticipants(meeting)
        let sourceAppLabel = Self.sourceAppLabel(meeting.sourceApp)

        // ---- YAML front-matter (kept for Obsidian / Dataview consumers) ----
        out += "---\n"
        out += "title: \(Self.escapeYAMLScalar(meeting.title))\n"
        out += "date: \(Self.iso8601.string(from: meeting.date))\n"
        out += "duration: \(Self.compactDuration(meeting.duration))\n"
        out += "source_app: \(Self.escapeYAMLScalar(sourceAppLabel ?? "unknown"))\n"
        if participantsList.isEmpty {
            out += "participants: []\n"
        } else {
            out += "participants:\n"
            for p in participantsList {
                out += "  - \(Self.escapeYAMLScalar(p))\n"
            }
        }
        out += "language: en\n"
        out += "model: \(Self.escapeYAMLScalar(Self.modelName(for: meeting)))\n"
        out += "---\n\n"

        // ---- Title + readable metadata block ----
        out += "# \(meeting.title)\n\n"

        // Markdown line breaks are produced by two trailing spaces. We collect
        // metadata lines first, then join — keeps the formatting predictable
        // even when individual fields are missing.
        var metaLines: [String] = []
        metaLines.append("**Date:** \(Self.formatHumanDate(meeting.date))")
        metaLines.append("**Duration:** \(Self.humanDuration(meeting.duration))")
        if let src = sourceAppLabel {
            metaLines.append("**Source:** \(src)")
        }
        if !participantsList.isEmpty {
            metaLines.append("**Participants:** \(participantsList.joined(separator: ", "))")
        }
        out += metaLines.joined(separator: "  \n") + "\n\n"

        // ---- Table of contents (only when transcript is long) ----
        let needsTOC = meeting.segments.count > 20
        if needsTOC {
            out += "## Table of Contents\n\n"
            if let s = meeting.summary, !Self.cleanText(s.overview).isEmpty {
                out += "- [TL;DR](#tldr)\n"
            }
            if let s = meeting.summary {
                if !s.keyDecisions.isEmpty { out += "- [Decisions](#decisions)\n" }
                if !s.actionItems.isEmpty { out += "- [Action items](#action-items)\n" }
                if !s.openQuestions.isEmpty { out += "- [Questions](#questions)\n" }
            }
            out += "- [Transcript](#transcript)\n\n"
        }

        // ---- TL;DR (overview pulled from summary) ----
        if let s = meeting.summary {
            let overview = Self.cleanText(s.overview)
            if !overview.isEmpty {
                out += "## TL;DR\n\n"
                out += "\(overview)\n\n"
            }
        }

        // ---- Decisions ----
        if let s = meeting.summary, !s.keyDecisions.isEmpty {
            out += "## Decisions\n\n"
            for d in s.keyDecisions {
                let cleaned = Self.cleanText(d)
                if !cleaned.isEmpty {
                    out += "- [x] \(cleaned)\n"
                }
            }
            out += "\n"
        }

        // ---- Action items ----
        if let s = meeting.summary, !s.actionItems.isEmpty {
            out += "## Action items\n\n"
            for a in s.actionItems {
                let box = a.isCompleted ? "[x]" : "[ ]"
                var line = "- \(box) \(Self.cleanText(a.text))"
                var suffix: [String] = []
                if let who = a.assignee?.trimmingCharacters(in: .whitespacesAndNewlines), !who.isEmpty {
                    // Strip a leading @ if the LLM already added one.
                    let handle = who.hasPrefix("@") ? String(who.dropFirst()) : who
                    suffix.append("@\(handle)")
                }
                if let due = a.dueDate?.trimmingCharacters(in: .whitespacesAndNewlines), !due.isEmpty {
                    suffix.append("by \(due)")
                }
                if !suffix.isEmpty {
                    line += " — " + suffix.joined(separator: " ")
                }
                out += line + "\n"
            }
            out += "\n"
        }

        // ---- Open questions ----
        if let s = meeting.summary, !s.openQuestions.isEmpty {
            out += "## Questions\n\n"
            for q in s.openQuestions {
                let cleaned = Self.cleanText(q)
                if !cleaned.isEmpty {
                    out += "- \(cleaned)\n"
                }
            }
            out += "\n"
        }

        // ---- Transcript ----
        out += "## Transcript\n\n"
        let segs = meeting.segments
        if segs.isEmpty {
            out += "_Transcript not yet generated — run Transcribe to populate._\n\n"
        } else {
            out += Self.renderTranscript(segs, withTimestamps: needsTOC)
        }

        // ---- Footer ----
        out += "---\n\n"
        out += "*Recorded with Voice.*\n"

        // ---- Audio file path as trailing HTML comment ----
        if let audio = meeting.audioFilePath, !audio.isEmpty {
            out += "\n<!-- audio: \(audio) -->\n"
        }

        return out
    }

    /// Show an NSSavePanel, write the markdown, and persist the chosen path
    /// onto the Meeting record. Returns the final URL on success.
    func exportToFile(_ meeting: Meeting, storage: StorageService) async -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export Meeting"
        panel.message = "Save the meeting transcript as Markdown."
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = Self.sanitizedFilename(meeting.title) + ".md"

        let response = await panel.beginSheet()
        guard response == .OK, let url = panel.url else { return nil }

        let body = renderMarkdown(meeting)
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSLog("[MeetingExporter] Failed to write \(url.path): \(error)")
            return nil
        }

        var updated = meeting
        updated.markdownExportPath = url.path
        do {
            try storage.saveMeeting(updated)
        } catch {
            NSLog("[MeetingExporter] Failed to persist markdownExportPath: \(error)")
        }
        return url
    }

    /// Copy the rendered markdown to the system pasteboard.
    func copyToClipboard(_ meeting: Meeting) {
        let body = renderMarkdown(meeting)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(body, forType: .string)
    }

    // MARK: - Transcript rendering

    /// Render the transcript as bold-prefixed turns with blank-line separators
    /// between speakers. Consecutive segments from the same speaker fold into
    /// a single paragraph (with soft breaks via two trailing spaces). When
    /// `withTimestamps` is true, the first line of each turn carries a leading
    /// `[HH:MM:SS]` stamp for long-meeting wayfinding.
    private static func renderTranscript(_ segs: [TranscriptSegment], withTimestamps: Bool) -> String {
        var out = ""
        var i = 0
        while i < segs.count {
            let turnSpeaker = segs[i].speaker
            var j = i
            var lines: [String] = []
            while j < segs.count && segs[j].speaker == turnSpeaker {
                let cleaned = cleanText(segs[j].text)
                if !cleaned.isEmpty {
                    if j == i {
                        let stamp = withTimestamps ? "[\(formatStamp(segs[j].startTime))] " : ""
                        if isAnonymousSpeaker(turnSpeaker) {
                            lines.append("\(stamp)\(cleaned)")
                        } else {
                            lines.append("**\(turnSpeaker):** \(stamp)\(cleaned)")
                        }
                    } else {
                        lines.append(cleaned)
                    }
                }
                j += 1
            }
            if !lines.isEmpty {
                out += lines.joined(separator: "  \n")
                out += "\n\n"
            }
            i = j
        }
        return out
    }

    // MARK: - Formatting helpers

    /// Always `[HH:MM:SS]` (zero-padded).
    static func formatStamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    /// Collapses runs of whitespace and trims.
    static func cleanText(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let collapsed = trimmed
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed
    }

    /// "MEETING" and empty-name segments render anonymously (no `Name:`).
    static func isAnonymousSpeaker(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if trimmed.uppercased() == "MEETING" { return true }
        return false
    }

    /// Sanitize the user-facing title into a filesystem-safe filename.
    static func sanitizedFilename(_ title: String) -> String {
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { t = "Untitled Meeting" }
        let banned: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|", "\0"]
        t = String(t.map { banned.contains($0) ? "-" : $0 })
        t = t.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        while t.hasPrefix(".") { t.removeFirst() }
        if t.count > 120 {
            t = String(t.prefix(120)).trimmingCharacters(in: .whitespaces)
        }
        if t.isEmpty { t = "Untitled Meeting" }
        return t
    }

    /// Participants for the header: prefer the v5 DOM-scraped list, fall back
    /// to distinct non-anonymous speaker names from the transcript.
    private func resolveParticipants(_ meeting: Meeting) -> [String] {
        let scraped = meeting.participantNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !scraped.isEmpty { return uniqued(scraped) }
        return collectSpeakerNames(meeting.segments)
    }

    /// Distinct, non-anonymous speaker names in first-seen order.
    private func collectSpeakerNames(_ segments: [TranscriptSegment]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for seg in segments {
            let name = seg.speaker.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.isAnonymousSpeaker(name) { continue }
            if seen.insert(name).inserted {
                ordered.append(name)
            }
        }
        return ordered
    }

    /// Order-preserving dedupe.
    private func uniqued(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for s in items where seen.insert(s).inserted {
            out.append(s)
        }
        return out
    }

    /// Compact "1h 23m" / "23m 04s" / "42s" duration for YAML front-matter.
    static func compactDuration(_ t: TimeInterval) -> String {
        let total = max(0, Int(t.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return "\(h)h \(m)m"
        } else if m > 0 {
            return String(format: "%dm %02ds", m, s)
        } else {
            return "\(s)s"
        }
    }

    /// Human-friendly duration for the header ("23 min", "1 hr 23 min", "42 sec").
    /// Differs from `compactDuration` (which targets YAML / file names) by
    /// reading as natural prose.
    static func humanDuration(_ t: TimeInterval) -> String {
        let total = max(0, Int(t.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return m > 0 ? "\(h) hr \(m) min" : "\(h) hr"
        }
        if m > 0 { return "\(m) min" }
        return "\(s) sec"
    }

    /// "Monday, May 26, 2026 · 2:34 PM" — locale-aware human date for the
    /// header block. Uses the user's current locale for weekday/month names
    /// and AM/PM, but always uses a middle dot separator.
    static func formatHumanDate(_ date: Date) -> String {
        let day = humanDateFormatter.string(from: date)
        let time = humanTimeFormatter.string(from: date)
        return "\(day) · \(time)"
    }

    /// Bundle ID → display name. Returns nil when the ID is unknown / missing
    /// so the header can hide the slot rather than say "unknown".
    static func sourceAppLabel(_ bundleID: String?) -> String? {
        guard let id = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else { return nil }
        let names: [String: String] = [
            "com.google.meet": "Google Meet",
            "us.zoom.xos": "Zoom",
            "com.hnc.Discord": "Discord",
            "ru.keepcoder.Telegram": "Telegram",
            "com.tinyspeck.slackmacgap": "Slack",
            "com.apple.FaceTime": "FaceTime",
            "com.cisco.webex.meetings": "Webex",
            "net.whatsapp.WhatsApp": "WhatsApp",
            "com.microsoft.teams2": "Teams",
            "com.skype.skype": "Skype",
            "com.apple.iChat": "Messages",
        ]
        return names[id]
    }

    /// Best-effort YAML scalar escape — quotes when the value contains
    /// characters that would confuse a YAML parser. Quoted values use
    /// double-quote escaping for embedded quotes and backslashes.
    static func escapeYAMLScalar(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "\"\"" }
        let needsQuotes = trimmed.contains(":") || trimmed.contains("#") ||
                          trimmed.contains("\"") || trimmed.contains("'") ||
                          trimmed.contains("[") || trimmed.contains("]") ||
                          trimmed.contains("{") || trimmed.contains("}") ||
                          trimmed.contains(",") || trimmed.contains("&") ||
                          trimmed.contains("*") || trimmed.contains("!") ||
                          trimmed.contains("|") || trimmed.contains(">") ||
                          trimmed.contains("%") || trimmed.contains("@") ||
                          trimmed.contains("`") || trimmed.hasPrefix("-") ||
                          trimmed.hasPrefix("?")
        if needsQuotes {
            let escaped = trimmed
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return trimmed
    }

    /// Model name pulled from a meeting if available; `MeetingSummary` does
    /// not currently expose a model field, so this falls back to "unknown".
    static func modelName(for meeting: Meeting) -> String {
        // Reserved for future MeetingSummary.model metadata.
        return "unknown"
    }

    // MARK: - Static formatters

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let humanDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d, yyyy"
        return f
    }()

    private static let humanTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()
}

// MARK: - NSSavePanel async bridge

private extension NSSavePanel {
    func beginSheet() async -> NSApplication.ModalResponse {
        await withCheckedContinuation { (cont: CheckedContinuation<NSApplication.ModalResponse, Never>) in
            if let host = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
                self.beginSheetModal(for: host) { resp in
                    cont.resume(returning: resp)
                }
            } else {
                let resp = self.runModal()
                cont.resume(returning: resp)
            }
        }
    }
}
