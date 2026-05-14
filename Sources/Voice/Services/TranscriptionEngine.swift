// VOICE — Transcription Engine Protocol
// ============================================================
// Abstract transcription backend. Lets us swap between engines
// (WhisperKit chunk-based, FluidAudio streaming, mock for tests)
// without touching the recording pipeline.
//
// Two surfaces — both drive the same underlying model:
//   1. Streaming (dictation):  start → feed → stop, plus partial AsyncStream
//   2. Batch (long meetings):  transcribe(audioChunk:chunkStartTime:)
//
// Implementors keep their own model state. `prepare()` is the
// download-and-load step; `isReady` flips true once the model is in memory.
// ============================================================

import Foundation

// MARK: - ModelState
// Shared by all engines. Drives the UI's ready/downloading badge.

enum ModelState: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case loading
    case ready
    case error(String)
}

// MARK: - TranscriptionEngine

protocol TranscriptionEngine: AnyObject {
    /// Live model lifecycle. Mirrors download → load → ready.
    var modelState: ModelState { get }

    /// True once the model is loaded and `start` / `transcribe` will work.
    var isReady: Bool { get }

    /// Download (if needed) and load the model into memory. Idempotent.
    func prepare() async throws

    // MARK: Streaming surface (dictation)

    /// Begin a fresh dictation session. Resets internal token state.
    func start() async throws

    /// Push 16 kHz mono Float32 PCM samples. The engine buffers internally
    /// and decodes on its own cadence. Safe to call from any actor.
    func feed(samples: [Float]) async

    /// Finalize the current session and return to idle state.
    ///
    /// Implementations that assemble transcripts inline (e.g. streaming engines)
    /// may return the final assembled segments here. Implementations that rely on
    /// a separate `transcribeFile(url:)` pass (e.g. FluidAudio / macparakeet)
    /// will return `[]` — the caller is responsible for invoking
    /// `transcribeFile(url:)` on the retained audio file after `stop()` returns.
    ///
    /// After return, the engine is idle until the next `start()`.
    func stop() async -> [TranscriptSegment]

    /// Live partial transcript while a session is active. Each emission is
    /// the *cumulative* current best-guess text, not a delta.
    var partialText: AsyncStream<String> { get }

    // MARK: Batch surface (long-form meetings)

    /// One-shot transcribe of a fixed audio buffer. Used by `MeetingRecorder`
    /// for its 30-second chunked long-form pipeline. Stateless — does not
    /// disturb a streaming session.
    func transcribe(
        audioChunk: [Float],
        chunkStartTime: TimeInterval
    ) async throws -> [TranscriptSegment]

    /// Batch-transcribe an entire audio file from disk. Used by
    /// `MeetingRecorder` for the post-meeting "re-transcribe for accuracy"
    /// pass that replaces the live streaming approximation with a canonical
    /// transcript carrying proper end-to-end timestamps.
    ///
    /// Expected file format: 16 kHz mono Float32 (the format
    /// `AudioCaptureService` writes). Other rates/channels will be downmixed
    /// + resampled by the implementation.
    func transcribeFile(url: URL) async throws -> [TranscriptSegment]

    /// Reset the speaker-detection heuristic at the start of a new dictation.
    /// Distinct from `start()` because the meeting flow does not use it.
    func resetSpeakerState()
}

// MARK: - TranscriptionError

enum TranscriptionError: LocalizedError {
    case notInitialized
    case modelNotFound
    case audioFormatError
    case streamingFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "Transcription engine not initialized. Call prepare() first."
        case .modelNotFound:
            return "Parakeet model not found. It may still be downloading."
        case .audioFormatError:
            return "Audio format error. Expected 16kHz mono Float32."
        case .streamingFailed(let msg):
            return "Streaming transcription failed: \(msg)"
        }
    }
}
