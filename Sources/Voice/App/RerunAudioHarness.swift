// VOICE — Re-run Audio Harness
// ============================================================
// Headless CLI mode: re-transcribe + re-polish the last N saved dictations
// straight from their retained .caf audio, and print OLD vs NEW transcript +
// polished text + latency, so we can see whether the current pipeline produces
// better/faster output than what the user originally got.
//
//   swift run -c release Voice --rerun-audio        # last 10
//   swift run -c release Voice --rerun-audio 25     # last 25
//
// A RecentDictation stores no audio path, so we bridge to the .caf via
// StorageService: the segments table holds the raw Parakeet text (== the
// dictation's `parakeetRawText`), and the owning meeting row holds the
// audioFilePath. See StorageService.audioPathsByNormalizedSegmentText().
//
// Lives in the Voice target (not a separate one) for the same reason as
// PolishHarness: the transcription + polish pipelines use internal access.
// ============================================================

import Foundation

@MainActor
enum RerunAudioHarness {
    private static func hprint(_ msg: String = "") {
        FileHandle.standardOutput.write(Data((msg + "\n").utf8))
    }

    private static func norm(_ s: String?) -> String {
        (s ?? "").lowercased()
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    struct Item {
        let entry: RecentDictation
        let audioURL: URL
    }

    static func run(limit: Int) async {
        hprint("[RERUN] Loading recent dictations (limit \(limit))…")

        // --- Bridge rawText → audioFilePath via voice.db ---
        let storage = StorageService()
        do { try storage.initialize() } catch {
            hprint("[RERUN] FATAL: cannot open voice.db: \(error)"); return
        }
        let pathByRaw = storage.audioPathsByNormalizedSegmentText()
        hprint("[RERUN] indexed \(pathByRaw.count) audio-backed segments from voice.db")

        // --- Resolve the last N non-cancelled entries to on-disk .caf ---
        var items: [Item] = []
        for e in RecentDictations.all() where !e.cancelled {
            guard let path = pathByRaw[norm(e.parakeetRawText)] ?? pathByRaw[norm(e.text)] else {
                continue
            }
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            items.append(Item(entry: e, audioURL: url))
            if items.count >= limit { break }
        }
        hprint("[RERUN] resolved \(items.count)/\(limit) entries to on-disk audio")
        guard !items.isEmpty else { hprint("[RERUN] nothing to do."); return }

        // --- Prepare transcription (downloads/loads Parakeet; blocks until ready) ---
        let transcription = TranscriptionService()
        do {
            hprint("[RERUN] preparing Parakeet…")
            try await transcription.prepare()
            hprint("[RERUN] Parakeet ready.")
        } catch {
            hprint("[RERUN] FATAL: transcription.prepare() failed: \(error)"); return
        }

        // --- Prewarm polish (cloud needs only an API key; local is the fallback) ---
        if Qwen3Polisher.isAvailable {
            Qwen3Polisher.shared.prewarm()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        hprint("[RERUN] cloud-available=\(CerebrasPolisher.isAvailable)")

        // --- Per-item rerun ---
        var oldMsTotal = 0, newMsTotal = 0, counted = 0, changedCount = 0
        for (i, it) in items.enumerated() {
            let e = it.entry

            // 1) Re-transcribe from the saved audio.
            let tStart = Date()
            let segs = (try? await transcription.transcribeFile(url: it.audioURL)) ?? []
            let newTranscript = segs.map { $0.text }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let transcribeMs = Int(Date().timeIntervalSince(tStart) * 1000)

            // 2) Re-polish via the production entry point (full cloud routing).
            let pStart = Date()
            let newPolished = await Qwen3Polisher.shared.polish(
                newTranscript,
                suspectWords: segs.first?.suspectWords,
                cleanupLevel: (e.cleanupLevelUsed ?? "medium").lowercased(),
                personalityStyle: (e.personalityStyleUsed ?? "neutral").lowercased()
            )
            let newPolishMs = Int(Date().timeIntervalSince(pStart) * 1000)
            let newEngine = PolishStatus.shared.lastEngine ?? "unknown"

            // 3) Compare.
            let oldText = e.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let textChanged = newPolished.trimmingCharacters(in: .whitespacesAndNewlines) != oldText
            let transcriptChanged = newTranscript != (e.parakeetRawText ?? "")

            hprint("")
            hprint("=== [\(i + 1)/\(items.count)] \(it.audioURL.lastPathComponent) ===")
            hprint("OLD transcript : \(e.parakeetRawText ?? "<none>")")
            hprint("NEW transcript : \(newTranscript)   (transcribe \(transcribeMs)ms, changed=\(transcriptChanged))")
            hprint("OLD polished   : [\(e.polishEngine ?? "?") \(e.polishMs.map(String.init) ?? "?")ms] \(oldText)")
            hprint("NEW polished   : [\(newEngine) \(newPolishMs)ms] \(newPolished)")
            hprint("TEXT CHANGED   : \(textChanged)")

            if let om = e.polishMs { oldMsTotal += om; newMsTotal += newPolishMs; counted += 1 }
            if textChanged { changedCount += 1 }
        }

        // --- Summary ---
        hprint("")
        hprint("=== SUMMARY ===")
        hprint("items rerun          : \(items.count)")
        if counted > 0 {
            hprint("avg OLD polish ms    : \(oldMsTotal / counted)")
            hprint("avg NEW polish ms    : \(newMsTotal / counted)")
        }
        let pct = items.isEmpty ? 0 : changedCount * 100 / items.count
        hprint("polished text changed: \(changedCount)/\(items.count) (\(pct)%)")
        hprint("[RERUN] done. (NEW engine printed per item — OLD vs NEW may differ; cloud latency reflects current network state.)")
    }
}
