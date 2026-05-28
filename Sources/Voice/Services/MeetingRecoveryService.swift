// VOICE — Meeting recovery & resilience.
// ============================================================
// PURPOSE: never let a meeting be lost again.
//
// THREE LAYERS:
//
// 1. ORPHAN AUDIO SCAN (on app launch)
//    Scans ~/Library/Application Support/Voice/audio/ for meeting-*.wav files
//    whose UUID-derived path doesn't match any row in the meetings table.
//    Surfaces them via `discoverOrphanedMeetingAudio()`. The caller (VoiceApp)
//    can then offer "Recover this meeting" or auto-create a placeholder
//    Meeting with kind=.meeting that points at the orphan WAV.
//
// 2. RE-TRANSCRIBE FROM SAVED AUDIO
//    `retranscribe(meeting:)` takes any Meeting that has a non-nil
//    audioFilePath, runs the saved WAV through TranscriptionService, and
//    overwrites the meeting's segments with the fresh result. This is the
//    "the transcript got dropped but the audio is still there" rescue path.
//
// 3. LIVE CHECKPOINT (during a meeting)
//    `checkpointDraft(meetingId:segments:audioPath:)` writes the partial
//    meeting state to the DB every 30s during an active capture. If the app
//    crashes mid-meeting, the next launch finds the partial row and the
//    audio file together. Worst-case loss is the most recent 30s of
//    transcript (the audio loses nothing — it streams continuously).
//
// All three layers fail closed: errors are logged with [VOICE-RECOVERY]
// and never throw out to the caller in a way that takes down the app.
// ============================================================

import Foundation
import AVFoundation

/// Lightweight handle describing a meeting WAV on disk that has no DB row.
/// Returned by `discoverOrphanedMeetingAudio()`.
struct OrphanedMeetingAudio: Identifiable, Sendable {
    let id: UUID
    let audioFileURL: URL
    let createdAt: Date
    let durationSeconds: TimeInterval  // 0 if AVAudioFile couldn't read header
    let sizeBytes: Int64
}

/// Snapshot used by the live-checkpoint path. We don't import RecordingState
/// here to keep this service free of UI dependencies.
struct MeetingDraftSnapshot: Sendable {
    let meetingId: UUID
    let title: String
    let date: Date
    let durationSeconds: TimeInterval
    let segments: [TranscriptSegment]
    let audioFilePath: String?
    let sourceApp: String?
    let participantNames: [String]
}

@MainActor
final class MeetingRecoveryService {

    // MARK: - Dependencies (injected, never owned)

    private let storage: StorageService
    private let transcription: TranscriptionService

    /// Wall-clock time the recovery service was instantiated. Used to filter
    /// out files modified after app launch — those belong to the CURRENT
    /// session and must never be treated as orphans.
    private let launchTime: Date = Date()

    /// Minimum age (seconds) a file must be vs. `launchTime` before recovery
    /// will touch it. 30s buffer protects against clock skew and the case
    /// where capture started moments before recovery ran.
    private static let recoveryMinAgeSeconds: TimeInterval = 30

    /// Emergency escape hatch. When this UserDefaults key is true, ALL
    /// recovery operations short-circuit and return empty / no-op. Lets the
    /// user disable recovery from the command line if it's misbehaving:
    ///     defaults write <bundleID> voice.skipMeetingRecovery -bool YES
    private static let skipRecoveryDefaultsKey = "voice.skipMeetingRecovery"

    private static var skipRecoveryRequested: Bool {
        UserDefaults.standard.bool(forKey: skipRecoveryDefaultsKey)
    }

    init(storage: StorageService, transcription: TranscriptionService) {
        self.storage = storage
        self.transcription = transcription
    }

    // IMPORTANT INVARIANTS (do not break):
    //   1. Recovery is ONE-SHOT on app launch. No timers, no recurring
    //      background scans. If you ever add a scheduled rescan here, you
    //      will trigger the screen-recording-when-not-in-a-meeting bug.
    //   2. Recovery NEVER starts a new capture. This file must not call
    //      `MeetingCaptureService.start()`, instantiate `SCStream`, or call
    //      `SCShareableContent.current` — any of those will request screen
    //      recording permission and trip macOS's recording indicator.
    //   3. Recovery only touches files OLDER than `launchTime` (minus the
    //      30s buffer). Files written by the current session are off-limits.

    // MARK: - Audio directory

    /// Same path MeetingCaptureService writes to:
    /// ~/Library/Application Support/Voice/audio/meeting-*.wav
    /// (lowercase "audio" — historically the dir name).
    static var meetingAudioDirectory: URL {
        let appSupport: URL
        do {
            appSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            appSupport = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        }
        return appSupport.appendingPathComponent("Voice/audio", isDirectory: true)
    }

    // MARK: - User-initiated audio file import
    //
    // Drag-and-drop or "Import audio…" file picker entry point. Accepts any
    // AVFoundation-readable format (m4a, mp3, wav, caf, aiff, …), converts
    // to 16kHz mono WAV in the meetings audio directory under a `meeting-*.wav`
    // filename, and inserts a Meeting row pointing at it. Caller can then
    // trigger retranscribe to populate segments + summary.

    /// Import an external audio file. Copies + converts to the canonical
    /// 16kHz mono WAV format Voice uses internally. Returns the created
    /// Meeting on success, nil on any failure (logged).
    func importAudioFile(_ sourceURL: URL, title customTitle: String? = nil) async -> Meeting? {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            print("[VOICE-IMPORT] source file missing: \(sourceURL.path)")
            return nil
        }

        // Build the destination filename. We mimic the live-recording naming
        // convention so the orphan scanner + WAV-repair pass treat it the
        // same way as real meeting captures.
        let now = Date()
        let stamp: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone.current
            return f.string(from: now)
        }()
        let shortID = String(UUID().uuidString.prefix(6)).lowercased()
        let destURL = Self.meetingAudioDirectory
            .appendingPathComponent("meeting-\(stamp)-\(shortID).wav")

        // Convert via AVAudioFile read + AVAudioConverter to 16kHz mono PCM.
        // afconvert would work too but keeping it in-process is more reliable
        // than spawning a subprocess from inside the app sandbox.
        let duration: TimeInterval
        do {
            duration = try Self.convertToCanonicalWAV(source: sourceURL, dest: destURL)
        } catch {
            print("[VOICE-IMPORT] conversion failed: \(error.localizedDescription)")
            return nil
        }

        // Build the Meeting row.
        let derivedTitle = customTitle?.trimmingCharacters(in: .whitespaces)
            ?? sourceURL.deletingPathExtension().lastPathComponent
        let meeting = Meeting(
            id: UUID(),
            title: derivedTitle,
            date: now,
            duration: duration,
            segments: [],
            audioFilePath: destURL.path,
            kind: duration >= 300 ? .meeting : .dictation,
            sourceApp: nil
        )

        do {
            try storage.saveMeeting(meeting)
            print("[VOICE-IMPORT] imported \(sourceURL.lastPathComponent) (\(Int(duration))s) → \(meeting.id)")
            return meeting
        } catch {
            print("[VOICE-IMPORT] DB save failed: \(error.localizedDescription)")
            // Try to clean up the orphan WAV we just wrote.
            try? FileManager.default.removeItem(at: destURL)
            return nil
        }
    }

    /// Convert any AVFoundation-readable audio file to 16kHz mono Float32 WAV
    /// at `dest`. Returns the destination's playback duration in seconds.
    private static func convertToCanonicalWAV(source: URL, dest: URL) throws -> TimeInterval {
        // Make sure the target dir exists.
        let dir = dest.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let inFile = try AVAudioFile(forReading: source)
        let inFormat = inFile.processingFormat
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "VoiceImport", code: 10, userInfo: [NSLocalizedDescriptionKey: "couldn't build 16kHz mono format"])
        }
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw NSError(domain: "VoiceImport", code: 11, userInfo: [NSLocalizedDescriptionKey: "no converter for \(inFormat) → \(outFormat)"])
        }

        // WAV file settings — Float32 PCM, 16kHz, 1 channel. Matches the live
        // recording writer in MeetingCaptureService.
        let outSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let outFile = try AVAudioFile(forWriting: dest, settings: outSettings, commonFormat: .pcmFormatFloat32, interleaved: false)

        // Stream in chunks so we don't OOM on long files (1-hour podcast).
        let bufFrames: AVAudioFrameCount = 16_000  // 1s of input per pull
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: bufFrames) else {
            throw NSError(domain: "VoiceImport", code: 12)
        }

        // Output capacity must cover the worst-case ratio (rare upsampling).
        let outCap = AVAudioFrameCount(Double(bufFrames) * (16_000.0 / max(inFormat.sampleRate, 1)) + 1_024)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCap) else {
            throw NSError(domain: "VoiceImport", code: 13)
        }

        var totalOutFrames: AVAudioFrameCount = 0
        var inputExhausted = false

        while !inputExhausted {
            var error: NSError?
            let status = converter.convert(to: outBuf, error: &error) { _, status in
                if inputExhausted {
                    status.pointee = .endOfStream
                    return nil
                }
                inBuf.frameLength = 0
                do {
                    try inFile.read(into: inBuf, frameCount: bufFrames)
                } catch {
                    status.pointee = .endOfStream
                    inputExhausted = true
                    return nil
                }
                if inBuf.frameLength == 0 {
                    status.pointee = .endOfStream
                    inputExhausted = true
                    return nil
                }
                status.pointee = .haveData
                return inBuf
            }
            if let error { throw error }
            if outBuf.frameLength > 0 {
                try outFile.write(from: outBuf)
                totalOutFrames += outBuf.frameLength
            }
            if status == .endOfStream { break }
        }

        return Double(totalOutFrames) / 16_000.0
    }

    // MARK: - Layer 0: Corrupt-meeting purge
    //
    // Runs BEFORE the orphan scan on launch. Sweeps both the audio directory
    // and the meetings table, deleting anything that's structurally garbage:
    //   - WAV files < 32KB (essentially empty, under ~1s of audio)
    //   - WAV files with broken header (missing RIFF / WAVE magic)
    //   - DB rows whose audio file is missing from disk
    //   - DB rows with kind=.meeting AND duration < 5s
    //   - DB rows with empty segments + no audio + older than 24h (unrecoverable)
    //
    // Safety guard: any file modified in the last 60 seconds is skipped —
    // it may belong to the active capture session.

    /// Sweep + delete corrupt meetings. Safe to call on launch before the
    /// orphan recovery scan. Honors the `voice.skipMeetingRecovery` escape
    /// hatch the same way every other recovery method does.
    func purgeCorruptMeetings() {
        if Self.skipRecoveryRequested {
            print("[VOICE-PURGE] skipped: \(Self.skipRecoveryDefaultsKey) is set")
            return
        }

        let fm = FileManager.default
        let dir = Self.meetingAudioDirectory
        let now = Date()
        let recentCutoff = now.addingTimeInterval(-60)  // never touch files modified in last 60s

        // Track reasons for the summary log line.
        var deletedTooSmall = 0
        var deletedBadHeader = 0
        var deletedMissingAudio = 0
        var deletedTooShort = 0
        var deletedOrphanedRow = 0

        // Snapshot the DB once — we need both the row → path map (to detect
        // disk files belonging to a known row) and the row list (to evaluate
        // each row against the corruption rules).
        let meetings: [Meeting]
        do {
            meetings = try storage.fetchAllMeetings()
        } catch {
            print("[VOICE-PURGE] couldn't fetch meetings: \(error) — aborting purge")
            return
        }
        // path → meeting row map for fast lookup when we delete a bad file.
        var rowByPath: [String: Meeting] = [:]
        for m in meetings {
            if let p = m.audioFilePath { rowByPath[p] = m }
        }

        // ---------- Pass 1: scan files on disk ----------
        let entries = (try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for url in entries {
            let name = url.lastPathComponent
            // Only inspect meeting-*.wav files. Leave .caf files alone — those
            // were produced by an older capture path and we don't want to delete
            // historical artifacts that might still play back.
            guard name.hasPrefix("meeting-"), name.hasSuffix(".wav") else { continue }

            let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modified = attrs?.contentModificationDate ?? now
            let size = Int64(attrs?.fileSize ?? 0)

            // Safety guard — never delete a file modified in the last 60s.
            if modified > recentCutoff {
                continue
            }

            var deleteReason: String? = nil

            if size < 32_768 {
                deleteReason = "tooSmall"
            } else if !Self.hasValidWavHeader(url: url) {
                deleteReason = "badHeader"
            }

            guard let reason = deleteReason else { continue }

            // Delete the file. Also delete the DB row if one is pointing at it.
            do {
                try fm.removeItem(at: url)
                if reason == "tooSmall" { deletedTooSmall += 1 } else { deletedBadHeader += 1 }
                print("[VOICE-PURGE] deleted file (\(reason), \(size) bytes): \(name)")
                if let row = rowByPath[url.path] {
                    do {
                        try storage.deleteMeeting(id: row.id)
                        print("[VOICE-PURGE] also deleted DB row for \(row.id)")
                    } catch {
                        print("[VOICE-PURGE] couldn't delete DB row for \(row.id): \(error)")
                    }
                    rowByPath.removeValue(forKey: url.path)
                }
            } catch {
                print("[VOICE-PURGE] couldn't delete \(name): \(error)")
            }
        }

        // ---------- Pass 2: scan DB rows ----------
        // Re-fetch so we're not iterating over rows we just nuked above.
        let liveMeetings: [Meeting]
        do {
            liveMeetings = try storage.fetchAllMeetings()
        } catch {
            print("[VOICE-PURGE] couldn't re-fetch meetings: \(error) — aborting pass 2")
            return
        }

        for m in liveMeetings {
            // Rule: row references an audio file that no longer exists on disk.
            //       (Skip rows with nil audio — those fall to the orphan-row rule below.)
            if let path = m.audioFilePath {
                if !fm.fileExists(atPath: path) {
                    // Safety: if the row was created in the last 60s, leave it
                    // alone — the writer may still be flushing the file.
                    if now.timeIntervalSince(m.date) < 60 { continue }
                    do {
                        try storage.deleteMeeting(id: m.id)
                        deletedMissingAudio += 1
                        print("[VOICE-PURGE] deleted DB row \(m.id) — audio missing: \(path)")
                    } catch {
                        print("[VOICE-PURGE] couldn't delete row \(m.id): \(error)")
                    }
                    continue
                }
            }

            // Rule: row with kind == .meeting AND duration < 5s — literal garbage.
            if m.kind == .meeting && m.duration < 5 {
                if now.timeIntervalSince(m.date) < 60 { continue }
                do {
                    // Also delete the audio file if it exists (we know it's <5s).
                    if let path = m.audioFilePath {
                        try? fm.removeItem(atPath: path)
                    }
                    try storage.deleteMeeting(id: m.id)
                    deletedTooShort += 1
                    print("[VOICE-PURGE] deleted DB row \(m.id) — meeting under 5s (\(m.duration)s)")
                } catch {
                    print("[VOICE-PURGE] couldn't delete row \(m.id): \(error)")
                }
                continue
            }

            // Rule: empty/nil transcript AND createdAt > 24h ago AND no audio.
            let transcriptEmpty = m.segments.isEmpty
            let olderThan24h = now.timeIntervalSince(m.date) > 86_400
            let hasNoAudio = (m.audioFilePath == nil) || !(m.audioFilePath.map { fm.fileExists(atPath: $0) } ?? false)
            if transcriptEmpty && olderThan24h && hasNoAudio {
                do {
                    try storage.deleteMeeting(id: m.id)
                    deletedOrphanedRow += 1
                    print("[VOICE-PURGE] deleted DB row \(m.id) — empty transcript, no audio, >24h old")
                } catch {
                    print("[VOICE-PURGE] couldn't delete row \(m.id): \(error)")
                }
            }
        }

        let total = deletedTooSmall + deletedBadHeader + deletedMissingAudio + deletedTooShort + deletedOrphanedRow
        var reasons: [String] = []
        if deletedTooSmall > 0      { reasons.append("tooSmall=\(deletedTooSmall)") }
        if deletedBadHeader > 0     { reasons.append("badHeader=\(deletedBadHeader)") }
        if deletedMissingAudio > 0  { reasons.append("missingAudio=\(deletedMissingAudio)") }
        if deletedTooShort > 0      { reasons.append("tooShort=\(deletedTooShort)") }
        if deletedOrphanedRow > 0   { reasons.append("orphanedRow=\(deletedOrphanedRow)") }
        let reasonStr = reasons.isEmpty ? "none" : reasons.joined(separator: ", ")
        print("[VOICE-PURGE] deleted \(total) corrupt meetings: \(reasonStr)")
    }

    /// One-shot dedup pass over the existing meetings table. Catches the
    /// duplicates that slipped through before save-time dedup landed. Two
    /// heuristics, ordered by confidence:
    ///
    ///   1. SAME audioFilePath under two ids → keep the winner, delete the
    ///      loser. Winner: most segments → longest duration → newest date.
    ///   2. SAME sourceApp, dates within 30s → merge: union the segments,
    ///      keep the longer duration, keep the better summary, delete the
    ///      loser. Same winner-pick rule.
    ///
    /// Both rules safeguard against destroying a currently-recording row
    /// (skips anything dated within the last 60s). Every action logs under
    /// [VOICE-DEDUP] so the reason is greppable post-mortem.
    ///
    /// Returns the number of rows that were deleted (so the launch path can
    /// surface a toast if anything was cleaned up).
    @discardableResult
    func dedupeMeetings() -> Int {
        if Self.skipRecoveryRequested {
            print("[VOICE-DEDUP] skipped: \(Self.skipRecoveryDefaultsKey) is set")
            return 0
        }

        // Snapshot the DB once. Mutations happen via storage.saveMeeting /
        // deleteMeeting, which is fine because we're operating against a
        // local copy and the table mutates a row at a time.
        let snapshot: [Meeting]
        do {
            snapshot = try storage.fetchAllMeetings()
        } catch {
            print("[VOICE-DEDUP] couldn't fetch meetings: \(error) — aborting")
            return 0
        }

        let now = Date()
        let liveCutoff = now.addingTimeInterval(-60)  // skip rows from the active session

        // Helper: pick the "winner" of a duplicate set. Returns the row to
        // keep + the rows to drop. More segments wins; ties on segments
        // break by longer duration; final tiebreak is the newer date.
        func chooseWinner(_ rows: [Meeting]) -> (keep: Meeting, drop: [Meeting]) {
            let sorted = rows.sorted { a, b in
                if a.segments.count != b.segments.count {
                    return a.segments.count > b.segments.count
                }
                if a.duration != b.duration {
                    return a.duration > b.duration
                }
                return a.date > b.date
            }
            return (sorted[0], Array(sorted.dropFirst()))
        }

        var deleted = 0
        var processed = Set<UUID>()  // already handled by an earlier group

        // ---------- Rule 1: same audioFilePath ----------
        // Group rows by path (skipping nil/empty). Anything with >= 2 rows in
        // the bucket is a duplicate.
        var byPath: [String: [Meeting]] = [:]
        for m in snapshot {
            // Defensive: skip in-flight rows so we never blow away the
            // currently-recording meeting.
            guard now.timeIntervalSince(m.date) >= 60 else { continue }
            guard let path = m.audioFilePath, !path.isEmpty else { continue }
            byPath[path, default: []].append(m)
        }
        for (path, group) in byPath where group.count > 1 {
            let (winner, losers) = chooseWinner(group)
            for loser in losers {
                processed.insert(loser.id)
                do {
                    // Don't delete the file — winner still references it.
                    // We need to delete just the DB row, not the audio.
                    // StorageService.deleteMeeting deletes both, so we go
                    // direct to a row-only delete via a temporary alias:
                    try deleteMeetingRowOnly(id: loser.id)
                    deleted += 1
                    print("[VOICE-DEDUP] merged meeting \(loser.id) into \(winner.id) (reason: shared audioFilePath \(path))")
                } catch {
                    print("[VOICE-DEDUP] couldn't delete loser \(loser.id): \(error)")
                }
            }
            // Record winner as already-processed so rule 2 doesn't fire on it again.
            processed.insert(winner.id)
        }

        // ---------- Rule 2: same sourceApp + within 30s ----------
        // Sort meetings by date and walk forward, grouping any rows whose
        // (sourceApp, date) puts them within 30s of a non-empty preceding
        // group's earliest member. Tight enough to catch double-fires but
        // loose enough to skip back-to-back genuine meetings.
        let chronological = snapshot
            .filter { now.timeIntervalSince($0.date) >= 60 }
            .filter { !processed.contains($0.id) }
            .filter { ($0.sourceApp ?? "").isEmpty == false }
            .sorted { $0.date < $1.date }

        var groups: [[Meeting]] = []
        for m in chronological {
            if let last = groups.last,
               let anchor = last.first,
               anchor.sourceApp == m.sourceApp,
               m.date.timeIntervalSince(anchor.date) <= 30 {
                groups[groups.count - 1].append(m)
            } else {
                groups.append([m])
            }
        }

        for group in groups where group.count > 1 {
            let (winner, losers) = chooseWinner(group)
            // Merge: union segments from losers into a fresh copy of the
            // winner so transcript coverage isn't lost. Duration takes the
            // longer of the two. Summary keeps whichever was non-nil (winner
            // first by virtue of `chooseWinner`'s preference).
            var merged = winner
            var seenSegmentIds = Set(merged.segments.map(\.id))
            for loser in losers {
                processed.insert(loser.id)
                for s in loser.segments where !seenSegmentIds.contains(s.id) {
                    merged.segments.append(s)
                    seenSegmentIds.insert(s.id)
                }
                if loser.duration > merged.duration { merged.duration = loser.duration }
                if merged.summary == nil, let s = loser.summary { merged.summary = s }
                // Union participant names (winner first).
                let existing = Set(merged.participantNames.map { $0.lowercased() })
                for name in loser.participantNames {
                    if !existing.contains(name.lowercased()) {
                        merged.participantNames.append(name)
                    }
                }
            }
            // Re-sort merged segments chronologically.
            merged.segments.sort { $0.startTime < $1.startTime }

            do {
                try storage.saveMeeting(merged)
                for loser in losers {
                    do {
                        try deleteMeetingRowOnly(id: loser.id)
                        deleted += 1
                        let app = winner.sourceApp ?? "?"
                        print("[VOICE-DEDUP] merged meeting \(loser.id) into \(winner.id) (reason: <30s gap, sourceApp=\(app))")
                    } catch {
                        print("[VOICE-DEDUP] couldn't delete loser \(loser.id): \(error)")
                    }
                }
            } catch {
                print("[VOICE-DEDUP] save of merged \(winner.id) failed: \(error)")
            }
        }

        if deleted == 0 {
            print("[VOICE-DEDUP] no duplicates found")
        } else {
            print("[VOICE-DEDUP] removed \(deleted) duplicate meeting row(s)")
        }
        return deleted
    }

    /// Drop just the meetings row (cascades to segments/summary via FK) but
    /// leave the audio file on disk — used by dedup so the winner row still
    /// has its WAV.
    private func deleteMeetingRowOnly(id: UUID) throws {
        try storage.deleteMeetingRowKeepingAudio(id: id)
    }

    /// Validate a WAV file's RIFF/WAVE magic. Reads only the first 12 bytes —
    /// cheap even for huge files. Returns false on any IO error or mismatch.
    private static func hasValidWavHeader(url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let data: Data
        do {
            data = try handle.read(upToCount: 12) ?? Data()
        } catch {
            return false
        }
        guard data.count >= 12 else { return false }
        // Bytes 0..3 must be "RIFF", bytes 8..11 must be "WAVE".
        let riff = data.subdata(in: 0..<4)
        let wave = data.subdata(in: 8..<12)
        return riff == Data([0x52, 0x49, 0x46, 0x46])     // "RIFF"
            && wave == Data([0x57, 0x41, 0x56, 0x45])     // "WAVE"
    }

    // MARK: - Layer 1: Orphan scan

    /// Find every meeting-*.wav file on disk whose path isn't referenced
    /// from any Meeting row in the DB. These are crash survivors.
    ///
    /// Safety guards (all of which must hold before recovery touches anything):
    ///   - `voice.skipMeetingRecovery` UserDefaults flag is false
    ///   - file's modification date is at least `recoveryMinAgeSeconds` older
    ///     than `launchTime` (so live-session files are never treated as orphans)
    func discoverOrphanedMeetingAudio() -> [OrphanedMeetingAudio] {
        // Emergency escape hatch — user can disable recovery entirely.
        if Self.skipRecoveryRequested {
            print("[VOICE-RECOVERY] skipped: \(Self.skipRecoveryDefaultsKey) is set")
            return []
        }

        let fm = FileManager.default
        let dir = Self.meetingAudioDirectory
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            print("[VOICE-RECOVERY] audio dir not readable at \(dir.path)")
            return []
        }

        // Files modified AFTER this cutoff belong to the current session and
        // must not be treated as orphans. We use launchTime - 30s so a capture
        // that started a few seconds before recovery ran is still excluded.
        let recencyCutoff = launchTime.addingTimeInterval(-Self.recoveryMinAgeSeconds)

        // Build a set of paths already known to the DB.
        let known: Set<String>
        do {
            let meetings = try storage.fetchAllMeetings()
            known = Set(meetings.compactMap { $0.audioFilePath })
        } catch {
            print("[VOICE-RECOVERY] couldn't fetch meetings for orphan compare: \(error)")
            return []
        }

        var orphans: [OrphanedMeetingAudio] = []
        for url in entries {
            let name = url.lastPathComponent
            guard name.hasPrefix("meeting-"),
                  name.hasSuffix(".wav") || name.hasSuffix(".caf")
            else { continue }

            if known.contains(url.path) { continue }

            let attrs = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey])
            let created = attrs?.creationDate ?? Date()
            let modified = attrs?.contentModificationDate ?? created
            let size = Int64(attrs?.fileSize ?? 0)

            // Skip files that belong to the current session. A file modified
            // after (launchTime - 30s) is either being written right now or
            // was created since launch — either way recovery has no business
            // touching it.
            if modified > recencyCutoff {
                print("[VOICE-RECOVERY] skipping live-session file: \(name) (modified \(modified))")
                continue
            }

            // Skip empty / header-only files. AVAudioFile writes a 44-byte
            // RIFF header at open; anything below ~1KB is effectively empty.
            guard size > 1024 else {
                print("[VOICE-RECOVERY] skipping empty orphan: \(name) (\(size) bytes)")
                continue
            }

            // Best-effort duration probe. afinfo or AVAudioFile both work; we
            // use AVAudioFile because we already depend on it. Falls back to
            // 0 if the header is bad (file written before close completed).
            var duration: TimeInterval = 0
            if let file = try? AVAudioFile(forReading: url) {
                duration = Double(file.length) / file.fileFormat.sampleRate
            }

            orphans.append(OrphanedMeetingAudio(
                id: UUID(),
                audioFileURL: url,
                createdAt: created,
                durationSeconds: duration,
                sizeBytes: size
            ))
        }

        // Newest first — most likely to be the one the user just lost.
        orphans.sort { $0.createdAt > $1.createdAt }

        print("[VOICE-RECOVERY] found \(orphans.count) orphaned meeting audio file(s)")
        return orphans
    }

    /// Auto-import an orphan: create a Meeting row pointing at the WAV with
    /// segments=[] (caller can run `retranscribe` later). Title gets a clear
    /// "(Recovered)" suffix so the user knows it came back from the dead.
    func importOrphan(_ orphan: OrphanedMeetingAudio) {
        if Self.skipRecoveryRequested {
            print("[VOICE-RECOVERY] importOrphan skipped: \(Self.skipRecoveryDefaultsKey) is set")
            return
        }
        let title = "Recovered meeting — \(Self.shortDate(orphan.createdAt))"
        let meeting = Meeting(
            id: orphan.id,
            title: title,
            date: orphan.createdAt,
            duration: orphan.durationSeconds,
            segments: [],
            audioFilePath: orphan.audioFileURL.path,
            // Honor the 3-minute threshold: anything shorter is a dictation,
            // not a meeting. Long dictations were being misclassified as
            // meetings because this used to hardcode .meeting.
            kind: orphan.durationSeconds >= 300 ? .meeting : .dictation
        )
        do {
            try storage.saveMeeting(meeting)
            print("[VOICE-RECOVERY] imported orphan as Meeting \(meeting.id) (\(Int(orphan.durationSeconds))s)")
        } catch {
            print("[VOICE-RECOVERY] importOrphan save failed: \(error)")
        }
    }

    // MARK: - Layer 2: Re-transcribe from saved audio

    /// Replace `meeting.segments` with a freshly-computed transcript from
    /// `meeting.audioFilePath`, run speaker diarization on the audio, merge
    /// in any Chrome-extension active-speaker events (named participants),
    /// and derive a clean human-readable title from the transcript content.
    /// Errors are logged but never thrown — caller gets `nil`.
    func retranscribe(meeting: Meeting) async -> Meeting? {
        guard let path = meeting.audioFilePath,
              FileManager.default.fileExists(atPath: path)
        else {
            print("[VOICE-RECOVERY] retranscribe: no audio file for \(meeting.id)")
            return nil
        }
        let url = URL(fileURLWithPath: path)
        do {
            print("[VOICE-RECOVERY] retranscribing \(url.lastPathComponent)…")
            // 1. Transcribe via Parakeet. We chunk the file ourselves into
            //    ~30s windows and call transcribe(audioChunk:) per window,
            //    so we get ONE segment per window instead of the single
            //    mega-segment that transcribeFile would return for a long
            //    file. Per-window segments are what makes diarization-by-
            //    midpoint actually useful.
            let segments = try await chunkAndTranscribe(url: url)

            // 2. Run audio-based diarization on the full WAV. The diarizer
            //    returns DiarizedTurn intervals with stable voice IDs.
            //    Failure is non-fatal — falls back to single-speaker labeling.
            let diarizer = SpeakerDiarizer()
            await diarizer.reset()
            let audioSamples: [Float]
            do {
                audioSamples = try Self.readSamplesAt16kMono(url: url)
            } catch {
                print("[VOICE-RECOVERY] couldn't read samples for diarization: \(error) — labeling all segments as MEETING")
                return await saveWithFallbackLabels(meeting: meeting, segments: segments)
            }
            let turns = await diarizer.diarize(samples: audioSamples, sampleRate: 16_000)
            print("[VOICE-RECOVERY] diarizer found \(turns.count) speaker turn(s)")

            // 3. Build a voiceID → display name map. Chrome ext names (if
            //    available in meeting.speakerEventsJson) take precedence;
            //    otherwise we use "Speaker 1", "Speaker 2", ...
            //
            //    Self-filtering: the LOCAL user's name (from
            //    UserDefaults["voice.userName"], default "Michael") gets the
            //    "You" label so the transcript reads "You: …" instead of the
            //    user's own name beside other speakers' real names.
            let chromeEvents = Self.decodeSpeakerEvents(meeting.speakerEventsJson)
            let me = (UserDefaults.standard.string(forKey: "voice.userName") ?? "")
                .trimmingCharacters(in: .whitespaces)
            var voiceToName: [Int: String] = [:]
            for turn in turns {
                if voiceToName[turn.voiceID] != nil { continue }
                let turnMidAbs = meeting.date.addingTimeInterval((turn.startTime + turn.endTime) / 2.0)
                if let name = Self.chromeNameAt(turnMidAbs, in: chromeEvents) {
                    // Rewrite self → "You" so the user sees their own
                    // turns as "You" instead of "Michael".
                    if !me.isEmpty, name.caseInsensitiveCompare(me) == .orderedSame {
                        voiceToName[turn.voiceID] = "You"
                    } else {
                        voiceToName[turn.voiceID] = name
                    }
                } else {
                    voiceToName[turn.voiceID] = "Speaker \(turn.voiceID + 1)"
                }
            }

            // 4. Tag each transcript segment with the speaker whose diarized
            //    turn contains the segment's midpoint. When the midpoint
            //    doesn't fall inside any turn (gap between turns, overlap
            //    zone, padding at edges), fall back to the CLOSEST turn —
            //    most segments still belong to a real speaker; using a
            //    generic "Speaker" label drops information. Chrome timeline
            //    is the final fallback when no diarized turn is anywhere
            //    nearby.
            let tagged = segments.map { seg -> TranscriptSegment in
                let mid = (seg.startTime + seg.endTime) / 2.0
                var s = seg
                if let turn = turns.first(where: { $0.startTime <= mid && mid <= $0.endTime }) {
                    s.speaker = voiceToName[turn.voiceID] ?? "Speaker \(turn.voiceID + 1)"
                    s.speakerId = "voice_\(turn.voiceID)"
                } else if let nearest = Self.nearestTurn(to: mid, in: turns), nearest.distance < 5.0 {
                    // Closest turn within 5s — better than going generic.
                    s.speaker = voiceToName[nearest.turn.voiceID] ?? "Speaker \(nearest.turn.voiceID + 1)"
                    s.speakerId = "voice_\(nearest.turn.voiceID)"
                } else {
                    let absMid = meeting.date.addingTimeInterval(mid)
                    if let chromeName = Self.chromeNameAt(absMid, in: chromeEvents) {
                        s.speaker = chromeName
                    } else {
                        s.speaker = "Speaker"
                    }
                }
                return s
            }

            // 5. Provisional title from the transcript content — used as
            //    input context for the summary generator.
            let provisionalTitle = Self.deriveMeetingTitle(
                segments: tagged,
                participantNames: meeting.participantNames,
                date: meeting.date,
                sourceApp: meeting.sourceApp,
                currentTitle: meeting.title
            )

            // 6. Generate an LLM-powered summary via Cerebras (overview,
            //    decisions, action items, open questions). Cheap fail-safe:
            //    if Cerebras is offline / rate-limited / API key missing,
            //    just skip the summary — transcript is still saved.
            let summary = await Self.generateSummary(
                segments: tagged,
                title: provisionalTitle,
                participants: meeting.participantNames
            )

            // 7. Final title — if Cerebras gave us a summary, generate a real
            //    title from it; otherwise fall back to the provisional one.
            //    LLM titles read like "Meta ad strategy for pain cream" instead
            //    of "Hello, hello. Hey, Matt. How you doing?…"
            let derivedTitle: String
            if let summary, !summary.overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                derivedTitle = await Self.generateTitle(overview: summary.overview, date: meeting.date, participants: meeting.participantNames) ?? provisionalTitle
            } else {
                derivedTitle = provisionalTitle
            }

            var updated = meeting
            updated.segments = tagged
            updated.title = derivedTitle
            if let summary = summary { updated.summary = summary }
            if updated.duration <= 0, let last = tagged.last {
                updated.duration = last.endTime
            }
            try storage.saveMeeting(updated)
            let speakerCount = Set(tagged.map(\.speaker)).count
            print("[VOICE-RECOVERY] retranscribe done — \(tagged.count) segments, \(speakerCount) speaker(s), summary=\(summary != nil), \"\(derivedTitle)\"")
            return updated
        } catch {
            print("[VOICE-RECOVERY] retranscribe failed for \(meeting.id): \(error)")
            return nil
        }
    }

    // MARK: - retranscribe helpers

    /// Chunk a WAV/CAF into overlapping ~30s windows and run Parakeet on each.
    /// Returns per-window TranscriptSegments with proper session-relative times,
    /// with boundary text deduplicated so the same audio doesn't appear twice.
    ///
    /// ## Why chunk here (vs. letting `transcribeFile` handle it):
    /// `transcribeFile` returns a single mega-segment for long inputs — useless
    /// for diarization, which assigns ONE speaker per segment via midpoint
    /// lookup. Splitting into ~30s windows means a 60-minute meeting becomes
    /// ~120 segments, each landing in the right speaker turn.
    ///
    /// ## Why overlap (vs. a clean stride):
    /// Without overlap, Parakeet gets cold acoustic context at the chunk start
    /// and tail and mis-decodes the boundary words. The classic failure mode:
    /// "the proj... ect timeline" because chunk N cut off "project" mid-word
    /// and chunk N+1 started after "j". With a 3s overlap, the boundary words
    /// appear in BOTH chunks — neither decoding had to guess what came next,
    /// so at least one side gets the words right. We then dedupe at stitch
    /// time, preferring the higher-confidence chunk's copy of the overlap.
    ///
    /// ## How the dedup works:
    /// For each adjacent chunk pair (L, R), search for the longest word-level
    /// suffix-of-L that matches a word-level prefix-of-R (case-insensitive,
    /// punctuation-stripped). The overlap window caps at ~14 words (≈3s of
    /// normal speech). The higher-confidence chunk's copy wins; the loser's
    /// duplicate is dropped. This is the same algorithm
    /// `TranscriptionService.chunkedTranscribe` uses inside Parakeet's own
    /// ~15s windows — proven against the original boundary-merge bug.
    ///
    /// Speaker stability is NOT handled here — the diarizer (called once
    /// over the FULL audio in `retranscribe`) already maintains a persistent
    /// SpeakerManager so voice IDs are stable across the whole meeting.
    private func chunkAndTranscribe(url: URL) async throws -> [TranscriptSegment] {
        let samples = try Self.readSamplesAt16kMono(url: url)
        guard !samples.isEmpty else { return [] }

        let sampleRate: Double = 16_000
        let chunkSamples = Int(sampleRate * 30)        // 30s window (decode budget)
        let strideSamples = Int(sampleRate * 27)       //  3s overlap between neighbors
        let overlapSeconds = 3.0
        // ~4 words/sec on normal English speech; 14 caps false-positive overlap matches.
        let overlapWordBudget = Int(overlapSeconds * 4) + 2

        // Collect raw per-chunk outputs first. We need both sides of every
        // seam in memory to do confidence-weighted dedup, so accumulate
        // everything before emitting final TranscriptSegments.
        struct ChunkOut {
            let index: Int
            let startTime: TimeInterval
            let endTime: TimeInterval
            var segment: TranscriptSegment      // mutable so we can edit text after merge
        }
        var rawChunks: [ChunkOut] = []
        var offset = 0
        var index = 0
        while offset < samples.count {
            let end = min(offset + chunkSamples, samples.count)
            let slice = Array(samples[offset..<end])
            let startTime = Double(offset) / sampleRate
            let endTime = Double(end) / sampleRate
            // Skip windows that are < 1.5s — Parakeet won't decode them well.
            if slice.count >= Int(sampleRate * 1.5) {
                do {
                    let segs = try await transcription.transcribe(
                        audioChunk: slice,
                        chunkStartTime: startTime
                    )
                    // `transcribe(audioChunk:)` returns ONE coarse segment per
                    // call (one TranscriptSegment spanning the whole window
                    // with concatenated text). If FluidAudio ever changes that
                    // we still defensively join all returned segments by space.
                    let joinedText = segs
                        .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                    if !joinedText.isEmpty {
                        // Average confidence across the returned pieces; nil
                        // if none reported one.
                        let confs = segs.compactMap { $0.confidence }
                        let avgConf: Float? = confs.isEmpty
                            ? nil
                            : confs.reduce(0, +) / Float(confs.count)
                        let representative = TranscriptSegment(
                            id: segs.first?.id ?? UUID(),
                            speaker: "Speaker 1",                // overwritten by diarization later
                            speakerId: segs.first?.speakerId,
                            text: joinedText,
                            startTime: startTime,
                            endTime: min(endTime, segs.last?.endTime ?? endTime),
                            confidence: avgConf,
                            isFinal: true,
                            suspectWords: segs.first?.suspectWords
                        )
                        rawChunks.append(ChunkOut(
                            index: index,
                            startTime: startTime,
                            endTime: endTime,
                            segment: representative
                        ))
                    }
                } catch {
                    print("[VOICE-RECOVERY] chunk \(index) failed (continuing): \(error.localizedDescription)")
                }
            }
            // Advance by stride to overlap with the next window. When we've
            // reached the end of the file, break — no point starting another
            // window that would just re-decode samples we already covered.
            if end == samples.count { break }
            offset += strideSamples
            // Safety net for pathological stride/chunkSamples combos.
            if offset >= samples.count { break }
            index += 1
        }

        // Walk pairs of adjacent chunks and dedupe their overlap region.
        // For each seam, the higher-confidence chunk's copy wins; we trim
        // the duplicate from the loser. Trimming the LEFT chunk means
        // dropping its suffix; trimming the RIGHT chunk means dropping
        // its prefix. Either way the spoken audio appears in the final
        // transcript exactly once.
        if rawChunks.count >= 2 {
            for i in 1..<rawChunks.count {
                let leftText = rawChunks[i - 1].segment.text
                let rightText = rawChunks[i].segment.text
                let leftConf = rawChunks[i - 1].segment.confidence ?? 0
                let rightConf = rawChunks[i].segment.confidence ?? 0
                let result = Self.dedupOverlap(
                    left: leftText,
                    right: rightText,
                    leftConf: leftConf,
                    rightConf: rightConf,
                    maxWords: overlapWordBudget
                )
                rawChunks[i - 1].segment.text = result.left
                rawChunks[i].segment.text = result.right
                if result.matchedWords > 0 {
                    print(
                        "[VOICE-RECOVERY] seam \(i - 1)→\(i): "
                        + "kept=\(result.keptSide) words=\(result.matchedWords) "
                        + "confL=\(String(format: "%.3f", leftConf)) "
                        + "confR=\(String(format: "%.3f", rightConf))"
                    )
                }
            }
        }

        // Final pass: assemble TranscriptSegments and drop anything that ended
        // up empty after dedup (rare — happens when one chunk was entirely
        // covered by the other's higher-confidence copy of the same audio).
        var out: [TranscriptSegment] = []
        out.reserveCapacity(rawChunks.count)
        for chunk in rawChunks {
            let cleaned = chunk.segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty { continue }
            var seg = chunk.segment
            seg.text = cleaned
            // Keep the window's wall-clock bounds. Midpoint-based diarization
            // doesn't care about a few seconds of slack at the edges; the
            // important property is that each segment's midpoint sits in
            // the middle of the audio it transcribes, far from any seam.
            seg.startTime = chunk.startTime
            seg.endTime = min(chunk.endTime, Double(samples.count) / sampleRate)
            out.append(seg)
        }
        print("[VOICE-RECOVERY] chunkAndTranscribe → \(out.count) segments across \(rawChunks.count) windows (stride=\(strideSamples / Int(sampleRate))s overlap=\(Int(overlapSeconds))s)")
        return out
    }

    /// Find the longest word-level overlap at the L-suffix / R-prefix seam
    /// and trim it from the lower-confidence side. Returns the trimmed
    /// strings plus a tag for which side kept the overlap and how many
    /// words matched ("none"/0 when no overlap was detectable).
    ///
    /// Match rules (mirroring `TranscriptionService.mergeByWordOverlap`):
    ///   - case-insensitive, with punctuation stripped at the match step
    ///   - at least 2 consecutive matching words
    ///   - >= 75% words agree across the candidate window
    ///   - first AND last word of the window agree (anchors prevent drift)
    ///
    /// When no overlap is detected we leave both sides untouched — the
    /// audio probably DID change at the boundary (silence, speaker swap,
    /// or one of the chunks mis-decoded badly enough that we can't find
    /// a match). False-negative is preferable to false-positive here:
    /// dropping non-overlapping content would lose user speech.
    ///
    /// ## Word-split repair
    /// One specific failure mode this also catches: a word split across
    /// the seam ("the proj" + "ect timeline"). The overlap match won't
    /// fire on "proj"/"ect" because they're different words, but the
    /// 3-second acoustic overlap above this means BOTH chunks should
    /// have decoded "project" fully — we just keep the version from the
    /// higher-confidence side. (If somehow neither side got the full
    /// word, that's a transcription failure we can't fix in stitching.)
    private static func dedupOverlap(
        left: String,
        right: String,
        leftConf: Float,
        rightConf: Float,
        maxWords: Int
    ) -> (left: String, right: String, keptSide: String, matchedWords: Int) {
        let lWords = left.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let rWords = right.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !lWords.isEmpty, !rWords.isEmpty else {
            return (left, right, "none", 0)
        }

        // Normalize for comparison: lowercase, drop trailing punctuation.
        // Mid-word punctuation (don't, well-known) stays untouched so we
        // don't merge "don't" with "dont" — that's the right call: those
        // are different surface forms even if they sound the same.
        let trailingPunct = CharacterSet.punctuationCharacters
        let norm: (String) -> String = { s in
            s.lowercased().trimmingCharacters(in: trailingPunct)
        }

        let maxK = min(maxWords, lWords.count, rWords.count)
        var bestK = 0
        let minK = 2     // require at least 2 consecutive matching words
        if maxK >= minK {
            for k in stride(from: maxK, through: minK, by: -1) {
                let lTail = lWords.suffix(k).map(norm)
                let rHead = rWords.prefix(k).map(norm)
                var hits = 0
                for j in 0..<k where lTail[j] == rHead[j] { hits += 1 }
                let ratio = Double(hits) / Double(k)
                // First + last anchors keep us from matching mid-overlap
                // coincidences (e.g. "the" appearing on both sides by chance).
                if ratio >= 0.75 && lTail.first == rHead.first && lTail.last == rHead.last {
                    bestK = k
                    break
                }
            }
        }

        if bestK == 0 {
            return (left, right, "none", 0)
        }

        // Higher-confidence side keeps its copy of the overlap region; the
        // other side gets the overlap trimmed from its boundary. Ties go to
        // the LEFT chunk (arbitrary but stable — and the left chunk's tail
        // tends to have slightly more LM context than the right's head).
        if leftConf >= rightConf {
            // L keeps the overlap; drop R's prefix of `bestK` words.
            let rTrimmed = rWords.dropFirst(bestK).joined(separator: " ")
            return (left, rTrimmed, "left", bestK)
        } else {
            // R keeps the overlap; drop L's suffix of `bestK` words.
            let lTrimmed = lWords.dropLast(bestK).joined(separator: " ")
            return (lTrimmed, right, "right", bestK)
        }
    }

    /// Last-resort save path: transcription worked but diarization couldn't
    /// even read samples. All segments get a generic "MEETING" label.
    private func saveWithFallbackLabels(meeting: Meeting, segments: [TranscriptSegment]) async -> Meeting? {
        let tagged = segments.map { seg -> TranscriptSegment in
            var s = seg
            s.speaker = "Speaker"
            return s
        }
        var updated = meeting
        updated.segments = tagged
        updated.title = Self.deriveMeetingTitle(
            segments: tagged,
            participantNames: meeting.participantNames,
            date: meeting.date,
            sourceApp: meeting.sourceApp,
            currentTitle: meeting.title
        )
        if updated.duration <= 0, let last = tagged.last {
            updated.duration = last.endTime
        }
        do {
            try storage.saveMeeting(updated)
            return updated
        } catch {
            print("[VOICE-RECOVERY] fallback save failed: \(error)")
            return nil
        }
    }

    /// Find the diarized turn whose interval is closest (by gap, not
    /// containment) to a given session-relative time. Returns the turn plus
    /// the gap distance in seconds. Used for "no turn contains this
    /// timestamp but there's one right next to it" labeling.
    private static func nearestTurn(to t: TimeInterval, in turns: [DiarizedTurn]) -> (turn: DiarizedTurn, distance: TimeInterval)? {
        var best: (DiarizedTurn, TimeInterval)? = nil
        for turn in turns {
            let dist: TimeInterval
            if t < turn.startTime { dist = turn.startTime - t }
            else if t > turn.endTime { dist = t - turn.endTime }
            else { dist = 0 }
            if best == nil || dist < best!.1 { best = (turn, dist) }
        }
        return best
    }

    /// Ask Cerebras for a short human title given the meeting overview.
    /// Returns a one-line title (~40 chars) suitable for a meeting list
    /// entry, with the date appended.
    /// Generate a clean, pure-topic title from the overview. NO date suffix
    /// (the row already shows the date in metadata). Returns nil on Cerebras
    /// failure — caller falls back to a date-bucket placeholder.
    static func generateTitle(overview: String, date: Date, participants: [String] = []) async -> String? {
        // Filter out the local user from the participants list so the
        // "others on the call" count drives the naming policy correctly.
        // The Chrome scrape sometimes includes the user, sometimes not,
        // depending on platform — normalize here.
        let me = (UserDefaults.standard.string(forKey: "voice.userName") ?? "")
            .trimmingCharacters(in: .whitespaces)
        let others = participants
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .filter { me.isEmpty || $0.caseInsensitiveCompare(me) != .orderedSame }
        let otherCount = others.count

        // Pick the participant-policy block based on how many OTHER people
        // were on the call. The bucket boundaries (1, 2-4, 5+) drive both
        // the prompt's instructions and what we surface to the model.
        let participantPolicy: String
        switch otherCount {
        case 0:
            participantPolicy = """
            # Participants
            No other named participants were captured for this meeting. Use a topic-only title. Do not invent names.
            """
        case 1:
            participantPolicy = """
            # Participants (MANDATORY NAME INCLUSION)
            Exactly ONE other person was on this call: \(others[0]).
            You MUST include "\(others[0])" in the title. This is not optional.
            Examples of the shape we want:
            - "\(others[0]) promotion 1:1"
            - "Promotion talk with \(others[0])"
            - "\(others[0]) onboarding plan"
            - "Pricing pushback from \(others[0])"
            Lead with the most concrete topic the two of you discussed and pair it with their name. Stay within 3-6 words and 50 chars.
            """
        case 2, 3, 4:
            let joined = others.joined(separator: ", ")
            participantPolicy = """
            # Participants (small group: 2-4 others)
            Others on the call: \(joined).
            Lead with the most concrete topic. You MAY include AT MOST ONE participant's first name when their involvement is the distinguishing signal (e.g. they raised the issue, the topic is about their work, or the meeting was scheduled for them). Never list two or more names. Stay within 3-6 words and 50 chars.
            """
        default:
            let preview = others.prefix(4).joined(separator: ", ")
            participantPolicy = """
            # Participants (large group: 5+ others)
            \(otherCount) other people were on this call (e.g. \(preview)…). The meeting is too big for name-led titles. DO NOT include any participant names. Lead with the topic, project, or decision only.
            """
        }

        let systemPrompt = """
        You write meeting titles. Input: a short overview of a meeting (sometimes plus participant names). Output: ONE short, specific, scannable title that helps the user find this meeting in a list six months from now.

        # Hard rules (never violate)
        - 3-6 words. Maximum 50 characters.
        - Output ONLY the title. No preamble, no "Title:", no quotes, no markdown.
        - Sentence case (first word capitalized, rest lowercase unless proper noun).
        - No date, no time, no weekday, no month name. No "morning", "afternoon", etc.
        - Forbidden filler words: "meeting", "discussion", "call", "chat", "catch-up", "review of", "about", "with X" used as filler. Skip the meta-noun, lead with the substance.
        - "Sync" and "standup" are ALSO forbidden as filler — with ONE exception: when the overview clearly identifies a recurring meeting pattern (daily standup, weekly sync, biweekly check-in, recurring 1:1), you MAY use "<subject> standup" or "<subject> sync" because that IS the most accurate descriptor of the meeting type.
        - No em-dash (—), no en-dash (–). Hyphens (-) only in compound words ("year-over-year").
        - No emojis, no non-ASCII decoration.
        - No terminal punctuation (period, !, ?).

        # The test
        Six months from now, the user sees this title in a list of 200 meetings. Can they tell what it was about without opening it? If the title is "Strategy discussion" → no. If it's "Q3 pricing tiers and channel mix" → yes.

        # Strategy by meeting type
        - DECISION made → lead with the decision. "Move launch to August" beats "Launch timing".
        - PROBLEM raised → lead with the problem. "Stripe webhook retries failing" beats "Payment infrastructure".
        - PROJECT update → lead with the project + status. "Onboarding flow v3 review" beats "Onboarding work".
        - CONVERSATION recap → lead with the topic. "Hiring plan for Q4 engineering".
        - BRAINSTORM → lead with what came out. "Pricing tiers and channel strategy".
        - 1-on-1 / CATCH-UP → see the participants block. If exactly one other person, you MUST name them.
        - RECURRING meeting (daily standup, weekly sync, biweekly 1:1) → "<subject> standup" / "<subject> sync" is allowed and often best.

        # Specificity rules
        - Prefer concrete nouns over abstract ones. "Pricing tiers" beats "pricing".
        - Numbers, product names, brand names, person names — include them when distinctive.
        - If multiple topics, name the dominant one OR connect two with "and": "Pricing tiers and SDR hiring".

        # Examples

        Overview: "Discussed Meta ad strategy for a pain cream brand targeting older adults with chronic pain."
        → Meta ads for pain cream

        Overview: "Reviewed Q2 sales targets and decided to add two new SDRs by July."
        → Add two SDRs by July

        Overview: "Stripe webhook retries are timing out after the v4 upgrade. Looked at the queue worker logs."
        → Stripe webhook retries failing

        Overview: "Caught up about the brother's wedding in Paris and weekend boat plans."
        → Paris wedding and boat plans

        Overview: "Worked through the onboarding flow redesign with focus on the wake word permission step."
        → Onboarding flow and wake word permission

        Overview: "Brainstormed pricing tiers and channel strategy for the launch."
        → Pricing tiers and channel strategy

        Overview: "Walk-through of the renders for the new product, lots of feedback on the cap detail."
        → Product render feedback on cap

        Overview: "1:1 with Priya. Talked about her promotion path and concerns with the new manager."
        → Priya promotion path

        Overview: "1:1 with Sarah. She wants to talk about her promotion to senior."
        → Sarah promotion 1:1

        Overview: "Customer call with Acme. They want SOC 2 Type 2 before signing the enterprise deal."
        → Acme SOC 2 requirement

        Overview: "Sprint retro. Velocity dropped 30% because of the migration freeze."
        → Velocity drop from migration freeze

        Overview: "Design crit on the new dashboard. Concerns about info density and chart legibility."
        → Dashboard info density and legibility

        Overview: "Daily engineering standup. Sarah blocked on auth migration, Marcus wrapping the API rewrite."
        → Engineering standup

        Overview: "Weekly product sync. Walked through roadmap shifts and Q4 priorities."
        → Product roadmap sync

        # Bad outputs to avoid (actual model failures and what they should have been)

        BAD: "Meeting on May 25 afternoon"
          WHY: forbidden "meeting", date + time-of-day, gives the reader zero topic info.
          GOOD (for a 1:1 with Sarah about promotion): "Sarah promotion 1:1"

        BAD: "Discussion of Q3 strategy"
          WHY: forbidden "discussion of", abstract noun "strategy" with no specifics.
          GOOD: "Q3 pricing and channel mix"

        BAD: "Catch-up with Sarah and Marcus and Priya about the dashboard"
          WHY: forbidden "catch-up", forbidden "about", lists three names, blows past 6 words.
          GOOD (5+ on the call): "Dashboard info density review"
          GOOD (2-4 on the call): "Dashboard density review with Priya"

        # Other patterns to avoid
        - "Solo brainstorm — pricing"             (em-dash, forbidden "solo")
        - "Pricing Tiers And Channel Strategy"    (Title Case)
        - "Sync with Sarah" for an ad-hoc 1:1     (use "Sarah promotion 1:1" or a topic-led title; "sync" only for recurring)

        \(participantPolicy)
        """
        // Build user content. If participant names were captured, surface them
        // alongside the overview so the model can apply the policy above.
        let participantsBlock: String
        if otherCount == 0 {
            participantsBlock = ""
        } else {
            participantsBlock = "Participants present (apply the policy in the system prompt): \(others.joined(separator: ", ")).\n\n"
        }
        let userContent = participantsBlock + overview
        // Cerebras-first → Groq fallback → deterministic fallback. We use the
        // existing polish() entry point on both services because neither
        // exposes a separate "one-shot completion" surface — polish() is the
        // single chat-completion call both classes provide.
        var engineUsed = "fallback"
        var rawResult: String? = nil
        if CerebrasPolisher.isAvailable {
            rawResult = await CerebrasPolisher.shared.polish(
                userContent,
                systemPrompt: systemPrompt,
                maxTokens: 32,
                cacheKey: "meeting-title-v6",
                timeoutSeconds: 10
            )
            if rawResult != nil { engineUsed = "cerebras" }
        }
        if rawResult == nil, GroqPolisher.isAvailable {
            rawResult = await GroqPolisher.shared.polish(
                userContent,
                systemPrompt: systemPrompt,
                maxTokens: 32,
                timeoutSeconds: 10
            )
            if rawResult != nil { engineUsed = "groq" }
        }
        guard var title = rawResult?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            print("[VOICE-TITLE] engine=fallback (cloud unavailable)")
            return nil
        }
        print("[VOICE-TITLE] engine=\(engineUsed)")
        // Defensive cleanup — strip quotes, trailing punctuation, em-dashes
        // the model might include despite instructions.
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"'.!?,;:"))
        title = title.replacingOccurrences(of: " — ", with: ", ")
        title = title.replacingOccurrences(of: " – ", with: ", ")
        title = title.replacingOccurrences(of: "—", with: "-")
        if title.isEmpty { return nil }
        if title.count > 50 {
            let cutoff = title.index(title.startIndex, offsetBy: 50)
            title = String(title[..<cutoff]) + "…"
        }
        return title
    }

    /// Generate a structured meeting summary by calling Cerebras with the
    /// full transcript. Returns nil silently when Cerebras is unavailable
    /// (no API key / rate-limited / network issue) — caller just saves the
    /// meeting without a summary. The model is asked to return JSON which we
    /// decode into MeetingSummary. The format is enforced via the system
    /// prompt; we still defensively decode and accept partial results.
    static func generateSummary(
        segments: [TranscriptSegment],
        title: String,
        participants: [String]
    ) async -> MeetingSummary? {
        // Build a speaker-prefixed transcript for the LLM. Cerebras is
        // OpenAI-compatible Qwen-3-235B, 65k context — even a 50min meeting
        // (~10k words ≈ 15k tokens) fits easily.
        let transcriptText = segments
            .map { "\($0.speaker): \($0.text)" }
            .joined(separator: "\n")
        // Truncate to ~50k chars hard ceiling. Anything longer is exotic.
        let truncated: String
        if transcriptText.count > 50_000 {
            let cutoff = transcriptText.index(transcriptText.startIndex, offsetBy: 50_000)
            truncated = String(transcriptText[..<cutoff]) + "\n[...truncated]"
        } else {
            truncated = transcriptText
        }

        let participantsHint: String
        if participants.isEmpty {
            participantsHint = ""
        } else {
            participantsHint = "Participants: \(participants.joined(separator: ", ")).\n"
        }

        let systemPrompt = """
        You are a meeting analyst. Given a transcript with speaker labels, produce a structured JSON summary with FOUR REQUIRED FIELDS: overview, keyDecisions, actionItems, openQuestions.

        ABSOLUTE: NEVER use emojis. NEVER use em-dashes (\u{2014}) or en-dashes (\u{2013}). Use periods and commas.
        Output ONLY the JSON object: no preamble, no markdown fences, no commentary, no explanation.

        OUTPUT SCHEMA (strict, fields in this order, ALL FOUR ARE REQUIRED):
        {
          "overview": string,            // 2-3 sentences, SPECIFIC topics + outcomes, never generic
          "keyDecisions": string[],      // things actually DECIDED, not just discussed
          "actionItems": [{ "text": string, "assignee": string|null }],
          "openQuestions": string[]      // unresolved items needing follow-up
        }

        Return ONLY valid JSON. No preamble. No markdown fences. No commentary.

        EVERY field is required in the output. Use empty arrays ([]) for fields with no content, NEVER omit a field, NEVER use null for arrays. The four field NAMES are case-sensitive: "overview", "keyDecisions", "actionItems", "openQuestions". Do NOT use "decisions", "actions", "questions" as keys, the exact spelling matters.

        HARD RULES:
        1. overview must name the actual topics and outcomes in 2-3 sentences. Do NOT write "we discussed X" or "the team talked about Y." Write what was decided, debated, or resolved. If nothing concrete happened, say "No decisions reached; meeting was a status update on X."
        2. keyDecisions: ONLY stated conclusions ("we are going with X", "decided to ship", "approved", "let's do Y"). Discussion, brainstorming, debate, or hypotheticals are NOT decisions. If no real decisions were made, return [].
        3. actionItems: each one REQUIRES a commitment with a clear verb, "will", "going to", "agreed to", "I'll", "let me", "by Friday", "tomorrow", "next week". Hypothetical talk ("we could", "maybe we should") is NOT an action item. If a speaker name appears next to a commitment, set "assignee" to that name. Use null only when the commitment is collective ("we'll review this") or genuinely unattributed. If no commitments were made, return [].
        4. openQuestions: items raised but not resolved. Format each as a question ending with "?". Includes both literal questions asked and topics deferred for follow-up. If nothing is unresolved, return [].
        5. Be GENEROUS in extracting these four kinds of content. If the meeting was a real conversation, there is almost always at least one decision or one action or one open question. Try hard before returning all-empty arrays.
        6. Empty arrays for empty fields, never null. The arrays themselves must always be present.

        EXAMPLE 1
        Transcript snippet:
        Sarah: I think we need to ship the new pricing page before the launch.
        Mike: Agreed. I'll have the copy done by Thursday and hand it to design.
        Sarah: Great. And we're decided on the $49 tier, right?
        Mike: Yes, $49 it is.
        Sarah: What about the annual discount, should we do 20% off?
        Mike: Not sure, let me run the numbers.

        Correct output:
        {
          "overview": "Sarah and Mike locked in the $49 pricing tier and aligned on shipping the new pricing page before launch. The annual discount percentage is still open.",
          "keyDecisions": ["Pricing tier set at $49", "Pricing page will ship before launch"],
          "actionItems": [
            {"text": "Write pricing page copy by Thursday and hand off to design", "assignee": "Mike"},
            {"text": "Run the numbers on the 20% annual discount", "assignee": "Mike"}
          ],
          "openQuestions": ["Should the annual discount be 20% off?"]
        }

        EXAMPLE 2
        Transcript snippet:
        Alex: So the API latency is way up. Could be the new caching layer.
        Priya: Maybe. We could rollback, or we could add more redis nodes.
        Alex: Let's not rollback yet. I want data first.
        Priya: Fair. I'll pull the p95 numbers tomorrow morning and post them in #infra.
        Alex: Cool. We should also think about adding circuit breakers at some point.

        Correct output:
        {
          "overview": "Alex and Priya investigated a spike in API latency potentially caused by the new caching layer. They chose not to roll back yet and want metrics first before deciding between rollback or scaling redis.",
          "keyDecisions": ["No rollback yet; gather metrics first"],
          "actionItems": [
            {"text": "Pull p95 latency numbers tomorrow morning and post in #infra", "assignee": "Priya"}
          ],
          "openQuestions": ["Rollback the caching layer or add more redis nodes?", "Should circuit breakers be added?"]
        }

        EXAMPLE 3 (status-update style meeting, still produces all four fields)
        Transcript snippet:
        You: Quick update from me. The onboarding redesign is in review with design. I'll get the QA build out to the team by Friday so people can try it.
        Priya: Sounds good. We should also figure out if we keep the wake word permission step or push it to settings.
        You: Yeah, no answer on that yet.

        Correct output:
        {
          "overview": "Status update on the onboarding redesign. The redesign is in design review and a QA build will go to the team by Friday. The placement of the wake word permission step is still undecided.",
          "keyDecisions": [],
          "actionItems": [
            {"text": "Ship QA build of onboarding redesign to the team by Friday", "assignee": "You"}
          ],
          "openQuestions": ["Keep the wake word permission step in onboarding, or move it to settings?"]
        }
        """

        let userPrompt = "\(participantsHint)Title: \(title)\n\nTranscript:\n\(truncated)"

        // Cerebras-first → Groq fallback → deterministic rule-based fallback.
        // Local MLX (Qwen3-4B) is intentionally NOT in this chain — useLargeLocalModel
        // is disabled, and the summary/title path runs cloud-only at the user's
        // request. Both polishers expose only `polish()` as their chat-completion
        // entry point, so we reuse that with the structured-JSON system prompt.
        //
        // On parse failure, we retry ONCE with a stricter "respond ONLY with
        // valid JSON" reminder appended to the user prompt. The retry uses a
        // different cache key so we don't get the same broken response back.
        let retryUserPrompt = userPrompt + "\n\nIMPORTANT: Respond with VALID JSON only. Start with { and end with }. Include all four fields with EXACT names: \"overview\" (string), \"keyDecisions\" (array of strings), \"actionItems\" (array of {text, assignee} objects), \"openQuestions\" (array of strings). Use empty arrays [] for missing data, never null for arrays. No markdown fences, no commentary."

        if CerebrasPolisher.isAvailable {
            let result = await CerebrasPolisher.shared.polish(
                userPrompt,
                systemPrompt: systemPrompt,
                maxTokens: 2048,
                cacheKey: "meeting-summary-v2",
                timeoutSeconds: 30
            )
            if let result = result, let parsed = parseSummaryJSON(result) {
                print("[VOICE-SUMMARY] engine=cerebras")
                return parsed
            }
            print("[VOICE-SUMMARY] Cerebras first parse failed, retrying with JSON reminder")
            let retry = await CerebrasPolisher.shared.polish(
                retryUserPrompt,
                systemPrompt: systemPrompt,
                maxTokens: 2048,
                cacheKey: "meeting-summary-v2-retry",
                timeoutSeconds: 30
            )
            if let retry = retry, let parsed = parseSummaryJSON(retry) {
                print("[VOICE-SUMMARY] engine=cerebras (retry)")
                return parsed
            }
            print("[VOICE-SUMMARY] Cerebras returned nil/unparseable — \(CerebrasPolisher.shared.lastFailureReason ?? "unknown") — trying Groq")
        }

        if GroqPolisher.isAvailable {
            let result = await GroqPolisher.shared.polish(
                userPrompt,
                systemPrompt: systemPrompt,
                maxTokens: 2048,
                timeoutSeconds: 30
            )
            if let result = result, let parsed = parseSummaryJSON(result) {
                print("[VOICE-SUMMARY] engine=groq")
                return parsed
            }
            print("[VOICE-SUMMARY] Groq first parse failed, retrying with JSON reminder")
            let retry = await GroqPolisher.shared.polish(
                retryUserPrompt,
                systemPrompt: systemPrompt,
                maxTokens: 2048,
                timeoutSeconds: 30
            )
            if let retry = retry, let parsed = parseSummaryJSON(retry) {
                print("[VOICE-SUMMARY] engine=groq (retry)")
                return parsed
            }
            print("[VOICE-SUMMARY] Groq returned nil/unparseable — \(GroqPolisher.shared.lastFailureReason ?? "unknown") — using rules fallback")
        }

        // Deterministic rule-based fallback. No LLM at all — picks the longest
        // few segments as the overview and harvests obvious "will/agreed to"
        // commitments as action items. Always returns something so the UI
        // never shows an empty summary card.
        print("[VOICE-SUMMARY] engine=rules")
        return ruleBasedSummary(segments: segments, participants: participants)
    }

    /// Last-resort summary path. No LLM call. Builds a coarse overview from
    /// the longest transcript segments and a commitment-pattern action-item
    /// scan. Output quality is intentionally low — this is the "cloud is down,
    /// at least show *something*" path.
    private static func ruleBasedSummary(
        segments: [TranscriptSegment],
        participants: [String]
    ) -> MeetingSummary {
        let cleanSegs = segments.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        // Overview: take the three longest segments as a rough summary.
        let topSegs = cleanSegs
            .sorted(by: { $0.text.count > $1.text.count })
            .prefix(3)
        // Restore chronological order so the overview reads forward in time.
        let overviewSegs = topSegs.sorted(by: { $0.startTime < $1.startTime })
        var overview = overviewSegs.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: " ")
        if overview.count > 600 {
            let cutoff = overview.index(overview.startIndex, offsetBy: 600)
            overview = String(overview[..<cutoff]) + "…"
        }
        if overview.isEmpty {
            overview = "No transcript content available for automated summary."
        }

        // Action items: scan for "I'll", "I will", "will be", "going to",
        // "agreed to". Limit to first 5 hits to avoid noise.
        let patterns = ["i'll ", "i will ", "we'll ", "we will ", "going to ", "agreed to ", "let me "]
        var actions: [ActionItem] = []
        for seg in cleanSegs {
            let lower = seg.text.lowercased()
            if patterns.contains(where: { lower.contains($0) }) {
                let assignee = participants.first(where: {
                    seg.speaker.caseInsensitiveCompare($0) == .orderedSame
                })
                actions.append(ActionItem(
                    text: seg.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    assignee: assignee ?? (seg.speaker == "You" ? "You" : nil)
                ))
                if actions.count >= 5 { break }
            }
        }

        return MeetingSummary(
            overview: overview,
            keyDecisions: [],
            actionItems: actions,
            openQuestions: []
        )
    }

    /// Tolerant JSON parser. Strips markdown fences if the LLM wraps the
    /// payload, accepts missing fields, tolerates the most common key
    /// renames ("decisions" instead of "keyDecisions" etc.), accepts action
    /// items as either {text, assignee} objects or as plain strings, and
    /// never throws.
    ///
    /// Returns nil ONLY when the input is completely unparseable as JSON.
    /// Returns a populated MeetingSummary (with empty arrays for whatever
    /// the LLM omitted) for any successfully parsed payload.
    private static func parseSummaryJSON(_ raw: String) -> MeetingSummary? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip ```json … ``` fences if present. Handles ``` and ```json at
        // the start; tolerates leading commentary the model might emit before
        // the fence by isolating the first { ... last } window.
        if trimmed.hasPrefix("```") {
            if let firstNewline = trimmed.firstIndex(of: "\n") {
                trimmed = String(trimmed[trimmed.index(after: firstNewline)...])
            }
            if let lastFence = trimmed.range(of: "```", options: .backwards) {
                trimmed = String(trimmed[..<lastFence.lowerBound])
            }
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Final defense: if the model emitted any preamble before the JSON
        // (despite the prompt saying not to), slice from first { to last }.
        if let firstBrace = trimmed.firstIndex(of: "{"),
           let lastBrace = trimmed.lastIndex(of: "}"),
           firstBrace < lastBrace {
            trimmed = String(trimmed[firstBrace...lastBrace])
        }
        guard let data = trimmed.data(using: .utf8) else { return nil }

        // Generic JSON decode so we can pull values by either the canonical
        // field name (`keyDecisions`) or the common LLM substitute
        // (`decisions`). The model is told both in the prompt, but field
        // renames are by far the most common parse failure in practice.
        guard let any = try? JSONSerialization.jsonObject(with: data, options: []) else {
            print("[VOICE-SUMMARY] couldn't decode JSON: \(trimmed.prefix(200))")
            return nil
        }
        guard let obj = any as? [String: Any] else {
            print("[VOICE-SUMMARY] top-level JSON was not an object: \(trimmed.prefix(200))")
            return nil
        }

        // Helper: return the first non-nil value for any of the given keys.
        func firstValue(_ keys: [String]) -> Any? {
            for k in keys { if let v = obj[k] { return v } }
            return nil
        }

        // Overview: string. Tolerates alternate keys.
        let overview = (firstValue(["overview", "summary", "tldr", "abstract"]) as? String) ?? ""

        // Key decisions: array of strings. Tolerates alternate keys + array of objects with a "text" field.
        let keyDecisions: [String] = {
            guard let v = firstValue(["keyDecisions", "decisions", "key_decisions"]) else { return [] }
            if let arr = v as? [String] { return arr }
            if let arr = v as? [[String: Any]] {
                return arr.compactMap { ($0["text"] ?? $0["decision"] ?? $0["item"]) as? String }
            }
            return []
        }()

        // Open questions: array of strings. Same tolerance.
        let openQuestions: [String] = {
            guard let v = firstValue(["openQuestions", "questions", "open_questions"]) else { return [] }
            if let arr = v as? [String] { return arr }
            if let arr = v as? [[String: Any]] {
                return arr.compactMap { ($0["text"] ?? $0["question"] ?? $0["item"]) as? String }
            }
            return []
        }()

        // Action items: array of {text, assignee} OR array of strings.
        let actionItems: [ActionItem] = {
            guard let v = firstValue(["actionItems", "actions", "action_items"]) else { return [] }
            if let arr = v as? [String] {
                return arr.map { ActionItem(text: $0, assignee: nil) }
            }
            if let arr = v as? [[String: Any]] {
                return arr.compactMap { dict in
                    let text = (dict["text"] ?? dict["action"] ?? dict["item"] ?? dict["task"]) as? String
                    guard let t = text, !t.isEmpty else { return nil }
                    let assignee = (dict["assignee"] ?? dict["owner"] ?? dict["who"]) as? String
                    return ActionItem(
                        text: t,
                        assignee: (assignee?.isEmpty ?? true) ? nil : assignee
                    )
                }
            }
            return []
        }()

        return MeetingSummary(
            overview: overview,
            keyDecisions: keyDecisions,
            actionItems: actionItems,
            openQuestions: openQuestions
        )
    }

    /// Read a WAV/CAF as a mono Float32 sample buffer at 16 kHz. Mirrors the
    /// helper inside TranscriptionService but kept local so this service
    /// doesn't have to expose it as public API.
    private static func readSamplesAt16kMono(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let srcFormat = file.processingFormat
        guard let dstFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "VoiceRecovery", code: 1)
        }
        let converter = AVAudioConverter(from: srcFormat, to: dstFormat)
        guard let converter else {
            throw NSError(domain: "VoiceRecovery", code: 2)
        }
        // Reading the whole file at once is fine — Voice already does this in
        // TranscriptionService.transcribeFile for chunked decode.
        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw NSError(domain: "VoiceRecovery", code: 3)
        }
        try file.read(into: srcBuffer)
        let dstCapacity = AVAudioFrameCount(Double(srcBuffer.frameLength) * (16_000.0 / srcFormat.sampleRate) + 2_048)
        guard let dstBuffer = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: dstCapacity) else {
            throw NSError(domain: "VoiceRecovery", code: 4)
        }
        var error: NSError?
        var consumed = false
        converter.convert(to: dstBuffer, error: &error) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return srcBuffer
        }
        if let error { throw error }
        let count = Int(dstBuffer.frameLength)
        guard let channelData = dstBuffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[0], count: count))
    }

    /// Decode the meeting.speakerEventsJson blob into an array of
    /// MeetingCaptureService.SpeakerEvent. Returns [] if missing or invalid.
    private static func decodeSpeakerEvents(_ json: String?) -> [MeetingCaptureService.SpeakerEvent] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([MeetingCaptureService.SpeakerEvent].self, from: data)) ?? []
    }

    /// Find whose tile was active at `t` according to the Chrome timeline.
    /// Returns nil if no event matches or the most recent event was an
    /// "active=false" (stopped talking).
    private static func chromeNameAt(_ t: Date, in events: [MeetingCaptureService.SpeakerEvent]) -> String? {
        guard !events.isEmpty else { return nil }
        // The Chrome extension emits "active=true" when a tile lights up and
        // "active=false" when it goes dim. Find the latest event <= t per name,
        // pick the one whose latest event is `active = true`.
        var lastByName: [String: MeetingCaptureService.SpeakerEvent] = [:]
        for ev in events where ev.t <= t {
            if let prev = lastByName[ev.name], prev.t > ev.t { continue }
            lastByName[ev.name] = ev
        }
        let activeNow = lastByName.values.filter { $0.active }
        // Of the names currently marked active, return the most recent one.
        return activeNow.max(by: { $0.t < $1.t })?.name
    }

    /// Build a short human-readable title from a transcript. Heuristic:
    /// - If Chrome ext provided participant names → "Meeting with Alice, Bob"
    /// - Else look for the first substantive line (>4 words) and use it,
    ///   truncated to ~60 chars, falling back to "Morning/Afternoon
    ///   recording · MMM d" if nothing usable shows up in the first minute.
    private static func deriveMeetingTitle(
        segments: [TranscriptSegment],
        participantNames: [String],
        date: Date,
        sourceApp: String?,
        currentTitle: String
    ) -> String {
        let dateStr: String = {
            let f = DateFormatter()
            f.dateFormat = "MMM d"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f.string(from: date)
        }()

        // Named-participants path — gives the cleanest, most useful title.
        let names = participantNames
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !names.isEmpty {
            let me = (UserDefaults.standard.string(forKey: "voice.userName") ?? "").trimmingCharacters(in: .whitespaces)
            let others = names.filter { $0.caseInsensitiveCompare(me) != .orderedSame }
            if !others.isEmpty {
                let joined: String
                if others.count == 1 { joined = others[0] }
                else if others.count == 2 { joined = "\(others[0]) and \(others[1])" }
                else { joined = "\(others.prefix(2).joined(separator: ", ")) and \(others.count - 2) others" }
                return "Meeting with \(joined) · \(dateStr)"
            }
        }

        // Transcript-derived path. Take the first segment with at least 5 real
        // words and truncate to ~60 chars. Skip obvious filler-only openers.
        let firstSubstantive = segments.first(where: { seg in
            let words = seg.text.split(separator: " ").filter { !$0.isEmpty }
            return words.count >= 5
        })
        if let seg = firstSubstantive {
            let cleaned = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Strip trailing punctuation since we'll be appending the date.
            let stripped = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;:"))
            let shortened: String
            if stripped.count <= 60 { shortened = stripped }
            else {
                let cutoff = stripped.index(stripped.startIndex, offsetBy: 60)
                shortened = String(stripped[..<cutoff]) + "…"
            }
            return "\(shortened) · \(dateStr)"
        }

        // Time-bucket fallback. Used when transcript is too short / noisy.
        let hour = Calendar.current.component(.hour, from: date)
        let bucket: String
        switch hour {
        case 5..<12:  bucket = "Morning"
        case 12..<17: bucket = "Afternoon"
        case 17..<22: bucket = "Evening"
        default:      bucket = "Night"
        }
        let appLabel: String
        switch sourceApp {
        case "com.google.meet":         appLabel = "Meet"
        case "us.zoom.xos":              appLabel = "Zoom"
        case "com.microsoft.teams2":    appLabel = "Teams"
        case "com.cisco.webex.meetings": appLabel = "Webex"
        default:                         appLabel = "recording"
        }
        return "\(bucket) \(appLabel) · \(dateStr)"
    }

    // MARK: - Layer 3: Live checkpoint (during a meeting)

    /// Save the in-progress meeting row to GRDB. Idempotent — uses the same
    /// meetingId, so calling this every 30s just overwrites the row with the
    /// growing segment list. If the app crashes here, the row stays.
    ///
    /// `kind` is forced to `.meeting`. `audioFilePath` should be the live
    /// path that MeetingCaptureService is streaming into.
    func checkpointDraft(_ draft: MeetingDraftSnapshot) {
        let meeting = Meeting(
            id: draft.meetingId,
            title: draft.title,
            date: draft.date,
            duration: draft.durationSeconds,
            segments: draft.segments,
            audioFilePath: draft.audioFilePath,
            kind: .meeting,
            sourceApp: draft.sourceApp
        )
        do {
            try storage.saveMeeting(meeting)
            print("[VOICE-RECOVERY] draft checkpoint: \(draft.segments.count) segments, \(Int(draft.durationSeconds))s")
        } catch {
            // Non-fatal — the live capture continues, we just don't have a
            // crash-safe snapshot for this tick.
            print("[VOICE-RECOVERY] draft checkpoint failed: \(error)")
        }
    }

    // MARK: - Formatting

    private static func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }
}

