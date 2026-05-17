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
//   Telemetry.logURL  -> URL?
//
// Auto-rotates at 5MB: events.jsonl -> events.jsonl.1 (clobbered).
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
