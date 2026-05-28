// PolishStatus.swift
//
// Singleton observable that exposes which polish engine is currently
// active. The transcribing pill watches `isCloudPolishing` so the cloud
// glyph only shows during the actual Cerebras request — not during ASR,
// not during local polish, not when idle.
//
// Set true when CerebrasPolisher starts a request; reset when the
// request returns (success or failure). Pure UI signal, no business logic.
//
// In addition to the live "in flight" flag, this object exposes per-call
// diagnostics for the most recent polish (engine, reason, latency, word
// counts, fallback count, sanitizer outcome, timestamp) plus a bounded
// history of the last 20 polishes so the UI can be honest about what
// happened on each call.

import Foundation
import SwiftUI
import os

/// One row in the recent-polish history. Captures everything the UI needs
/// to render a diagnostic list without re-running anything.
public struct PolishRecord: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let engine: String
    public let reason: String?
    public let latencyMs: Int
    public let inputWords: Int
    public let outputWords: Int
    public let fallbackCount: Int
    public let sanitizerRejected: Bool
    public let inputSample: String   // first 60 chars of input
    public let outputSample: String  // first 60 chars of output

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        engine: String,
        reason: String?,
        latencyMs: Int,
        inputWords: Int,
        outputWords: Int,
        fallbackCount: Int,
        sanitizerRejected: Bool,
        inputSample: String,
        outputSample: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.engine = engine
        self.reason = reason
        self.latencyMs = latencyMs
        self.inputWords = inputWords
        self.outputWords = outputWords
        self.fallbackCount = fallbackCount
        self.sanitizerRejected = sanitizerRejected
        self.inputSample = inputSample
        self.outputSample = outputSample
    }
}

public extension Notification.Name {
    /// Posted on the main actor after PolishStatus has finished recording a
    /// polish completion. UI views observing PolishStatus can either bind
    /// directly via @Observable or listen to this name as a coarse signal.
    static let voicePolishComplete = Notification.Name("voice.polishComplete")
}

@Observable
@MainActor
public final class PolishStatus {
    public static let shared = PolishStatus()

    /// True while a Cerebras request is in flight. The transcribing pill
    /// reads this to morph between the breathing circle and a cloud icon.
    public var isCloudPolishing: Bool = false

    // MARK: - Most-recent-polish snapshot

    /// Engine label of the most recent polish, used by the history view.
    /// Format: "cloud:qwen-3-235b" / "cloud:gpt-oss-120b" / "local:qwen3-4b"
    /// / "local:qwen3-1.7b" / "rules-only"
    public var lastEngine: String?

    /// Human-readable explanation of the routing decision for the most
    /// recent polish. Examples:
    ///   "word count 12 > 8 threshold, Cerebras configured"
    ///   "Cerebras 429 → Groq fallback"
    ///   "Cerebras timeout 3s → local"
    public var lastReason: String?

    /// Wall-clock latency of the most recent polish, in milliseconds.
    public var lastLatencyMs: Int = 0

    /// Whitespace-split word count of the input text.
    public var lastInputWordCount: Int = 0

    /// Whitespace-split word count of the polished output text.
    public var lastOutputWordCount: Int = 0

    /// How many engines were attempted before one succeeded.
    /// 1 = primary succeeded, 2 = primary failed and a fallback succeeded, etc.
    public var lastFallbackCount: Int = 0

    /// True if the sanitizer rejected the model output and the caller fell
    /// back to the raw / unpolished text.
    public var lastSanitizerRejected: Bool = false

    /// When the most recent polish completed.
    public var lastTimestamp: Date?

    /// Ring buffer of the last 20 polish records, newest first.
    public var recentPolishes: [PolishRecord] = []

    /// Hard cap on `recentPolishes` length.
    private let historyLimit = 20

    private static let logger = Logger(subsystem: "voice", category: "polish")

    private init() {}

    // MARK: - Recording

    /// Single entry point for recording the completion of one polish call.
    ///
    /// Safe to call from any actor / thread — internally hops to the main
    /// actor before mutating @Observable state. Updates the "last*" fields,
    /// appends to `recentPolishes` (trimming to the most recent 20), emits a
    /// structured log line, and posts `.voicePolishComplete`.
    public nonisolated func record(
        engine: String,
        reason: String?,
        latencyMs: Int,
        inputWords: Int,
        outputWords: Int,
        fallbackCount: Int,
        sanitizerRejected: Bool,
        inputSample: String,
        outputSample: String
    ) {
        let timestamp = Date()
        let record = PolishRecord(
            timestamp: timestamp,
            engine: engine,
            reason: reason,
            latencyMs: latencyMs,
            inputWords: inputWords,
            outputWords: outputWords,
            fallbackCount: fallbackCount,
            sanitizerRejected: sanitizerRejected,
            inputSample: inputSample,
            outputSample: outputSample
        )

        // Structured trace — one line per polish call, grep-friendly.
        let reasonField = reason.map { "\"\($0)\"" } ?? "-"
        let sanitizerField = sanitizerRejected ? "sanitizerRejected" : "sanitizerOK"
        let traceLine = "[VOICE-POLISH] engine=\(engine) reason=\(reasonField) latency=\(latencyMs)ms in=\(inputWords)w out=\(outputWords)w fallbacks=\(fallbackCount) \(sanitizerField)"
        Self.logger.log("\(traceLine, privacy: .public)")

        Task { @MainActor in
            self.applyRecord(record)
        }
    }

    /// Main-actor mutation half of `record`. Pulled out so the nonisolated
    /// public entry point stays a thin wrapper.
    @MainActor
    private func applyRecord(_ record: PolishRecord) {
        lastEngine = record.engine
        lastReason = record.reason
        lastLatencyMs = record.latencyMs
        lastInputWordCount = record.inputWords
        lastOutputWordCount = record.outputWords
        lastFallbackCount = record.fallbackCount
        lastSanitizerRejected = record.sanitizerRejected
        lastTimestamp = record.timestamp

        recentPolishes.insert(record, at: 0)
        if recentPolishes.count > historyLimit {
            recentPolishes.removeLast(recentPolishes.count - historyLimit)
        }

        NotificationCenter.default.post(name: .voicePolishComplete, object: self)
    }
}
