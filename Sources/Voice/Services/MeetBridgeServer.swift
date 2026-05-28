// MeetBridgeServer.swift
// ============================================================
// Minimal HTTP server on localhost:59423 that receives signals
// from the "Voice Meet Bridge" Chrome extension.
//
// The extension POSTs to:
//   http://127.0.0.1:59423/meet?active=true   (joined a meeting)
//   http://127.0.0.1:59423/meet?active=false  (left a meeting)
//
// We parse "active=true" / "active=false" from the raw HTTP request
// text (the query string appears in the GET/POST line) and call
// the onMeetActive callback on the main actor.
//
// No external dependencies — uses the Network framework only.
// ============================================================

import Foundation
import Network

@MainActor
final class MeetBridgeServer {

    // Called on the main actor whenever the meeting state changes.
    // The second argument is the list of participant names scraped from the
    // call platform's DOM by the Chrome extension (excluding the local user).
    // It is `[]` when the extension didn't / couldn't provide names — callers
    // should fall back to their existing name-extraction path in that case.
    var onMeetActive: ((Bool, [String]) -> Void)?

    /// Called on the main actor for every Google Meet active-speaker change.
    /// `name` is the participant whose tile lit up / went dim, `active` is
    /// true when they started talking and false when they stopped, and
    /// `timestamp` is the wall-clock moment the change was observed in the
    /// browser. Used by MeetingCaptureService to label transcript segments.
    var onSpeakerEvent: ((_ name: String, _ active: Bool, _ timestamp: Date) -> Void)?

    private var listener: NWListener?
    private let port: NWEndpoint.Port = 59423
    /// Bounded retry counter for transient listener failures. We never retry
    /// indefinitely — a duplicate Voice instance owning port 59423 should not
    /// trigger a forever-loop of binds.
    private var retryAttempts: Int = 0
    private let maxRetryAttempts: Int = 3

    // MARK: - Start / Stop

    func start() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        guard let l = try? NWListener(using: params, on: port) else {
            print("[MeetBridge] Could not bind to port \(port)")
            return
        }
        listener = l

        l.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                print("[MeetBridge] Listening on port \(self.port.rawValue)")
                Task { @MainActor in self.retryAttempts = 0 }
            case .failed(let err):
                // POSIX 48 = EADDRINUSE — almost always "another Voice is
                // running". Don't retry on that; just log and give up so the
                // duplicate instance fails gracefully.
                let isAddrInUse: Bool = {
                    if case .posix(let code) = err {
                        return code == .EADDRINUSE
                    }
                    return false
                }()
                Task { @MainActor in
                    self.listener?.cancel()
                    self.listener = nil
                    if isAddrInUse {
                        print("[MeetBridge] Port \(self.port.rawValue) already in use (another Voice instance?) — giving up. \(err)")
                        return
                    }
                    if self.retryAttempts >= self.maxRetryAttempts {
                        print("[MeetBridge] Failed \(self.retryAttempts) times — giving up: \(err)")
                        return
                    }
                    self.retryAttempts += 1
                    print("[MeetBridge] Failed: \(err) — retry \(self.retryAttempts)/\(self.maxRetryAttempts) in 5 s")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                        self?.start()
                    }
                }
            default:
                break
            }
        }

        l.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.handle(connection)
        }

        l.start(queue: .global(qos: .utility))
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Per-connection handling

    nonisolated private func handle(_ connection: NWConnection) {
        // Self-cancel if the connection dies before/during read so we don't
        // leak NWConnection state when Chrome opens many short-lived sockets
        // (e.g. user tab-hops across Meet calls rapidly).
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled:
                connection.stateUpdateHandler = nil
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .utility))

        // Read up to 2 KB — more than enough for a small HTTP request.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 2048) { [weak self] data, _, _, error in
            // If receive errored or the peer closed before sending anything,
            // close immediately so we don't sit on an orphan connection.
            if error != nil || (data == nil) {
                connection.cancel()
                return
            }
            // Two endpoints share one parser:
            //   /meet     → meeting state + participant-name list
            //   /speaker  → active-speaker name/active/timestamp tuple
            // We dispatch on the request path. parseSpeaker returns nil when
            // the path is not /speaker, so /meet falls through to the
            // existing active/names path unchanged.
            let active: Bool?
            var names: [String] = []
            var speaker: (name: String, active: Bool, t: Date)? = nil
            var isSpeakerPath = false
            if let data, let text = String(data: data, encoding: .utf8) {
                isSpeakerPath = Self.requestPath(fromRequest: text).hasPrefix("/speaker")
                if isSpeakerPath {
                    active = nil
                    speaker = Self.parseSpeaker(fromRequest: text)
                } else {
                    if text.contains("active=true") {
                        active = true
                    } else if text.contains("active=false") {
                        active = false
                    } else {
                        active = nil  // OPTIONS preflight or unknown — ignore
                    }
                    names = Self.parseNames(fromRequest: text)
                }
            } else {
                active = nil
            }

            // Send 200 OK with CORS headers, then cancel after the send drains.
            let response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: POST, OPTIONS\r\nConnection: close\r\n\r\n"
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })

            if isSpeakerPath {
                if let sp = speaker {
                    DispatchQueue.main.async { [weak self] in
                        self?.onSpeakerEvent?(sp.name, sp.active, sp.t)
                    }
                }
                return
            }

            guard let active else { return }
            if !names.isEmpty {
                print("[MeetBridge] Received active=\(active) names=\(names) from Chrome extension")
            } else {
                print("[MeetBridge] Received active=\(active) from Chrome extension")
            }
            DispatchQueue.main.async { [weak self] in
                self?.onMeetActive?(active, names)
            }
        }
    }

    // MARK: - Query string parsing

    /// Extract the `names=` query parameter from the raw HTTP request text and
    /// return it as `[String]`. We deliberately do NOT pull in URLComponents
    /// because the input is a raw HTTP request, not a URL — we just need the
    /// path/query line. Returns `[]` when the parameter is missing or empty.
    /// `nonisolated` because it's called from the connection-receive callback,
    /// which runs on a background queue — the parser touches no instance state.
    /// Pull the request-target path out of a raw HTTP request, without the
    /// query string. Returns `""` when the request can't be parsed.
    nonisolated static func requestPath(fromRequest text: String) -> String {
        guard let firstLine = text.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first else {
            return ""
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return "" }
        let target = String(parts[1])
        if let qIdx = target.firstIndex(of: "?") {
            return String(target[..<qIdx])
        }
        return target
    }

    /// Parse `/speaker?name=Alice&active=true&t=1747700000000` from a raw HTTP
    /// request. Returns nil when any required field is missing or malformed.
    /// Same nonisolated rules as parseNames: pure function, no state.
    nonisolated static func parseSpeaker(fromRequest text: String) -> (name: String, active: Bool, t: Date)? {
        guard let firstLine = text.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first else {
            return nil
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let target = String(parts[1])
        guard let qIdx = target.firstIndex(of: "?") else { return nil }
        let query = String(target[target.index(after: qIdx)...])

        var name: String? = nil
        var active: Bool? = nil
        var tMs: Double? = nil
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { continue }
            let key = String(kv[0])
            let rawValue = String(kv[1])
            switch key {
            case "name":
                let decoded = rawValue.removingPercentEncoding ?? rawValue
                let trimmed = decoded.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { name = trimmed }
            case "active":
                if rawValue == "true" { active = true }
                else if rawValue == "false" { active = false }
            case "t":
                tMs = Double(rawValue)
            default:
                continue
            }
        }
        guard let n = name, let a = active else { return nil }
        let timestamp: Date
        if let ms = tMs { timestamp = Date(timeIntervalSince1970: ms / 1000.0) }
        else { timestamp = Date() }
        return (n, a, timestamp)
    }

    nonisolated static func parseNames(fromRequest text: String) -> [String] {
        // First line: e.g. "POST /meet?active=true&names=Alice,Bob HTTP/1.1".
        guard let firstLine = text.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first else {
            return []
        }
        // Pull out the request-target token (the bit between the method and the version).
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return [] }
        let target = String(parts[1])
        guard let qIdx = target.firstIndex(of: "?") else { return [] }
        let query = String(target[target.index(after: qIdx)...])
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2, kv[0] == "names" else { continue }
            let rawValue = String(kv[1])
            // Each name was individually URL-encoded by the extension, then
            // joined with literal commas. Split first, then percent-decode.
            return rawValue
                .split(separator: ",")
                .map { String($0).removingPercentEncoding ?? String($0) }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        return []
    }
}
