// VOICE — Video transcription pipeline coordinator.
// ============================================================
// Glues the three backend pieces together into one user-facing flow:
//
//   ingest (VideoIngestService) → transcript (captions OR local ASR via
//   TranscriptionEngine) → summary (VideoSummarizer) → persist + reflect
//   progress live in TranscribedVideoStore.
//
// Mirrors the app's @Observable @MainActor singleton convention (PolishStatus,
// TranscribedVideoStore). The view owns one of these and calls
// `transcribeVideo(urlString:)`; every pipeline step calls `store.update(...)`
// so the UI grid reflects status (ingesting → transcribing → summarizing →
// done / failed) as it happens.
// ============================================================

import Foundation
import Observation

@Observable
@MainActor
final class VideoTranscriptionCoordinator {

    static let shared = VideoTranscriptionCoordinator()

    private let store = TranscribedVideoStore.shared

    /// Set true while at least one transcription is in flight — lets the UI
    /// reflect global busy state if it wants to.
    private(set) var isRunning = false

    init() {}

    /// Kick off the full ingest → transcribe → summarize → persist pipeline for
    /// a single URL. Adds a placeholder row immediately so the UI shows a card
    /// right away, then mutates it in place through each stage.
    func transcribeVideo(urlString: String) async {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // 1. Insert a placeholder row in `.ingesting` state immediately.
        var video = TranscribedVideo(
            sourceURL: trimmed,
            title: trimmed,
            status: .ingesting
        )
        store.add(video)
        isRunning = true
        defer { isRunning = false }

        do {
            // 2. Ingest: metadata + captions-or-audio.
            let result = try await VideoIngestService().ingest(urlString: trimmed)

            video = TranscribedVideo(
                id: video.id,
                sourceURL: result.sourceURL,
                title: result.title,
                channel: result.channel,
                durationSeconds: result.durationSeconds,
                thumbnailLocalPath: result.thumbnailLocalPath ?? result.thumbnailURL,
                addedAt: video.addedAt,
                transcript: "",
                status: .ingesting
            )
            store.update(video)

            // 3. Transcript: captions fast-path, or local ASR on the WAV.
            let transcriptText: String
            switch result.transcript {
            case .captions(let text):
                transcriptText = text
            case .needsLocalASR(let wavPath):
                video.status = .transcribing
                store.update(video)
                transcriptText = try await runLocalASR(wavPath: wavPath)
            }

            video.transcript = transcriptText
            store.update(video)

            // 4. Summarize.
            video.status = .summarizing
            store.update(video)

            let summary = try await VideoSummarizer.shared.summarize(
                transcript: transcriptText,
                title: result.title,
                durationSeconds: result.durationSeconds
            )

            video.tldr = summary.tldr
            video.thesis = summary.thesis
            video.actionItems = summary.actionItems
            video.topics = summary.topics

            // 5. Done.
            video.status = .done
            video.errorMessage = nil
            store.update(video)
        } catch {
            video.status = .failed
            video.errorMessage = error.localizedDescription
            store.update(video)
        }
    }

    // MARK: - Redo flows

    /// Re-run ONLY summarization on a video's EXISTING stored transcript — no
    /// re-download, no re-transcribe. Cheap path for "the summary was bad, try
    /// again." Updates the stored row in place (by id) through
    /// `.summarizing → .done`, or `.failed` on error. If the transcript is empty
    /// there is nothing to summarize, so we fall back to a full `reprocess`.
    func redoSummary(_ video: TranscribedVideo) async {
        let transcript = video.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            // Nothing stored to summarize — go re-fetch from source instead.
            await reprocess(video)
            return
        }

        var working = video
        working.status = .summarizing
        working.errorMessage = nil
        store.update(working)

        isRunning = true
        defer { isRunning = false }

        do {
            let summary = try await VideoSummarizer.shared.summarize(
                transcript: working.transcript,
                title: working.title,
                durationSeconds: working.durationSeconds
            )

            working.tldr = summary.tldr
            working.thesis = summary.thesis
            working.actionItems = summary.actionItems
            working.topics = summary.topics

            working.status = .done
            working.errorMessage = nil
            store.update(working)
        } catch {
            working.status = .failed
            working.errorMessage = error.localizedDescription
            store.update(working)
        }
    }

    /// Full re-run from the original `sourceURL`: same ingest → transcribe →
    /// summarize pipeline as `transcribeVideo`, but UPDATING the existing stored
    /// row (same id) instead of adding a new one — so it never creates a
    /// duplicate. The video's `id`, `addedAt`, and `chatMessages` are preserved
    /// across the rebuild.
    func reprocess(_ video: TranscribedVideo) async {
        let trimmed = video.sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            var failed = video
            failed.status = .failed
            failed.errorMessage = "Cannot reprocess: no source URL on record."
            store.update(failed)
            return
        }

        // Identity to carry through the whole rebuild.
        let id = video.id
        let addedAt = video.addedAt
        let chatMessages = video.chatMessages

        // Reset the existing row to `.ingesting` in place (no new row added).
        var working = video
        working.status = .ingesting
        working.errorMessage = nil
        store.update(working)

        isRunning = true
        defer { isRunning = false }

        do {
            // 1. Ingest: metadata + captions-or-audio.
            let result = try await VideoIngestService().ingest(urlString: trimmed)

            // Rebuild the record, preserving id / addedAt / chatMessages.
            working = TranscribedVideo(
                id: id,
                sourceURL: result.sourceURL,
                title: result.title,
                channel: result.channel,
                durationSeconds: result.durationSeconds,
                thumbnailLocalPath: result.thumbnailLocalPath ?? result.thumbnailURL,
                addedAt: addedAt,
                transcript: "",
                status: .ingesting,
                chatMessages: chatMessages
            )
            store.update(working)

            // 2. Transcript: captions fast-path, or local ASR on the WAV.
            let transcriptText: String
            switch result.transcript {
            case .captions(let text):
                transcriptText = text
            case .needsLocalASR(let wavPath):
                working.status = .transcribing
                store.update(working)
                transcriptText = try await runLocalASR(wavPath: wavPath)
            }

            working.transcript = transcriptText
            store.update(working)

            // 3. Summarize.
            working.status = .summarizing
            store.update(working)

            let summary = try await VideoSummarizer.shared.summarize(
                transcript: transcriptText,
                title: result.title,
                durationSeconds: result.durationSeconds
            )

            working.tldr = summary.tldr
            working.thesis = summary.thesis
            working.actionItems = summary.actionItems
            working.topics = summary.topics

            // 4. Done.
            working.status = .done
            working.errorMessage = nil
            store.update(working)
        } catch {
            working.status = .failed
            working.errorMessage = error.localizedDescription
            store.update(working)
        }
    }

    // MARK: - Local ASR

    /// Transcribe a 16 kHz mono WAV via the shared TranscriptionEngine. Loads
    /// models on demand (idempotent — `prepare()` returns early if ready), then
    /// runs the batch file pass and joins the segment text.
    private func runLocalASR(wavPath: String) async throws -> String {
        let engine = TranscriptionService()
        try await engine.prepare()
        let segments = try await engine.transcribeFile(url: URL(fileURLWithPath: wavPath))
        return segments
            .map { $0.text.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
