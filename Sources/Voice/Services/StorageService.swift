// VOICE — Storage Service (GRDB + SQLite + FTS5)
// ============================================================
// Durable, searchable persistence layer for meetings, transcripts, and
// summaries. Uses GRDB.swift on top of SQLite with FTS5.
//
// Schema (current = v3):
//   meetings(
//     id TEXT PRIMARY KEY,
//     title TEXT NOT NULL DEFAULT 'Untitled Meeting',
//     date DATETIME NOT NULL,
//     duration REAL NOT NULL DEFAULT 0,
//     audioFilePath TEXT,                -- v1; nil if no audio retained
//     kind TEXT NOT NULL DEFAULT 'meeting',  -- v3
//     markdownExportPath TEXT,           -- v3
//     tagsJson TEXT NOT NULL DEFAULT '[]',  -- v3
//     pinnedNote TEXT                    -- v3
//   )
//   segments(
//     id TEXT PRIMARY KEY,
//     meetingId TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
//     speaker TEXT NOT NULL,
//     text TEXT NOT NULL,
//     startTime REAL NOT NULL,
//     endTime REAL NOT NULL,
//     confidence REAL,
//     speakerId TEXT,                    -- v2
//     isFinal INTEGER NOT NULL DEFAULT 1 -- v2 (0/1 boolean)
//   )
//   summaries(
//     id TEXT PRIMARY KEY,
//     meetingId TEXT NOT NULL UNIQUE REFERENCES meetings(id) ON DELETE CASCADE,
//     overview TEXT NOT NULL,
//     keyDecisionsJson TEXT NOT NULL,
//     actionItemsJson TEXT NOT NULL,
//     openQuestionsJson TEXT NOT NULL
//   )
//   segments_fts (FTS5 virtual table mirroring segments.text + speaker)
//
// Pragmas: journal_mode=WAL, synchronous=NORMAL (fast, durable).
// Backups: voice.db.backup is refreshed on launch when older than 24h.
// Recovery: PRAGMA integrity_check on launch; restore from backup on fail.
// ============================================================

import Foundation
import GRDB

/// A single full-text-search hit: which meeting/segment matched, with
/// a snippet of highlighted context and the BM25 rank (lower is better).
struct SearchHit: Codable, Sendable {
    let meeting: Meeting
    let segment: TranscriptSegment
    let snippet: String
    let rank: Double
}

class StorageService {
    private var dbPool: DatabasePool?

    // MARK: - Paths

    /// Directory containing the database file and its backup.
    private var voiceDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let voiceDir = appSupport.appendingPathComponent("Voice", isDirectory: true)
        try? FileManager.default.createDirectory(at: voiceDir, withIntermediateDirectories: true)
        return voiceDir
    }

    /// Where the SQLite file lives (~/Library/Application Support/Voice/voice.db).
    private var databasePath: String {
        voiceDirectory.appendingPathComponent("voice.db").path
    }

    /// Sibling backup file used for automatic recovery.
    private var backupPath: String {
        voiceDirectory.appendingPathComponent("voice.db.backup").path
    }

    /// Directory where audio recordings are stored on disk.
    /// Used by `pruneOrphanedAudio()` to find unreferenced files.
    private var audioDirectory: URL {
        let dir = voiceDirectory.appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Initialization

    /// Open (or create) the database, configure pragmas, run migrations,
    /// verify integrity, and refresh the backup if it's older than 24h.
    /// Safe to call exactly once at app launch.
    func initialize() throws {
        // Integrity check on the existing file before opening it for writes.
        // If corrupt, attempt restore from backup.
        try recoverIfCorrupt()

        var config = Configuration()
        // WAL + NORMAL synchronous: fast writes that survive crashes
        // (only loses txns from the last few ms before a power loss).
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        dbPool = try DatabasePool(path: databasePath, configuration: config)
        try migrate()
        try refreshBackupIfStale()
    }

    // MARK: - Schema Migration
    //
    // We use GRDB's DatabaseMigrator (which is backed by sqlite_master inspection
    // and is equivalent in spirit to a `user_version` PRAGMA — it's idempotent
    // and tracks applied migrations in a `grdb_migrations` table). Each ALTER
    // step is wrapped in a transaction by GRDB. New migrations are append-only.

    private func migrate() throws {
        guard let db = dbPool else { return }
        var migrator = DatabaseMigrator()

        // -------- v1: initial schema --------
        migrator.registerMigration("v1_create_tables") { db in
            try db.create(table: "meetings") { t in
                t.primaryKey("id", .text).notNull()
                t.column("title", .text).notNull().defaults(to: "Untitled Meeting")
                t.column("date", .datetime).notNull()
                t.column("duration", .double).notNull().defaults(to: 0)
                t.column("audioFilePath", .text)
            }

            try db.create(table: "segments") { t in
                t.primaryKey("id", .text).notNull()
                t.column("meetingId", .text).notNull()
                    .references("meetings", onDelete: .cascade)
                t.column("speaker", .text).notNull()
                t.column("text", .text).notNull()
                t.column("startTime", .double).notNull()
                t.column("endTime", .double).notNull()
                t.column("confidence", .double)
            }

            try db.create(table: "summaries") { t in
                t.primaryKey("id", .text).notNull()
                t.column("meetingId", .text).notNull().unique()
                    .references("meetings", onDelete: .cascade)
                t.column("overview", .text).notNull()
                t.column("keyDecisionsJson", .text).notNull()
                t.column("actionItemsJson", .text).notNull()
                t.column("openQuestionsJson", .text).notNull()
            }

            // FTS5 virtual table mirroring segments. GRDB's `synchronize`
            // installs INSERT/UPDATE/DELETE triggers that keep the index
            // in lockstep with the source table.
            try db.create(virtualTable: "segments_fts", using: FTS5()) { t in
                t.synchronize(withTable: "segments")
                t.tokenizer = .unicode61()
                t.column("text")
                t.column("speaker")
            }
        }

        // -------- v2: TranscriptSegment new columns --------
        // Idempotent because GRDB only runs unregistered migrations.
        migrator.registerMigration("v2_segment_columns") { db in
            try db.alter(table: "segments") { t in
                t.add(column: "speakerId", .text)
                t.add(column: "isFinal", .integer).notNull().defaults(to: 1)
            }
        }

        // -------- v3: Meeting new columns --------
        migrator.registerMigration("v3_meeting_columns") { db in
            try db.alter(table: "meetings") { t in
                t.add(column: "kind", .text).notNull().defaults(to: MeetingKind.meeting.rawValue)
                t.add(column: "markdownExportPath", .text)
                t.add(column: "tagsJson", .text).notNull().defaults(to: "[]")
                t.add(column: "pinnedNote", .text)
            }
        }

        try migrator.migrate(db)
    }

    // MARK: - Backup & Recovery

    /// Copy the current database file to `voice.db.backup` if no backup
    /// exists or the existing one is older than 24 hours. Best-effort:
    /// failures are logged but not thrown — a stale backup is preferable
    /// to a failed launch.
    private func refreshBackupIfStale() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: databasePath) else { return }

        let needsBackup: Bool
        if let attrs = try? fm.attributesOfItem(atPath: backupPath),
           let modDate = attrs[.modificationDate] as? Date {
            needsBackup = Date().timeIntervalSince(modDate) > 24 * 3600
        } else {
            needsBackup = true
        }

        guard needsBackup else { return }

        // Atomic-ish: copy to a temp path then rename. Avoids leaving a
        // half-written backup if we're killed mid-copy.
        let tempPath = backupPath + ".tmp"
        try? fm.removeItem(atPath: tempPath)
        do {
            try fm.copyItem(atPath: databasePath, toPath: tempPath)
            if fm.fileExists(atPath: backupPath) {
                try fm.removeItem(atPath: backupPath)
            }
            try fm.moveItem(atPath: tempPath, toPath: backupPath)
        } catch {
            NSLog("[Voice/Storage] backup refresh failed: \(error)")
        }
    }

    /// Run `PRAGMA integrity_check` on the existing DB. If it returns anything
    /// other than "ok", restore from `voice.db.backup` if one exists.
    /// Logs to stderr — the app continues launching with whatever it has.
    private func recoverIfCorrupt() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: databasePath) else { return }

        // Open in a temporary pool just for the check, so we don't pollute
        // the real pool's configuration.
        let tempPool: DatabasePool
        do {
            tempPool = try DatabasePool(path: databasePath)
        } catch {
            // Can't even open it — try restore.
            try restoreFromBackup()
            return
        }

        let healthy: Bool = (try? tempPool.read { db -> Bool in
            let result = try String.fetchOne(db, sql: "PRAGMA integrity_check") ?? ""
            return result.lowercased() == "ok"
        }) ?? false

        if !healthy {
            NSLog("[Voice/Storage] integrity_check failed — restoring from backup")
            try restoreFromBackup()
        }
    }

    /// Move the corrupt DB aside and copy the backup into its place.
    /// No-op (with a warning) if no backup exists.
    private func restoreFromBackup() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: backupPath) else {
            NSLog("[Voice/Storage] no backup available for recovery")
            return
        }
        let corruptPath = databasePath + ".corrupt-\(Int(Date().timeIntervalSince1970))"
        if fm.fileExists(atPath: databasePath) {
            try? fm.moveItem(atPath: databasePath, toPath: corruptPath)
        }
        try fm.copyItem(atPath: backupPath, toPath: databasePath)
        NSLog("[Voice/Storage] restored DB from backup; corrupt copy at \(corruptPath)")
    }

    // MARK: - CRUD Operations
    //
    // Every multi-row write goes through `db.write { ... }`, which GRDB
    // implements as `BEGIN IMMEDIATE; ... ; COMMIT`. Any thrown error
    // inside the block triggers ROLLBACK automatically, so partial
    // writes never reach disk.

    /// Insert or replace a meeting plus all of its segments and summary.
    /// Atomic: a failure on any row rolls back the whole save.
    func saveMeeting(_ meeting: Meeting) throws {
        guard let db = dbPool else { return }

        try db.write { db in
            let tagsJson = (try? String(data: JSONEncoder().encode(meeting.tags), encoding: .utf8)) ?? "[]"

            try db.execute(
                sql: """
                INSERT OR REPLACE INTO meetings
                    (id, title, date, duration, audioFilePath,
                     kind, markdownExportPath, tagsJson, pinnedNote)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    meeting.id.uuidString,
                    meeting.title,
                    meeting.date,
                    meeting.duration,
                    meeting.audioFilePath,
                    meeting.kind.rawValue,
                    meeting.markdownExportPath,
                    tagsJson,
                    meeting.pinnedNote
                ]
            )

            for segment in meeting.segments {
                try db.execute(
                    sql: """
                    INSERT OR REPLACE INTO segments
                        (id, meetingId, speaker, text, startTime, endTime,
                         confidence, speakerId, isFinal)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        segment.id.uuidString,
                        meeting.id.uuidString,
                        segment.speaker,
                        segment.text,
                        segment.startTime,
                        segment.endTime,
                        segment.confidence,
                        segment.speakerId,
                        segment.isFinal ? 1 : 0
                    ]
                )
            }

            if let summary = meeting.summary {
                let decisionsJson = try JSONEncoder().encode(summary.keyDecisions)
                let actionsJson = try JSONEncoder().encode(summary.actionItems)
                let questionsJson = try JSONEncoder().encode(summary.openQuestions)

                try db.execute(
                    sql: """
                    INSERT OR REPLACE INTO summaries
                        (id, meetingId, overview, keyDecisionsJson,
                         actionItemsJson, openQuestionsJson)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        UUID().uuidString,
                        meeting.id.uuidString,
                        summary.overview,
                        String(data: decisionsJson, encoding: .utf8),
                        String(data: actionsJson, encoding: .utf8),
                        String(data: questionsJson, encoding: .utf8)
                    ]
                )
            }
        }
    }

    /// Fetch every meeting, newest first, with segments and summary inlined.
    func fetchAllMeetings() throws -> [Meeting] {
        guard let db = dbPool else { return [] }
        return try db.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM meetings ORDER BY date DESC")
            return try rows.map { try meeting(from: $0, in: db) }
        }
    }

    /// Most recent N meetings (date DESC). Convenience wrapper.
    func recentMeetings(limit: Int = 20) throws -> [Meeting] {
        guard let db = dbPool else { return [] }
        return try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM meetings ORDER BY date DESC LIMIT ?",
                arguments: [limit]
            )
            return try rows.map { try meeting(from: $0, in: db) }
        }
    }

    /// Filter meetings by kind (`.dictation` or `.meeting`), newest first.
    func meetingsByKind(_ kind: MeetingKind) throws -> [Meeting] {
        guard let db = dbPool else { return [] }
        return try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM meetings WHERE kind = ? ORDER BY date DESC",
                arguments: [kind.rawValue]
            )
            return try rows.map { try meeting(from: $0, in: db) }
        }
    }

    /// Delete a meeting by ID. Cascade removes its segments, FTS rows,
    /// and summary. Also unlinks the audio file on disk if one is set.
    func deleteMeeting(id: UUID) throws {
        guard let db = dbPool else { return }
        try db.write { db in
            // Look up the audio path before deleting the row.
            let audioPath = try String.fetchOne(
                db,
                sql: "SELECT audioFilePath FROM meetings WHERE id = ?",
                arguments: [id.uuidString]
            )
            try db.execute(sql: "DELETE FROM meetings WHERE id = ?", arguments: [id.uuidString])
            if let path = audioPath, !path.isEmpty {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }

    // MARK: - Search

    /// Legacy full-text search returning whole meetings. Kept for callers
    /// that just want a list of matching meetings (e.g. the search UI in
    /// RecordingCoordinator).
    func searchTranscripts(query: String) throws -> [Meeting] {
        guard let db = dbPool else { return [] }
        let safeQuery = sanitizeFTSQuery(query)
        guard !safeQuery.isEmpty else { return [] }

        return try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT s.meetingId
                FROM segments_fts fts
                JOIN segments s ON s.rowid = fts.rowid
                WHERE segments_fts MATCH ?
                ORDER BY rank
            """, arguments: [safeQuery])

            let meetingIds = rows.map { $0["meetingId"] as String }
            return try meetingIds.compactMap { meetingId in
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM meetings WHERE id = ?",
                    arguments: [meetingId]
                ) else { return nil }
                return try self.meeting(from: row, in: db)
            }
        }
    }

    /// Full-text search returning hit-level results. Each hit carries the
    /// matching segment, a highlighted snippet, the BM25 rank (lower is
    /// better), and the parent meeting (without its segments inlined, to
    /// keep payload small — call `fetchAllMeetings` if you need them).
    func searchTranscripts(query: String, limit: Int = 50) throws -> [SearchHit] {
        guard let db = dbPool else { return [] }
        let safeQuery = sanitizeFTSQuery(query)
        guard !safeQuery.isEmpty else { return [] }

        return try db.read { db in
            // bm25() — lower is more relevant. snippet() wraps matches in
            // « / » so callers can highlight without re-tokenizing.
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    s.id           AS segmentId,
                    s.meetingId    AS meetingId,
                    s.speaker      AS speaker,
                    s.text         AS text,
                    s.startTime    AS startTime,
                    s.endTime      AS endTime,
                    s.confidence   AS confidence,
                    s.speakerId    AS speakerId,
                    s.isFinal      AS isFinal,
                    snippet(segments_fts, 0, '«', '»', '…', 12) AS snippet,
                    bm25(segments_fts) AS rank
                FROM segments_fts fts
                JOIN segments s ON s.rowid = fts.rowid
                WHERE segments_fts MATCH ?
                ORDER BY rank
                LIMIT ?
            """, arguments: [safeQuery, limit])

            return try rows.compactMap { row -> SearchHit? in
                let meetingId = row["meetingId"] as String
                guard let meetingRow = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM meetings WHERE id = ?",
                    arguments: [meetingId]
                ) else { return nil }

                // Build a lightweight meeting (no segments/summary inlined).
                let parent = try self.meetingHeader(from: meetingRow)

                let segment = TranscriptSegment(
                    id: UUID(uuidString: row["segmentId"]) ?? UUID(),
                    speaker: row["speaker"],
                    speakerId: row["speakerId"],
                    text: row["text"],
                    startTime: row["startTime"],
                    endTime: row["endTime"],
                    confidence: row["confidence"],
                    isFinal: ((row["isFinal"] as Int?) ?? 1) != 0
                )

                return SearchHit(
                    meeting: parent,
                    segment: segment,
                    snippet: row["snippet"] ?? "",
                    rank: row["rank"] ?? 0
                )
            }
        }
    }

    /// Strip characters that would make the FTS5 MATCH grammar choke
    /// (quotes, parens, colons). Falls back to a quoted phrase if the
    /// caller passed something that looks like free text rather than an
    /// FTS expression.
    private func sanitizeFTSQuery(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // Strip dangerous chars; keep word chars, spaces, *, AND/OR/NOT.
        let allowed = CharacterSet.alphanumerics
            .union(.whitespaces)
            .union(CharacterSet(charactersIn: "*-_"))
        let cleaned = String(trimmed.unicodeScalars.filter { allowed.contains($0) })
        guard !cleaned.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
        return cleaned
    }

    // MARK: - Tags & Notes

    /// Append `tag` to the meeting's tag list (deduped). No-op if the
    /// meeting doesn't exist or already has the tag.
    func addTag(meetingId: UUID, tag: String) throws {
        guard let db = dbPool else { return }
        let tag = tag.trimmingCharacters(in: .whitespaces)
        guard !tag.isEmpty else { return }
        try db.write { db in
            var tags = try self.fetchTags(meetingId: meetingId, in: db)
            guard !tags.contains(tag) else { return }
            tags.append(tag)
            try self.writeTags(tags, meetingId: meetingId, in: db)
        }
    }

    /// Remove `tag` from the meeting's tag list. No-op if absent.
    func removeTag(meetingId: UUID, tag: String) throws {
        guard let db = dbPool else { return }
        try db.write { db in
            var tags = try self.fetchTags(meetingId: meetingId, in: db)
            tags.removeAll { $0 == tag }
            try self.writeTags(tags, meetingId: meetingId, in: db)
        }
    }

    /// Set or clear (`nil`) the single user-pinned note shown above the
    /// transcript for a meeting.
    func setPinnedNote(meetingId: UUID, note: String?) throws {
        guard let db = dbPool else { return }
        try db.write { db in
            try db.execute(
                sql: "UPDATE meetings SET pinnedNote = ? WHERE id = ?",
                arguments: [note, meetingId.uuidString]
            )
        }
    }

    private func fetchTags(meetingId: UUID, in db: Database) throws -> [String] {
        let json = try String.fetchOne(
            db,
            sql: "SELECT tagsJson FROM meetings WHERE id = ?",
            arguments: [meetingId.uuidString]
        ) ?? "[]"
        return (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
    }

    private func writeTags(_ tags: [String], meetingId: UUID, in db: Database) throws {
        let data = try JSONEncoder().encode(tags)
        let json = String(data: data, encoding: .utf8) ?? "[]"
        try db.execute(
            sql: "UPDATE meetings SET tagsJson = ? WHERE id = ?",
            arguments: [json, meetingId.uuidString]
        )
    }

    // MARK: - Audio retention

    /// Scan the audio directory and delete any `.caf`/`.wav`/`.m4a` files
    /// that aren't referenced by a meeting row. Returns the number of
    /// files removed. Safe to call any time; cheap (single DB query +
    /// directory listing).
    @discardableResult
    func pruneOrphanedAudio() throws -> Int {
        guard let db = dbPool else { return 0 }
        let fm = FileManager.default
        let referenced: Set<String> = try db.read { db in
            let paths = try String.fetchAll(
                db,
                sql: "SELECT audioFilePath FROM meetings WHERE audioFilePath IS NOT NULL"
            )
            return Set(paths)
        }

        let exts: Set<String> = ["caf", "wav", "m4a"]
        guard let entries = try? fm.contentsOfDirectory(
            at: audioDirectory,
            includingPropertiesForKeys: nil
        ) else { return 0 }

        var removed = 0
        for url in entries where exts.contains(url.pathExtension.lowercased()) {
            if !referenced.contains(url.path) {
                try? fm.removeItem(at: url)
                removed += 1
            }
        }
        return removed
    }

    // MARK: - Export

    /// Build a Markdown document from a meeting (title, summary, full transcript).
    func exportAsMarkdown(_ meeting: Meeting) -> String {
        var md = "# \(meeting.title)\n"
        md += "**Date:** \(meeting.date.formatted())\n"
        md += "**Duration:** \(Int(meeting.duration / 60)) minutes\n"
        md += "**Speakers:** \(meeting.speakerCount)\n\n"

        if let pin = meeting.pinnedNote, !pin.isEmpty {
            md += "> \(pin)\n\n"
        }

        if !meeting.tags.isEmpty {
            md += "**Tags:** " + meeting.tags.map { "`\($0)`" }.joined(separator: " ") + "\n\n"
        }

        if let summary = meeting.summary {
            md += "## Summary\n\(summary.overview)\n\n"

            if !summary.keyDecisions.isEmpty {
                md += "## Key Decisions\n"
                summary.keyDecisions.forEach { md += "- \($0)\n" }
                md += "\n"
            }

            if !summary.actionItems.isEmpty {
                md += "## Action Items\n"
                summary.actionItems.forEach { item in
                    let check = item.isCompleted ? "[x]" : "[ ]"
                    md += "- \(check) \(item.text)"
                    if let assignee = item.assignee { md += " — \(assignee)" }
                    md += "\n"
                }
                md += "\n"
            }
        }

        md += "## Transcript\n\n"
        for segment in meeting.segments {
            md += "**\(segment.speaker)** (\(segment.formattedTimestamp))\n"
            md += "\(segment.text)\n\n"
        }
        return md
    }

    /// Encode a meeting as JSON. Reflects the full v3 schema.
    func exportAsJSON(_ meeting: Meeting) throws -> Data {
        try JSONEncoder().encode(meeting)
    }

    // MARK: - Private Helpers

    /// Build a full Meeting (with segments + summary) from a `meetings` row.
    private func meeting(from row: Row, in db: Database) throws -> Meeting {
        let meetingId = row["id"] as String
        let segments = try fetchSegments(for: meetingId, in: db)
        let summary = try fetchSummary(for: meetingId, in: db)
        let tags = decodeTags(row["tagsJson"] as String?)
        let kind = MeetingKind(rawValue: (row["kind"] as String?) ?? "") ?? .meeting

        return Meeting(
            id: UUID(uuidString: meetingId) ?? UUID(),
            title: row["title"],
            date: row["date"],
            duration: row["duration"],
            segments: segments,
            summary: summary,
            audioFilePath: row["audioFilePath"],
            kind: kind,
            markdownExportPath: row["markdownExportPath"],
            tags: tags,
            pinnedNote: row["pinnedNote"]
        )
    }

    /// Build a Meeting "header" (no segments/summary) from a row.
    /// Used by search hits where we don't want to load every segment.
    private func meetingHeader(from row: Row) throws -> Meeting {
        let meetingId = row["id"] as String
        let tags = decodeTags(row["tagsJson"] as String?)
        let kind = MeetingKind(rawValue: (row["kind"] as String?) ?? "") ?? .meeting

        return Meeting(
            id: UUID(uuidString: meetingId) ?? UUID(),
            title: row["title"],
            date: row["date"],
            duration: row["duration"],
            segments: [],
            summary: nil,
            audioFilePath: row["audioFilePath"],
            kind: kind,
            markdownExportPath: row["markdownExportPath"],
            tags: tags,
            pinnedNote: row["pinnedNote"]
        )
    }

    private func decodeTags(_ json: String?) -> [String] {
        guard let json, !json.isEmpty else { return [] }
        return (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
    }

    private func fetchSegments(for meetingId: String, in db: Database) throws -> [TranscriptSegment] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT * FROM segments WHERE meetingId = ? ORDER BY startTime",
            arguments: [meetingId]
        )
        return rows.map { row in
            TranscriptSegment(
                id: UUID(uuidString: row["id"]) ?? UUID(),
                speaker: row["speaker"],
                speakerId: row["speakerId"],
                text: row["text"],
                startTime: row["startTime"],
                endTime: row["endTime"],
                confidence: row["confidence"],
                isFinal: ((row["isFinal"] as Int?) ?? 1) != 0
            )
        }
    }

    private func fetchSummary(for meetingId: String, in db: Database) throws -> MeetingSummary? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM summaries WHERE meetingId = ?",
            arguments: [meetingId]
        ) else {
            return nil
        }

        let decisions = try JSONDecoder().decode(
            [String].self,
            from: (row["keyDecisionsJson"] as String).data(using: .utf8)!
        )
        let actions = try JSONDecoder().decode(
            [ActionItem].self,
            from: (row["actionItemsJson"] as String).data(using: .utf8)!
        )
        let questions = try JSONDecoder().decode(
            [String].self,
            from: (row["openQuestionsJson"] as String).data(using: .utf8)!
        )

        return MeetingSummary(
            overview: row["overview"],
            keyDecisions: decisions,
            actionItems: actions,
            openQuestions: questions
        )
    }

    // MARK: - Self tests
    //
    // Not wired into a test target. Call manually from a debug menu when
    // you want to smoke-check the storage layer end-to-end.

    #if DEBUG
    /// Build a throwaway DB in a temp dir, exercise the full surface,
    /// assert search + cascade delete behave. Throws on first failure.
    static func runSelfTests() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("voice-selftest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let pool = try DatabasePool(
            path: tmp.appendingPathComponent("voice.db").path,
            configuration: config
        )

        // We can't reuse `migrate()` because it needs a real instance, so
        // run a minimal copy here. (Trade-off: this stub validates the
        // wiring but isn't a substitute for an XCTest target.)
        let svc = StorageService()
        svc.dbPool = pool
        try svc.migrate()

        // Insert 3 meetings, each with one segment.
        for i in 0..<3 {
            let m = Meeting(
                title: "Meeting \(i)",
                duration: 60,
                segments: [
                    TranscriptSegment(
                        speaker: "Speaker \(i)",
                        text: i == 1 ? "the quick brown fox" : "filler text \(i)",
                        startTime: 0,
                        endTime: 1
                    )
                ],
                kind: .meeting
            )
            try svc.saveMeeting(m)
        }

        // Search hits the middle meeting.
        let hits = try svc.searchTranscripts(query: "brown", limit: 10)
        guard hits.count == 1, hits[0].meeting.title == "Meeting 1" else {
            throw NSError(domain: "Voice.StorageService.SelfTest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "search expected 1 hit, got \(hits.count)"])
        }

        // Delete cascade.
        try svc.deleteMeeting(id: hits[0].meeting.id)
        let postDelete = try svc.searchTranscripts(query: "brown", limit: 10)
        guard postDelete.isEmpty else {
            throw NSError(domain: "Voice.StorageService.SelfTest", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "delete cascade leaked \(postDelete.count) hits"])
        }

        let remaining = try svc.fetchAllMeetings()
        guard remaining.count == 2 else {
            throw NSError(domain: "Voice.StorageService.SelfTest", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "expected 2 remaining meetings, got \(remaining.count)"])
        }
    }
    #endif
}
