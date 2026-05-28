// VOICE — Speaker Diarizer
// ============================================================
// Audio-based speaker diarization for meeting transcripts.
//
// This labels who's speaking from the AUDIO itself, independent
// of any DOM scraping. It works on Zoom, FaceTime, in-person
// meetings, and as a fallback when the Meet/Discord/Teams DOM
// hooks fail.
//
// Architecture:
//   - Wraps FluidAudio's `DiarizerManager` (pyannote 3.1 pipeline:
//     powerset segmentation + WeSpeaker embeddings + clustering)
//   - One DiarizerManager instance per SpeakerDiarizer — its
//     internal SpeakerManager keeps speaker identity stable across
//     chunks for the lifetime of the session.
//   - Models are loaded lazily on first diarize() call so app
//     startup isn't blocked.
//   - Cross-session participant recognition: known voice centroids
//     (e.g. Sarah's voice) can be persisted to disk and reloaded
//     into the manager on init, so a recurring participant gets
//     the same voice ID across meetings.
//
// Speaker ID mapping:
//   FluidAudio emits stable string IDs ("spk_0", "spk_1", …) that
//   persist across calls because we hold the manager. We translate
//   those strings into the simple integer IDs MeetingCaptureService
//   wants by remembering "string -> int" pairs per session. When a
//   string ID is a known persisted participant, we surface its
//   name in logs and reserve its int slot first.
//
// Clustering semantics (READ THIS — it's a foot-gun):
//   FluidAudio's `clusteringThreshold` / `speakerThreshold` is a
//   COSINE DISTANCE, not similarity:
//     - distance < threshold  → same speaker
//     - LOWER threshold = STRICTER = more distinct speakers
//     - HIGHER threshold = LOOSER  = more merging
//   So "tighten the threshold to 0.72" colloquially means tighten
//   similarity, which here means LOWER the distance threshold from
//   the 0.7 default to 0.62. We tune accordingly below.
//
// Failure mode:
//   diarize() catches every internal error and returns []. The
//   caller falls back to single-speaker labeling. We never crash
//   the meeting capture session because diarization failed.
// ============================================================

import Foundation
import FluidAudio

/// Result of diarizing one chunk: a single speaker's turn within that chunk.
/// Times are RELATIVE to the chunk start, not session start.
struct DiarizedTurn: Sendable {
    /// Seconds from the chunk's start (0..30s for a 30s chunk).
    let startTime: TimeInterval
    /// Seconds from the chunk's start.
    let endTime: TimeInterval
    /// Integer voice ID, stable across the entire diarizer session.
    /// 0, 1, 2, … assigned in arrival order as new speakers are heard.
    let voiceID: Int
}

/// A speaker centroid persisted across sessions. Saving Sarah's centroid lets
/// next week's meeting recognize her voice without manual labeling.
///
/// `embedding` is the L2-normalized 256D WeSpeaker vector exported from the
/// FluidAudio SpeakerManager after we've accumulated enough audio of this
/// person. `displayName` is what we want to show in transcripts.
struct PersistedCentroid: Codable, Sendable {
    let id: String          // stable identifier, e.g. "sarah", "alex"
    let displayName: String // "Sarah Chen"
    let embedding: [Float]  // 256D, L2-normalized
    let createdAt: Date
    let updatedAt: Date
}

/// Implemented as an `actor` so callers from any thread (the
/// MeetingCaptureService transcription worker runs on a detached Task) can
/// safely invoke `diarize()` and `reset()` without bumping into Sendable
/// warnings or main-actor isolation errors.
actor SpeakerDiarizer {

    // MARK: - Tunables (centralized for visibility)

    /// Cosine *distance* threshold. Lower = stricter = fewer false-merges of
    /// distinct speakers. FluidAudio default is 0.7; we tighten to 0.62 so that
    /// e.g. a mid-pitch male and a low-alto female don't get collapsed into the
    /// same speaker. If you see legitimately-same-speaker segments getting
    /// split, bump this back up by 0.03 at a time.
    private static let clusteringThreshold: Float = 0.62

    /// Minimum seconds of speech before we'll consider a segment "worth a
    /// speaker assignment." Default 1.0 is fine — sub-second utterances are
    /// where misassignment lives, but discarding them all means the transcript
    /// loses interjections ("yeah", "right"). We accept the noise.
    private static let minSpeechDuration: Float = 1.0

    /// Minimum seconds of speech a segment must contribute before its embedding
    /// is allowed to *update* an existing speaker's centroid (online EMA pull).
    /// Higher = more stable centroids (won't drift toward background noise from
    /// short clips); lower = faster adaptation. 1.5s is a good balance.
    private static let minEmbeddingUpdateDuration: Float = 1.5

    /// After diarization, look at all pairs of clusters whose centroids are
    /// within this cosine distance of each other. If both clusters in the pair
    /// hold <`minMergeSpeechFraction` of total speech, treat them as
    /// noise-induced splits and merge them.
    private static let minMergeDistance: Float = 0.4

    /// A cluster holding less than this fraction of total speech is considered
    /// a candidate for being merged into a neighbor (noise-induced split).
    private static let minMergeSpeechFraction: Float = 0.05

    /// Where to persist known-participant centroids on disk so they survive
    /// across app launches and meeting sessions.
    private static var persistenceURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = appSupport.appendingPathComponent("Voice", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("speaker_centroids.json")
    }

    // MARK: - State

    private var manager: DiarizerManager?
    private var modelsLoaded: Bool = false
    private var modelLoadInFlight: Task<Void, Error>? = nil

    /// Maps FluidAudio's stable string speaker IDs (e.g. "spk_0") onto the
    /// integer IDs we expose to callers. Built incrementally — voice 0 is the
    /// first speaker we ever hear, voice 1 is the second, and so on.
    private var voiceIDMap: [String: Int] = [:]

    /// If true, diarize() short-circuits and returns a single voice-0 turn
    /// spanning the whole audio. Used for solo recordings (mic-only, no SCStream
    /// system-audio mix) where running the diarizer pipeline is pure waste —
    /// there's only one human in the recording by construction.
    private var soloMode: Bool = false

    /// Centroids loaded from disk on first model-load. Mapped into the
    /// SpeakerManager so a known voice gets recognized on its very first turn.
    /// Key: persisted ID ("sarah"). Value: display name for logging.
    private var knownParticipantNames: [String: String] = [:]

    // MARK: - Init

    init() {
        // Models are not loaded yet — the first diarize() call will trigger
        // a one-time download + compile via FluidAudio's downloader. Keeping
        // it lazy means app launch isn't blocked by a multi-hundred-MB CoreML
        // bundle on first run.
    }

    // MARK: - Public configuration

    /// Tell the diarizer this session has only one human speaker (e.g. a
    /// mic-only recording with no system-audio mix). When true, `diarize()`
    /// returns a single voice-0 turn covering the whole audio and skips the
    /// embedding + clustering pipeline entirely. Saves ~200ms/chunk.
    func setSoloMode(_ solo: Bool) {
        soloMode = solo
        print("[VOICE-DIAR] solo-mode \(solo ? "ENABLED" : "disabled") — diarization \(solo ? "bypassed" : "active")")
    }

    /// Reset all per-session state. Call between meetings so voice IDs
    /// from a previous call don't carry over.
    func reset() {
        let prevCount = voiceIDMap.count
        voiceIDMap.removeAll(keepingCapacity: false)
        print("[VOICE-DIAR] session reset (cleared \(prevCount) voice-ID mappings)")
        // The DiarizerManager's internal SpeakerManager still holds embeddings
        // from the previous session. For now we leave it — the next session
        // will simply emit new string IDs like "spk_5" which we'll map to
        // voice 0 anyway because voiceIDMap was cleared. If we wanted true
        // isolation we'd `cleanup()` + reinitialize, but that throws away the
        // compiled CoreML models too. The current behavior is the right
        // trade-off: fast restart, fresh int IDs.
    }

    /// Diarize a single audio chunk. Returns turns sorted by startTime.
    /// Returns [] on any error — caller falls back to single-speaker labeling.
    ///
    /// - Parameters:
    ///   - samples: Mono float32 audio (typically 16 kHz).
    ///   - sampleRate: Sample rate. Default 16 kHz.
    func diarize(samples: [Float], sampleRate: Double = 16_000) async -> [DiarizedTurn] {
        guard !samples.isEmpty else { return [] }

        // Solo recordings: skip the model entirely. One turn, voice 0, done.
        // This is a real perf + correctness win — the WeSpeaker pipeline often
        // misclusters silence-padded mic recordings into 2+ "speakers" that are
        // all the same person + room noise, which then shows up in transcripts
        // as fake speaker switches.
        if soloMode {
            let durationSec = Double(samples.count) / sampleRate
            print("[VOICE-DIAR] solo-mode short-circuit: 1 turn, voice 0, \(String(format: "%.2f", durationSec))s")
            return [DiarizedTurn(startTime: 0, endTime: durationSec, voiceID: 0)]
        }

        // Models too short for the WeSpeaker embedding window get garbage
        // output — guard against tiny tail chunks at the end of a session.
        // The pyannote segmentation model wants at least ~1s of audio.
        let minSamples = Int(sampleRate * 1.0)
        guard samples.count >= minSamples else {
            print("[VOICE-DIAR] chunk too short (\(samples.count) samples < \(minSamples)) — returning empty")
            return []
        }

        do {
            try await ensureModelsLoaded()
        } catch {
            print("[VOICE-DIAR] model load failed: \(error.localizedDescription)")
            return []
        }

        guard let manager = manager else { return [] }

        do {
            let durationSec = Double(samples.count) / sampleRate
            print("[VOICE-DIAR] diarizing chunk: \(String(format: "%.2f", durationSec))s @ \(Int(sampleRate))Hz")

            // FluidAudio expects Int sample rate. 30s @ 16 kHz = 480_000.
            let result = try await manager.performCompleteDiarization(
                samples,
                sampleRate: Int(sampleRate),
                atTime: 0
            )

            // After the manager has finished assigning embeddings to clusters,
            // do a min-merge pass to collapse clusters that are very close in
            // embedding space AND hold a vanishingly small share of speech —
            // those are almost always the same human, split by an ambient
            // noise burst or a quiet utterance. We do this BEFORE building the
            // int-ID map so the caller never sees the spurious cluster.
            await collapseNoiseSplitClusters(in: manager, totalDuration: durationSec)

            // FluidAudio's TimedSpeakerSegment carries:
            //   - speakerId: stable string ("spk_0", "spk_1", …)
            //   - startTimeSeconds / endTimeSeconds: relative to the audio
            //     we just handed it (i.e. chunk-relative, because we passed
            //     atTime: 0).
            // Map each segment into a DiarizedTurn with an int voiceID.
            var turns: [DiarizedTurn] = []
            turns.reserveCapacity(result.segments.count)
            var perVoiceCounts: [Int: Int] = [:]
            for seg in result.segments {
                // Skip un-assigned segments (FluidAudio occasionally emits
                // empty speakerId when activity was below threshold but the
                // segment slipped through).
                guard !seg.speakerId.isEmpty else { continue }
                let vid = voiceID(forString: seg.speakerId)
                perVoiceCounts[vid, default: 0] += 1
                turns.append(DiarizedTurn(
                    startTime: TimeInterval(seg.startTimeSeconds),
                    endTime: TimeInterval(seg.endTimeSeconds),
                    voiceID: vid
                ))
            }
            // Sort defensively in case FluidAudio returns them in any other
            // order (it currently sorts by startTimeSeconds, but rely on
            // the input shape, not the implementation detail).
            turns.sort { $0.startTime < $1.startTime }

            // Summary log: how many distinct voices did we hear in this chunk?
            let breakdown = perVoiceCounts
                .sorted { $0.key < $1.key }
                .map { "v\($0.key)×\($0.value)" }
                .joined(separator: " ")
            print("[VOICE-DIAR] chunk done: \(turns.count) turns across \(perVoiceCounts.count) voices [\(breakdown)]")
            return turns
        } catch {
            print("[VOICE-DIAR] diarization failed: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Cross-session participant recognition

    /// Load the disk-persisted speaker centroids (Sarah's voice, Alex's voice,
    /// …) into the underlying SpeakerManager. After this returns, the very
    /// first turn we hear from a known participant in any future session will
    /// be matched against their stored centroid and assigned the same string
    /// ID — making cross-session voice continuity possible.
    ///
    /// Call after init + first model-load. Safe to call multiple times (it
    /// uses `.skip` mode so existing entries aren't clobbered).
    func loadPersistedCentroids() async {
        guard let manager = manager else {
            print("[VOICE-DIAR] loadPersistedCentroids: manager not ready yet — call after first diarize()")
            return
        }

        let centroids: [PersistedCentroid]
        do {
            let data = try Data(contentsOf: Self.persistenceURL)
            centroids = try JSONDecoder().decode([PersistedCentroid].self, from: data)
        } catch {
            // File missing on first run is normal — don't shout about it.
            if (error as NSError).code != NSFileReadNoSuchFileError {
                print("[VOICE-DIAR] could not read persisted centroids: \(error.localizedDescription)")
            } else {
                print("[VOICE-DIAR] no persisted centroids on disk (first run, expected)")
            }
            return
        }

        guard !centroids.isEmpty else {
            print("[VOICE-DIAR] persisted-centroids file is empty")
            return
        }

        // Translate our PersistedCentroid → FluidAudio's Speaker. Mark each as
        // permanent so it survives a SpeakerManager.reset() and so a later
        // findMergeablePairs() pass won't dissolve it.
        var fluidSpeakers: [Speaker] = []
        fluidSpeakers.reserveCapacity(centroids.count)
        for c in centroids {
            let s = Speaker(
                id: c.id,
                name: c.displayName,
                currentEmbedding: c.embedding,
                duration: 0,
                createdAt: c.createdAt,
                updatedAt: c.updatedAt,
                isPermanent: true
            )
            fluidSpeakers.append(s)
            knownParticipantNames[c.id] = c.displayName
        }
        await manager.speakerManager.initializeKnownSpeakers(fluidSpeakers, mode: .skip)
        print("[VOICE-DIAR] loaded \(fluidSpeakers.count) persisted centroids: \(centroids.map { $0.displayName }.joined(separator: ", "))")
    }

    /// Snapshot the current SpeakerManager state and write it to disk so the
    /// next session can recognize today's speakers. Filters to clusters that
    /// have accumulated at least `minDuration` seconds — short-lived clusters
    /// (a one-off cough) shouldn't pollute the persisted set.
    ///
    /// `nameProvider` lets the caller (MeetingCaptureService) supply a display
    /// name for each speaker ID it's seen, e.g. by joining DOM-scraped Zoom
    /// participants against voice IDs. If `nameProvider` returns nil for an
    /// ID, that speaker is skipped (we don't want unnamed centroids).
    func persistCurrentCentroids(
        minDuration: Float = 8.0,
        nameProvider: @Sendable (_ speakerId: String) -> String?
    ) async {
        guard let manager = manager else {
            print("[VOICE-DIAR] persistCurrentCentroids: manager not ready, nothing to save")
            return
        }

        let speakers = await manager.speakerManager.getSpeakerList()
        var toPersist: [PersistedCentroid] = []
        for sp in speakers {
            guard sp.duration >= minDuration else {
                print("[VOICE-DIAR] skip-persist \(sp.id) — only \(String(format: "%.1f", sp.duration))s of speech (< \(minDuration)s)")
                continue
            }
            guard let displayName = nameProvider(sp.id) else {
                print("[VOICE-DIAR] skip-persist \(sp.id) — no display name supplied")
                continue
            }
            toPersist.append(PersistedCentroid(
                id: sp.id,
                displayName: displayName,
                embedding: sp.currentEmbedding,
                createdAt: sp.createdAt,
                updatedAt: sp.updatedAt
            ))
        }

        guard !toPersist.isEmpty else {
            print("[VOICE-DIAR] no centroids met the persistence bar — disk unchanged")
            return
        }

        // Merge with whatever is already on disk: a returning participant's
        // centroid updates (more data = more accurate), and new participants
        // get added. Disk wins on ID conflicts when its embedding is more
        // recent (rare) — otherwise the new in-memory snapshot wins.
        var existingById: [String: PersistedCentroid] = [:]
        if let data = try? Data(contentsOf: Self.persistenceURL),
           let prior = try? JSONDecoder().decode([PersistedCentroid].self, from: data) {
            for p in prior { existingById[p.id] = p }
        }
        for p in toPersist {
            if let existing = existingById[p.id], existing.updatedAt > p.updatedAt {
                // Disk is newer; keep it. Shouldn't usually happen.
                continue
            }
            existingById[p.id] = p
        }
        let merged = Array(existingById.values).sorted { $0.displayName < $1.displayName }

        do {
            let data = try JSONEncoder().encode(merged)
            try data.write(to: Self.persistenceURL, options: .atomic)
            print("[VOICE-DIAR] persisted \(merged.count) centroids to \(Self.persistenceURL.lastPathComponent): \(merged.map { $0.displayName }.joined(separator: ", "))")
        } catch {
            print("[VOICE-DIAR] failed to write centroids: \(error.localizedDescription)")
        }
    }

    // MARK: - Private helpers

    /// After the diarizer's clustering step, examine every pair of clusters
    /// and merge any pair where BOTH centroids are very close in embedding
    /// space AND both clusters hold a tiny share of total speech. These are
    /// almost always the same person, split by ambient noise or a quiet
    /// utterance bleed-through.
    private func collapseNoiseSplitClusters(in manager: DiarizerManager, totalDuration: Double) async {
        let speakers = await manager.speakerManager.getSpeakerList()
        guard speakers.count >= 2, totalDuration > 0 else { return }

        let totalSpeech = speakers.reduce(Float(0)) { $0 + $1.duration }
        guard totalSpeech > 0 else { return }

        // findMergeablePairs uses cosine distance and returns pairs under the
        // threshold. We use the AGGRESSIVE 0.4 distance here (much tighter
        // than the session-level 0.62) so we only merge clusters that are
        // genuinely similar — not just "in the same neighborhood."
        let pairs = await manager.speakerManager.findMergeablePairs(speakerThreshold: Self.minMergeDistance)
        guard !pairs.isEmpty else { return }

        // Index durations for the speech-fraction gate.
        var durationById: [String: Float] = [:]
        for sp in speakers { durationById[sp.id] = sp.duration }

        var mergeCount = 0
        for pair in pairs {
            guard let srcDur = durationById[pair.speakerToMerge],
                  let dstDur = durationById[pair.destination] else { continue }
            let srcFrac = srcDur / totalSpeech
            let dstFrac = dstDur / totalSpeech
            // Both must be small for us to call this a noise-induced split.
            // If one is the dominant speaker, the other being close is
            // suspicious but might be a quiet co-host — leave them alone.
            guard srcFrac < Self.minMergeSpeechFraction, dstFrac < Self.minMergeSpeechFraction else {
                print("[VOICE-DIAR] skip-merge \(pair.speakerToMerge)→\(pair.destination): one cluster too big (\(String(format: "%.1f%%", srcFrac*100)) / \(String(format: "%.1f%%", dstFrac*100)))")
                continue
            }
            await manager.speakerManager.mergeSpeaker(pair.speakerToMerge, into: pair.destination, stopIfPermanent: true)
            mergeCount += 1
            print("[VOICE-DIAR] merge \(pair.speakerToMerge)→\(pair.destination): close centroids (~\(String(format: "%.2f", Self.minMergeDistance))) AND both <\(Int(Self.minMergeSpeechFraction*100))% (\(String(format: "%.1f", srcFrac*100))% / \(String(format: "%.1f", dstFrac*100))%)")
        }
        if mergeCount > 0 {
            print("[VOICE-DIAR] min-merge pass collapsed \(mergeCount) noise-split cluster(s)")
        }
    }

    /// Translate FluidAudio's stable string speaker IDs into compact int
    /// voice IDs. Caches assignments so the same string always maps to the
    /// same int for the lifetime of this SpeakerDiarizer. If the string ID
    /// is a known persisted participant (e.g. "sarah"), the log line surfaces
    /// the display name so you can see in Console.app that recognition fired.
    private func voiceID(forString stringID: String) -> Int {
        if let existing = voiceIDMap[stringID] { return existing }
        let next = voiceIDMap.count
        voiceIDMap[stringID] = next
        if let name = knownParticipantNames[stringID] {
            print("[VOICE-DIAR] new voice slot v\(next) ← known participant \"\(name)\" (id=\(stringID))")
        } else {
            print("[VOICE-DIAR] new voice slot v\(next) ← \(stringID) (unrecognized — new speaker this session)")
        }
        return next
    }

    /// Load + compile the FluidAudio CoreML diarizer models. Idempotent.
    /// Concurrent callers share a single in-flight Task to avoid duplicate
    /// downloads. After model load, persisted centroids are pulled into the
    /// fresh SpeakerManager so the very first turn in the session can be
    /// matched against a known voice.
    private func ensureModelsLoaded() async throws {
        if modelsLoaded { return }
        if let inFlight = modelLoadInFlight {
            try await inFlight.value
            return
        }
        let task = Task<Void, Error> { [self] in
            print("[VOICE-DIAR] downloading + compiling diarizer models (threshold=\(Self.clusteringThreshold) dist, min-speech=\(Self.minSpeechDuration)s)")
            let models = try await DiarizerModels.downloadIfNeeded()
            // Custom config: tighter clustering, EMA-friendly update gate. The
            // SpeakerManager that DiarizerManager owns will read these and use
            // them for every per-segment assignment + centroid update.
            let config = DiarizerConfig(
                clusteringThreshold: Self.clusteringThreshold,
                minSpeechDuration: Self.minSpeechDuration,
                minEmbeddingUpdateDuration: Self.minEmbeddingUpdateDuration,
                minSilenceGap: 0.5,
                numClusters: -1,
                minActiveFramesCount: 10.0,
                debugMode: false,
                chunkDuration: 10.0,
                chunkOverlap: 0.0
            )
            let m = DiarizerManager(config: config)
            m.initialize(models: consume models)
            await self.installManager(m)
            // Reload known voices into the freshly-initialized SpeakerManager.
            // This is what makes Sarah's voice recognizable next Tuesday.
            await self.loadPersistedCentroids()
            print("[VOICE-DIAR] models ready (online centroid update is ALPHA=0.9 EMA inside FluidAudio)")
        }
        modelLoadInFlight = task
        defer { modelLoadInFlight = nil }
        try await task.value
    }

    /// Helper invoked from the model-load Task to land the compiled manager
    /// into actor-isolated state.
    private func installManager(_ m: DiarizerManager) {
        self.manager = m
        self.modelsLoaded = true
    }
}
