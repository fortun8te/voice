// VOICE — Data Models
// ============================================================
// Core data types used throughout the app. These map directly to
// the GRDB database schema and the UI display.
//
// Schema versioning:
//   v1 — initial fields (id, speaker, text, startTime, endTime, confidence)
//   v2 — TranscriptSegment adds: speakerId, isFinal
//   v3 — Meeting adds: kind, markdownExportPath, tagsJson, pinnedNote
//        (audioFilePath was already present from v1)
//
// All new fields have safe defaults so older rows decode without error.
// ============================================================

import Foundation

// MARK: - MeetingKind
// Distinguishes a quick dictation (single-speaker, often short) from a
// recorded meeting (multi-speaker, summarized).

public enum MeetingKind: String, Codable, CaseIterable, Sendable {
    case dictation
    case meeting
}

// MARK: - TranscriptSegment
// A single chunk of transcribed speech from one speaker.

struct TranscriptSegment: Identifiable, Codable, Sendable {
    let id: UUID
    var speaker: String           // "Speaker 1" or actual name if identified
    var speakerId: String?        // v2: stable ID from diarizer (e.g. "spk_0"); nil if unknown
    var text: String              // The transcribed text
    var startTime: TimeInterval   // Seconds from recording start
    var endTime: TimeInterval
    var confidence: Float?        // 0.0-1.0, nil if not available
    var isFinal: Bool             // v2: false for streaming partials, true once committed
    /// v4: Tokens flagged as low-confidence by the ASR (per-token confidence < 0.6).
    /// Surfaced to the LLM polisher so it can double-check spelling/word choice.
    /// Not persisted to the DB — purely a transient hint between transcription
    /// and polish on the same dictation. Omitted from CodingKeys.
    var suspectWords: [String]?

    init(
        id: UUID = UUID(),
        speaker: String = "Speaker 1",
        speakerId: String? = nil,
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        confidence: Float? = nil,
        isFinal: Bool = true,
        suspectWords: [String]? = nil
    ) {
        self.id = id
        self.speaker = speaker
        self.speakerId = speakerId
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
        self.isFinal = isFinal
        self.suspectWords = suspectWords
    }

    // Format for display — change to "[HH:MM:SS]" for long meetings
    var formattedTimestamp: String {
        let mins = Int(startTime) / 60
        let secs = Int(startTime) % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    // Custom decoder so older rows without v2 columns decode successfully.
    enum CodingKeys: String, CodingKey {
        case id, speaker, speakerId, text, startTime, endTime, confidence, isFinal
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.speaker = try c.decode(String.self, forKey: .speaker)
        self.speakerId = try c.decodeIfPresent(String.self, forKey: .speakerId)
        self.text = try c.decode(String.self, forKey: .text)
        self.startTime = try c.decode(TimeInterval.self, forKey: .startTime)
        self.endTime = try c.decode(TimeInterval.self, forKey: .endTime)
        self.confidence = try c.decodeIfPresent(Float.self, forKey: .confidence)
        self.isFinal = try c.decodeIfPresent(Bool.self, forKey: .isFinal) ?? true
    }
}

// MARK: - Meeting
// A complete recorded meeting with metadata.

struct Meeting: Identifiable, Codable, Sendable {
    let id: UUID
    var title: String                  // Auto-generated from calendar or first sentence
    var date: Date
    var duration: TimeInterval         // Total seconds
    var segments: [TranscriptSegment]
    var summary: MeetingSummary?
    var audioFilePath: String?         // v1: nil if audio not retained (privacy mode)
    var kind: MeetingKind              // v3: .meeting (default) or .dictation
    var markdownExportPath: String?    // v3: filesystem path of last markdown export, if any
    var tags: [String]                 // v3: free-form tags; persisted as JSON
    var pinnedNote: String?            // v3: a single user-pinned note shown above transcript

    init(
        id: UUID = UUID(),
        title: String = "Untitled Meeting",
        date: Date = .now,
        duration: TimeInterval = 0,
        segments: [TranscriptSegment] = [],
        summary: MeetingSummary? = nil,
        audioFilePath: String? = nil,
        kind: MeetingKind = .meeting,
        markdownExportPath: String? = nil,
        tags: [String] = [],
        pinnedNote: String? = nil
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.duration = duration
        self.segments = segments
        self.summary = summary
        self.audioFilePath = audioFilePath
        self.kind = kind
        self.markdownExportPath = markdownExportPath
        self.tags = tags
        self.pinnedNote = pinnedNote
    }

    var speakerCount: Int {
        Set(segments.map(\.speaker)).count
    }

    var wordCount: Int {
        segments.reduce(0) { $0 + $1.text.split(separator: " ").count }
    }

    /// Convenience: filesystem URL for the audio file, if retained.
    var audioFileURL: URL? {
        get { audioFilePath.map { URL(fileURLWithPath: $0) } }
        set { audioFilePath = newValue?.path }
    }

    /// Convenience: filesystem URL for the markdown export, if any.
    var markdownExportURL: URL? {
        get { markdownExportPath.map { URL(fileURLWithPath: $0) } }
        set { markdownExportPath = newValue?.path }
    }

    // Custom decoder so older rows without v3 fields decode successfully.
    enum CodingKeys: String, CodingKey {
        case id, title, date, duration, segments, summary, audioFilePath
        case kind, markdownExportPath, tags, pinnedNote
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.date = try c.decode(Date.self, forKey: .date)
        self.duration = try c.decode(TimeInterval.self, forKey: .duration)
        self.segments = try c.decodeIfPresent([TranscriptSegment].self, forKey: .segments) ?? []
        self.summary = try c.decodeIfPresent(MeetingSummary.self, forKey: .summary)
        self.audioFilePath = try c.decodeIfPresent(String.self, forKey: .audioFilePath)
        self.kind = try c.decodeIfPresent(MeetingKind.self, forKey: .kind) ?? .meeting
        self.markdownExportPath = try c.decodeIfPresent(String.self, forKey: .markdownExportPath)
        self.tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        self.pinnedNote = try c.decodeIfPresent(String.self, forKey: .pinnedNote)
    }
}

// MARK: - MeetingSummary
// AI-generated summary of a meeting.

struct MeetingSummary: Codable, Sendable, Equatable {
    var overview: String              // 2-3 sentence summary
    var keyDecisions: [String]        // TWEAK: Add "owner" field per decision
    var actionItems: [ActionItem]
    var openQuestions: [String]       // TWEAK: Remove if not useful

    // TWEAK: Add more fields: topics, sentiment, follow-up date
}

struct ActionItem: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    var text: String
    var assignee: String?        // TWEAK: nil if no owner mentioned
    var dueDate: String?         // TWEAK: Parse to Date if structured
    var isCompleted: Bool

    init(
        id: UUID = UUID(),
        text: String,
        assignee: String? = nil,
        dueDate: String? = nil,
        isCompleted: Bool = false
    ) {
        self.id = id
        self.text = text
        self.assignee = assignee
        self.dueDate = dueDate
        self.isCompleted = isCompleted
    }
}
