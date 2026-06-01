// Telemetry.swift
// ============================================================
// LOCAL-ONLY event log. Never sends a single byte over the
// network. Writes append-only JSON-lines to:
//
//     ~/Library/Application Support/Voice/events.jsonl
//
// Helps users (and us, when they share the file) debug issues
// without crash reporters or analytics SDKs.
//
// Public API:
//   Telemetry.log("event_name", properties: [...])
//   Telemetry.signal("phase", "detail", properties: [...])  // state transitions
//   Telemetry.snapshot(reason:, extra:)                     // health/config dump
//   Telemetry.maskKey(_:)  -> "csk-abcd…(len 51)"           // never logs secrets
//   Telemetry.logURL  -> URL?
//
// Auto-rotates at 5MB: events.jsonl -> events.jsonl.1 (clobbered).
//
// SECRETS: never pass a raw API key into `properties`. Use `maskKey()`
// which keeps only a short prefix + length. The snapshot builder masks
// the Cerebras key for you.
// ============================================================

import Foundation

enum Telemetry {

    private static let queue = DispatchQueue(label: "voice.telemetry", qos: .utility)
    private static let maxBytes: UInt64 = 5 * 1024 * 1024
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// File URL for the current event log. Returns nil if Application Support
    /// can't be resolved (very rare; treat as best-effort).
    static var logURL: URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let dir = appSupport.appendingPathComponent("Voice", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true
            )
        }
        return dir.appendingPathComponent("events.jsonl")
    }

    /// Append a JSON-line event. Safe to call from any thread / actor.
    /// Properties are best-effort serialised; non-JSON values become "<unencodable>".
    static func log(_ event: String, properties: [String: Any] = [:]) {
        let timestamp = isoFormatter.string(from: Date())
        let payload = sanitize(properties)
        var record: [String: Any] = [
            "ts": timestamp,
            "event": event
        ]
        for (k, v) in payload { record[k] = v }

        queue.async {
            guard let url = logURL else { return }
            rotateIfNeeded(at: url)
            guard let data = try? JSONSerialization.data(
                withJSONObject: record,
                options: [.sortedKeys]
            ) else { return }

            var line = data
            line.append(0x0A)  // newline

            if FileManager.default.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: line)
                }
            } else {
                try? line.write(to: url, options: .atomic)
            }
        }
    }

    // MARK: - Signals (cheap structured state-transition events)

    /// Emit a structured state-transition / error signal. Thin wrapper over
    /// `log` that namespaces everything under a consistent shape so concurrent
    /// flows can be untangled and grepped in events.jsonl:
    ///
    ///   {"event":"<phase>","detail":"<detail>", ...properties}
    ///
    /// Examples:
    ///   Telemetry.signal("recording.start", "ptt", ["session": sid])
    ///   Telemetry.signal("paste.failure", "secure_field", ["chars": 42])
    ///
    /// Cheap by design — the actual file write hops to the utility queue, so
    /// callers on the hot path (paste, recording start/stop) pay only a
    /// dictionary build + async enqueue.
    static func signal(_ phase: String, _ detail: String = "", _ properties: [String: Any] = [:]) {
        var props = properties
        if !detail.isEmpty { props["detail"] = detail }
        log(phase, properties: props)
    }

    /// Redact an API key down to a short prefix + length so the JSONL log
    /// proves *which* key is loaded (or that none is) WITHOUT ever writing the
    /// secret. Empty input → "<none>". Short input → "<set len N>" (no prefix,
    /// so a tiny accidental value can't be reconstructed).
    static func maskKey(_ key: String) -> String {
        if key.isEmpty { return "<none>" }
        guard key.count >= 8 else { return "<set len \(key.count)>" }
        return "\(key.prefix(4))…(len \(key.count))"
    }

    // MARK: - Debug snapshot (one-shot health/config dump)

    /// Emit a `debug.snapshot` event capturing current health/config at a
    /// glance. Call at app launch, on failures, and any time the state would
    /// help a reader of events.jsonl understand context.
    ///
    /// `reason` records WHY the snapshot fired (e.g. "launch", "error",
    /// "paste_failure"). `extra` is merged in for caller-specific context
    /// (recent failure reasons, engine in use, etc.). The Cerebras key is
    /// always masked here — callers pass the raw key and we redact it.
    ///
    /// Schema (event "debug.snapshot"):
    ///   ts                ISO8601 timestamp (from log())
    ///   reason            String — trigger ("launch" | "error" | ...)
    ///   app_version       CFBundleShortVersionString
    ///   app_build         CFBundleVersion
    ///   os                operatingSystemVersionString
    ///   cloud_enabled     Bool — Cerebras toggle
    ///   cloud_key         String — masked key prefix, never the full key
    ///   wake_word         String — wake-word mode ("off" | ...)
    ///   meeting_detect    Bool — meeting auto-detection enabled
    ///   default_model     String — audio source / engine in use
    ///   accessibility     Bool — AXIsProcessTrusted()
    ///   ... + any keys in `extra`
    static func snapshot(reason: String, extra: [String: Any] = [:]) {
        let info = Bundle.main.infoDictionary
        var props: [String: Any] = [
            "reason": reason,
            "app_version": info?["CFBundleShortVersionString"] as? String ?? "?",
            "app_build": info?["CFBundleVersion"] as? String ?? "?",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        // Merge caller-supplied context (engine, failure reasons, config flags).
        // Callers pass the raw key under "cloud_key_raw"; we mask it here so the
        // secret never leaves this function unredacted.
        for (k, v) in extra {
            if k == "cloud_key_raw", let raw = v as? String {
                props["cloud_key"] = maskKey(raw)
            } else {
                props[k] = v
            }
        }
        log("debug.snapshot", properties: props)
    }

    // MARK: - Private

    /// Coerce values into JSON-safe representations. Anything that
    /// JSONSerialization can't handle becomes its string description.
    private static func sanitize(_ props: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in props {
            if JSONSerialization.isValidJSONObject([k: v]) {
                out[k] = v
            } else {
                out[k] = String(describing: v)
            }
        }
        return out
    }

    /// Rotate the log if it has grown past the 5MB ceiling.
    /// Single backup slot — events.jsonl.1 — overwritten each rotation.
    private static func rotateIfNeeded(at url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64,
              size >= maxBytes else { return }
        let backup = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: url, to: backup)
    }
}
