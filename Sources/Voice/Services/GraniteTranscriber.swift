// VOICE — IBM Granite 4.0 1B Speech Transcriber
// ============================================================
// Manages a persistent Python subprocess (granite_server.py) that loads
// the model once at startup and handles transcription requests via
// stdin/stdout JSON — one newline-delimited JSON object per message.
//
// Protocol:
//   Startup:  server writes {"status":"ready"} | {"status":"unavailable",...}
//   Request:  we write {"path":"/abs/path.caf"}\n
//   Response: server writes {"text":"..."} | {"error":"..."}\n
//
// Falls back silently to nil if Python / mlx_audio is not installed.
// The entire dual-model path is optional — Parakeet v2 is always the fallback.
// ============================================================

import Foundation

actor GraniteTranscriber {
    static let shared = GraniteTranscriber()

    // MARK: - State

    enum State: CustomStringConvertible {
        case idle
        case starting
        case ready
        case unavailable(String)
        case failed(String)

        var isReady: Bool { if case .ready = self { return true } else { return false } }

        var description: String {
            switch self {
            case .idle:                 return "idle"
            case .starting:             return "starting"
            case .ready:                return "ready"
            case .unavailable(let r):   return "unavailable(\(r))"
            case .failed(let r):        return "failed(\(r))"
            }
        }
    }

    private(set) var state: State = .idle

    // MARK: - Subprocess handles

    private var process: Process?
    private var stdinHandle: FileHandle?

    // MARK: - Line delivery (actor-isolated async queue)
    //
    // The background I/O thread delivers lines via incomingLine() / incomingEOF()
    // which post Task { await self._deliver(_:) } onto the actor's executor.
    // nextLine() registers a CheckedContinuation that is resumed by _deliver().
    // A timeout path calls _cancelWaiting() which resumes the continuation with
    // nil and removes it — preventing double-resume if a line arrives late.

    private var bufferedLines: [String] = []
    private var waitingContinuation: CheckedContinuation<String?, Never>? = nil
    private var isEOF = false

    // Called from the I/O thread (nonisolated) — hops onto actor executor.
    nonisolated func incomingLine(_ line: String) {
        Task { await self._deliver(line) }
    }

    nonisolated func incomingEOF() {
        Task { await self._deliverEOF() }
    }

    private func _deliver(_ line: String) {
        if let cont = waitingContinuation {
            waitingContinuation = nil
            cont.resume(returning: line)
        } else {
            bufferedLines.append(line)
        }
    }

    private func _deliverEOF() {
        isEOF = true
        state = .failed("Subprocess died unexpectedly")
        stdinHandle = nil
        if let cont = waitingContinuation {
            waitingContinuation = nil
            cont.resume(returning: nil)
        }
        print("[VOICE-Granite] Subprocess died — marking failed")
    }

    private func _cancelWaiting() {
        if let cont = waitingContinuation {
            waitingContinuation = nil
            cont.resume(returning: nil)
        }
    }

    // Wait for the next line from the subprocess. Returns nil on EOF.
    private func nextLine() async -> String? {
        if !bufferedLines.isEmpty { return bufferedLines.removeFirst() }
        if isEOF { return nil }
        return await withCheckedContinuation { cont in
            // Runs synchronously on actor executor — safe to mutate state.
            self.waitingContinuation = cont
        }
    }

    // Wait for the next line with a deadline. Returns nil on timeout or EOF.
    private func nextLine(timeout seconds: Double) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask { await self.nextLine() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                // Clear any registered waiter so late-arriving lines don't
                // resume a continuation after the consumer has moved on.
                await self._cancelWaiting()
                return nil
            }
            let result = await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - Python discovery

    private static let pythonCandidates: [String] = [
        "/opt/homebrew/bin/python3.11",
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3.11",
        "/usr/local/bin/python3",
        "/usr/bin/python3",
    ]

    private static func findPython() -> String? {
        pythonCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func scriptPath() -> String? {
        // Xcode app target — resources land in Bundle.main. (Bundle.module is
        // SPM-only and isn't generated for .xcodeproj targets.)
        if let bundled = Bundle.main.path(forResource: "granite_server", ofType: "py") {
            return bundled
        }
        // Final fallback: executable directory based on Bundle.main.
        // CommandLine.arguments[0] is unreliable when launched via `open` or
        // Spotlight (it can resolve to the .app wrapper path, not the actual
        // executable). Bundle.main.executableURL is the canonical lookup.
        if let execURL = Bundle.main.executableURL {
            let candidate = execURL.deletingLastPathComponent()
                .appendingPathComponent("granite_server.py").path
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }

    // MARK: - Lifecycle

    /// Start the Granite subprocess. Call once at app launch — non-blocking,
    /// failures are silent. Subsequent calls are no-ops.
    func start() async {
        guard case .idle = state else { return }
        state = .starting
        print("[VOICE-Granite] Starting server…")

        guard let python = Self.findPython() else {
            state = .unavailable("Python 3 not found (install via Homebrew)")
            print("[VOICE-Granite] Python not found — dual-model disabled")
            return
        }

        guard let script = Self.scriptPath() else {
            state = .unavailable("granite_server.py not bundled in app")
            print("[VOICE-Granite] Script not found — dual-model disabled")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = [script]

        let stdin  = Pipe()
        let stdout = Pipe()
        proc.standardInput  = stdin
        proc.standardOutput = stdout
        proc.standardError  = FileHandle.nullDevice

        do {
            try proc.launch()
        } catch {
            state = .failed("Process launch failed: \(error.localizedDescription)")
            print("[VOICE-Granite] Launch failed: \(error)")
            return
        }

        self.process     = proc
        self.stdinHandle = stdin.fileHandleForWriting

        // Start I/O reader on a raw thread (availableData blocks).
        let capture = self          // strong ref — process lifetime
        let handle  = stdout.fileHandleForReading
        Thread.detachNewThread {
            var buffer = Data()
            while true {
                let chunk = handle.availableData   // blocks until data available
                if chunk.isEmpty { capture.incomingEOF(); break }
                buffer.append(chunk)
                // Extract complete newline-terminated lines.
                while let idx = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let lineData = Data(buffer[buffer.startIndex ..< idx])
                    let line = String(data: lineData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !line.isEmpty { capture.incomingLine(line) }
                    buffer = Data(buffer[buffer.index(after: idx)...])
                }
            }
        }

        // Wait up to 30s for the startup handshake (first run may download model).
        guard let startupLine = await nextLine(timeout: 30),
              let data = startupLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            state = .failed("No startup handshake from Granite server")
            proc.terminate()
            print("[VOICE-Granite] No handshake — dual-model disabled")
            return
        }

        let status = json["status"] as? String ?? ""
        if status == "ready" {
            state = .ready
            print("[VOICE-Granite] ✓ Ready")
        } else {
            let reason = json["reason"] as? String ?? "model unavailable"
            state = .unavailable(reason)
            print("[VOICE-Granite] Unavailable: \(reason)")
        }
    }

    // MARK: - Transcription

    /// Count of consecutive transcription errors. After 3, we mark the server
    /// unhealthy and return nil immediately on future calls — avoids the user
    /// paying an 8s timeout on every dictation when the backend is broken.
    private var consecutiveErrors: Int = 0
    private let errorThreshold = 3

    /// Transcribe an audio file via Granite. Returns nil if unavailable or timed out.
    /// Timeout is 8s — Granite on warm model is ~1-2s; allow extra for first inference.
    func transcribe(url: URL) async -> String? {
        guard state.isReady, let stdin = stdinHandle else {
            return nil
        }
        if consecutiveErrors >= errorThreshold {
            // Circuit breaker — backend has been failing, stop wasting time.
            return nil
        }

        let request: [String: Any] = ["path": url.path]
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let line = String(data: data, encoding: .utf8)
        else { return nil }

        let payload = (line + "\n").data(using: .utf8)!
        do {
            try stdin.write(contentsOf: payload)
        } catch {
            print("[VOICE-Granite] Write failed: \(error) — subprocess likely dead")
            state = .failed("Write failed: \(error.localizedDescription)")
            stdinHandle = nil
            return nil
        }

        guard let responseLine = await nextLine(timeout: 8.0),
              let responseData = responseLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        else {
            print("[VOICE-Granite] Response timeout or bad JSON")
            return nil
        }

        if let text = json["text"] as? String, !text.isEmpty {
            consecutiveErrors = 0
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            print("[VOICE-Granite] ← '\(t.prefix(80))'")
            return t
        }
        if let error = json["error"] as? String {
            consecutiveErrors += 1
            print("[VOICE-Granite] Error (\(consecutiveErrors)/\(errorThreshold)): \(error)")
            if consecutiveErrors >= errorThreshold {
                print("[VOICE-Granite] Circuit breaker tripped — dual-model disabled this session")
            }
        }
        return nil
    }

    // MARK: - Shutdown

    func shutdown() {
        if let proc = process, proc.isRunning {
            print("[VOICE-Granite] Shutting down subprocess (PID \(proc.processIdentifier))")
            proc.terminate()
        }
        process = nil
        stdinHandle = nil
        state = .idle
    }
}
