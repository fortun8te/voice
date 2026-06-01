// VOICE — Transcribed-video persistence.
// ============================================================
// PURPOSE: durable storage for videos the user ingests + transcribes
// (YouTube links, local video files, etc.). The store owns the list,
// publishes changes to SwiftUI, and persists every mutation to a JSON
// file alongside the app's other stores.
//
// CONVENTIONS MIRRORED FROM THE EXISTING CODEBASE:
//   - Observation: `@Observable @MainActor final class … { static let shared }`
//     — same shape as `PolishStatus` (Sources/Voice/Services/PolishStatus.swift).
//     SwiftUI views bind to `TranscribedVideoStore.shared` directly.
//   - On-disk format + location: a single JSON array at
//     ~/Library/Application Support/Voice/transcribed_videos.json, written
//     atomically with `JSONEncoder`, read with `JSONDecoder`. This is the
//     exact pattern `RecentDictations` uses (recent_dictations.json) — same
//     Application Support/Voice directory, same fail-closed decode behavior
//     (a bad/missing file yields an empty list, never a crash).
//
// STANDALONE BY DESIGN: this file intentionally does NOT import or reference
// `VideoSummary` / `VideoIngestResult` (owned by other agents). The summary
// fields live here as plain stored properties so the file compiles on its
// own; the integrator copies values across at the call site.
// ============================================================

import Foundation
import Observation

/// One chat message attached to a transcribed video. The store owns this type.
/// `role` is a plain string ("user" | "assistant") to stay schema-light and
/// forward-compatible. `ts` is required (no `Date()` default) so the type stays
/// trivially constructible from any (non-isolated) context.
public struct VideoChatMessage: Codable, Identifiable, Equatable {
    public let id: UUID
    public let role: String /* "user" | "assistant" */
    public let content: String
    public let ts: Date

    public init(id: UUID = UUID(), role: String, content: String, ts: Date) {
        self.id = id
        self.role = role
        self.content = content
        self.ts = ts
    }
}

/// One transcribed video and everything we know about it. Codable so the
/// whole list round-trips through a single JSON file. `Identifiable` so
/// SwiftUI `ForEach` can key on it directly.
struct TranscribedVideo: Codable, Identifiable {
    var id: UUID
    /// Original source the video came from — a YouTube URL, a file:// URL, etc.
    let sourceURL: String
    let title: String
    let channel: String?
    let durationSeconds: Double?
    /// Path to a locally-cached thumbnail image, if one was downloaded.
    let thumbnailLocalPath: String?
    var addedAt: Date
    var transcript: String

    // MARK: - Summary fields
    //
    // These mirror the shape of the `VideoSummary` type another agent defines.
    // We deliberately store them as plain properties here (rather than nesting
    // a `VideoSummary`) so this file has no cross-file dependency and compiles
    // independently. The integrator maps a `VideoSummary` onto these.
    var tldr: String?
    var thesis: String?
    var actionItems: [String]
    var topics: [String]

    /// Stable identifier for the underlying video derived from `sourceURL`,
    /// when one can be extracted (e.g. a YouTube video id). Used for dedup so
    /// the same video ingested via differently-shaped URLs collapses to one
    /// row. `nil` when no recognizable id is present (e.g. arbitrary file URLs).
    var videoID: String? {
        TranscribedVideo.extractVideoID(from: sourceURL)
    }

    /// Best-effort extraction of a YouTube video id from common URL shapes:
    /// `watch?v=`, `youtu.be/<id>`, `/embed/<id>`, `/shorts/<id>`. Returns nil
    /// for anything that doesn't look like a YouTube URL.
    static func extractVideoID(from urlString: String) -> String? {
        guard let comps = URLComponents(string: urlString),
              let host = comps.host?.lowercased() else { return nil }

        if host.contains("youtu.be") {
            let id = comps.path.split(separator: "/").first.map(String.init)
            return (id?.isEmpty == false) ? id : nil
        }
        guard host.contains("youtube.com") else { return nil }

        if let v = comps.queryItems?.first(where: { $0.name == "v" })?.value, !v.isEmpty {
            return v
        }
        let parts = comps.path.split(separator: "/").map(String.init)
        if let i = parts.firstIndex(where: { $0 == "embed" || $0 == "shorts" }),
           i + 1 < parts.count, !parts[i + 1].isEmpty {
            return parts[i + 1]
        }
        return nil
    }

    /// Where this video sits in the ingest → transcribe → summarize pipeline.
    enum Status: String, Codable {
        case ingesting
        case transcribing
        case summarizing
        case done
        case failed
    }

    var status: Status
    /// Human-readable failure reason when `status == .failed`. Nil otherwise.
    var errorMessage: String?

    /// Conversation history attached to this video. Defaults to empty; older
    /// persisted records (written before this field existed) decode to `[]`.
    var chatMessages: [VideoChatMessage]

    /// Designated initializer. Most fields default so callers can create a
    /// freshly-ingesting row with just a source URL + title.
    init(
        id: UUID = UUID(),
        sourceURL: String,
        title: String,
        channel: String? = nil,
        durationSeconds: Double? = nil,
        thumbnailLocalPath: String? = nil,
        addedAt: Date = Date(),
        transcript: String = "",
        tldr: String? = nil,
        thesis: String? = nil,
        actionItems: [String] = [],
        topics: [String] = [],
        status: Status = .ingesting,
        errorMessage: String? = nil,
        chatMessages: [VideoChatMessage] = []
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.title = title
        self.channel = channel
        self.durationSeconds = durationSeconds
        self.thumbnailLocalPath = thumbnailLocalPath
        self.addedAt = addedAt
        self.transcript = transcript
        self.tldr = tldr
        self.thesis = thesis
        self.actionItems = actionItems
        self.topics = topics
        self.status = status
        self.errorMessage = errorMessage
        self.chatMessages = chatMessages
    }

    // Custom decoding so older persisted entries (written before a field
    // existed) still decode cleanly — array/optional fields fall back to
    // sensible empties rather than failing the whole file's decode. Mirrors
    // the back-compat tolerance RecentDictation builds in via optionals.
    enum CodingKeys: String, CodingKey {
        case id, sourceURL, title, channel, durationSeconds, thumbnailLocalPath
        case addedAt, transcript, tldr, thesis, actionItems, topics, status, errorMessage
        case chatMessages
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        sourceURL = try c.decode(String.self, forKey: .sourceURL)
        title = try c.decode(String.self, forKey: .title)
        channel = try c.decodeIfPresent(String.self, forKey: .channel)
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds)
        thumbnailLocalPath = try c.decodeIfPresent(String.self, forKey: .thumbnailLocalPath)
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        transcript = try c.decodeIfPresent(String.self, forKey: .transcript) ?? ""
        tldr = try c.decodeIfPresent(String.self, forKey: .tldr)
        thesis = try c.decodeIfPresent(String.self, forKey: .thesis)
        actionItems = try c.decodeIfPresent([String].self, forKey: .actionItems) ?? []
        topics = try c.decodeIfPresent([String].self, forKey: .topics) ?? []
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .done
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        chatMessages = try c.decodeIfPresent([VideoChatMessage].self, forKey: .chatMessages) ?? []
    }
}

/// Observable, persistent store for transcribed videos.
///
/// Observation matches `PolishStatus`: `@Observable @MainActor final class`
/// with a `static let shared` singleton. SwiftUI views read
/// `TranscribedVideoStore.shared.videos` and re-render automatically on any
/// mutation. All mutating methods persist to disk immediately (atomic write).
@Observable
@MainActor
final class TranscribedVideoStore {

    /// App-wide singleton — matches the `static let shared` convention used by
    /// PolishStatus and other long-lived services.
    static let shared = TranscribedVideoStore()

    /// All transcribed videos, newest first. Observed by SwiftUI.
    private(set) var videos: [TranscribedVideo] = []

    /// JSON file at ~/Library/Application Support/Voice/transcribed_videos.json.
    /// Same Application Support/Voice directory as RecentDictations and
    /// StorageService — created on demand if missing.
    private static var fileURL: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let voiceDir = appSupport.appendingPathComponent("Voice", isDirectory: true)
        try? FileManager.default.createDirectory(at: voiceDir, withIntermediateDirectories: true)
        return voiceDir.appendingPathComponent("transcribed_videos.json")
    }

    /// Load from disk on init. Fail-closed: a missing or corrupt file leaves
    /// `videos` empty rather than crashing — same posture as RecentDictations.
    private init() {
        videos = Self.loadFromDisk()
    }

    // MARK: - Public API

    /// Insert a new video, deduping against existing entries. This is the
    /// dedup entry point: if a video already exists with the same `id`, the
    /// same non-nil `videoID`, or the same `sourceURL`, the existing entry is
    /// replaced in place (preserving its id/addedAt/chatMessages) rather than
    /// inserting a duplicate. Otherwise the video is added at the front.
    func add(_ video: TranscribedVideo) {
        upsert(video)
    }

    /// Replace any existing entry matching `video` (by id, non-nil videoID, or
    /// sourceURL) in place, preserving the prior entry's identity — its `id`,
    /// `addedAt`, and `chatMessages` are kept so persisted UUIDs and history
    /// survive a re-ingest. Inserts at the front if no match is found.
    func upsert(_ video: TranscribedVideo) {
        let idx = videos.firstIndex { existing in
            if existing.id == video.id { return true }
            if let v = video.videoID, !v.isEmpty, existing.videoID == v { return true }
            return existing.sourceURL == video.sourceURL
        }
        if let idx {
            let prior = videos[idx]
            var merged = video
            merged.id = prior.id
            merged.addedAt = prior.addedAt
            // Preserve prior chat history unless the incoming video carries its own.
            if merged.chatMessages.isEmpty {
                merged.chatMessages = prior.chatMessages
            }
            videos[idx] = merged
        } else {
            videos.insert(video, at: 0)
        }
        sortNewestFirst()
        persist()
    }

    /// Replace the existing video that shares `video.id`. No-op if none matches.
    func update(_ video: TranscribedVideo) {
        guard let idx = videos.firstIndex(where: { $0.id == video.id }) else { return }
        videos[idx] = video
        persist()
    }

    /// Remove the video with the given id, if present.
    func remove(id: UUID) {
        let before = videos.count
        videos.removeAll { $0.id == id }
        if videos.count != before { persist() }
    }

    /// Append a chat message to the video with the given id and persist.
    /// No-op if no video matches.
    func appendChatMessage(_ m: VideoChatMessage, toVideoID id: UUID) {
        guard let idx = videos.firstIndex(where: { $0.id == id }) else { return }
        videos[idx].chatMessages.append(m)
        persist()
    }

    /// Drop everything and clear the on-disk file.
    func clear() {
        guard !videos.isEmpty else { return }
        videos.removeAll()
        persist()
    }

    // MARK: - Derived views

    /// `videos` bucketed by calendar day of `addedAt` for sectioned UI.
    /// Days are sorted descending (newest day first); videos within each day
    /// are sorted by `addedAt` descending. `day` is the start-of-day instant.
    var groupedByDay: [(day: Date, videos: [TranscribedVideo])] {
        let cal = Calendar.current
        let buckets = Dictionary(grouping: videos) { cal.startOfDay(for: $0.addedAt) }
        return buckets
            .map { (day: $0.key, videos: $0.value.sorted { $0.addedAt > $1.addedAt }) }
            .sorted { $0.day > $1.day }
    }

    // MARK: - Persistence

    /// Keep `videos` ordered newest-first by `addedAt`.
    private func sortNewestFirst() {
        videos.sort { $0.addedAt > $1.addedAt }
    }

    /// Write the current list to disk atomically. Errors are logged and
    /// swallowed — a failed write must never take down the app or break the
    /// in-memory state the UI is bound to.
    private func persist() {
        do {
            let data = try JSONEncoder().encode(videos)
            try data.write(to: Self.fileURL, options: .atomic)
        } catch {
            NSLog("[VOICE-STORAGE] failed to write transcribed_videos.json: \(error)")
        }
    }

    /// Read + decode the JSON file. Returns [] on any failure (missing file,
    /// corrupt JSON, schema mismatch) after logging — never throws.
    private static func loadFromDisk() -> [TranscribedVideo] {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([TranscribedVideo].self, from: data)
            return decoded.sorted { $0.addedAt > $1.addedAt }
        } catch {
            NSLog("[VOICE-STORAGE] failed to read transcribed_videos.json: \(error)")
            return []
        }
    }
}
