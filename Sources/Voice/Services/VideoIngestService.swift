// VOICE — Video Ingest Service
// ============================================================
// Backend for the "paste a video / YouTube URL → transcribe it" feature.
//
// Given a URL string, this service produces everything a downstream
// transcription + summarization step needs:
//
//   1. Metadata        — title, channel, duration, thumbnail, video id
//                        (via `yt-dlp --dump-json`)
//   2. Captions first  — if the video already has (auto-)captions we fetch
//                        and parse the VTT into plain text. This is the FAST
//                        path: no audio download, no local ASR.
//   3. Audio fallback  — if there are NO captions, download `bestaudio`,
//                        then transcode with ffmpeg to 16 kHz mono PCM WAV
//                        (the format `TranscriptionEngine.transcribeFile`
//                        expects — see TranscriptionEngine.swift /
//                        TranscriptionService.swift). The WAV path is
//                        returned so a downstream ASR pass can consume it.
//   4. Thumbnail       — downloaded to a local cache path so the UI grid
//                        works offline.
//
// Everything shells out to the system `yt-dlp` (/opt/homebrew/bin/yt-dlp)
// and `ffmpeg` (/opt/homebrew/bin/ffmpeg) via `Process`, falling back to a
// PATH lookup. Temp/cache files live under the user caches dir and are
// cleaned up on demand.
//
// Self-contained: only Foundation. An integrator wires this into the app
// and Xcode project separately.
// ============================================================

import Foundation

// MARK: - VideoIngestResult

/// The full output of ingesting a single video URL.
public struct VideoIngestResult: Sendable {
    /// The original URL that was ingested.
    public let sourceURL: String
    /// Provider-specific id (e.g. YouTube video id), if `yt-dlp` reported one.
    public let videoID: String?
    /// Display title.
    public let title: String
    /// Channel / uploader name, if available.
    public let channel: String?
    /// Duration in seconds, if available.
    public let durationSeconds: Double?
    /// Local file path of the downloaded thumbnail, if one was fetched.
    public let thumbnailLocalPath: String?
    /// Remote thumbnail URL as reported by `yt-dlp` (fallback if download failed).
    public let thumbnailURL: String?

    /// Where the transcript comes from.
    public enum Transcript: Sendable {
        /// Captions already existed; here is the parsed plain text.
        case captions(String)
        /// No captions — audio was downloaded + transcoded. The caller must
        /// run local ASR on this 16 kHz mono PCM WAV file.
        case needsLocalASR(audioWavPath: String)
    }

    public let transcript: Transcript
}

// MARK: - VideoIngestError

/// Errors surfaced by ``VideoIngestService``.
public enum VideoIngestError: LocalizedError {
    /// The supplied string was not a usable URL.
    case invalidURL(String)
    /// A `yt-dlp` invocation failed. Carries captured stderr.
    case ytDlpFailed(stderr: String, exitCode: Int32)
    /// An `ffmpeg` invocation failed. Carries captured stderr.
    case ffmpegFailed(stderr: String, exitCode: Int32)
    /// `yt-dlp` produced neither caption tracks nor a downloadable audio file.
    case noAudioOrCaptions
    /// Could not locate the `yt-dlp` or `ffmpeg` executable on this machine.
    case toolNotFound(String)
    /// `yt-dlp --dump-json` output could not be parsed.
    case metadataParseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let s):
            return "Not a valid URL: \(s)"
        case .ytDlpFailed(let stderr, let code):
            return "yt-dlp failed (exit \(code)): \(stderr)"
        case .ffmpegFailed(let stderr, let code):
            return "ffmpeg failed (exit \(code)): \(stderr)"
        case .noAudioOrCaptions:
            return "Video has no captions and no downloadable audio."
        case .toolNotFound(let tool):
            return "Required tool not found: \(tool). Install it via Homebrew."
        case .metadataParseFailed(let detail):
            return "Could not parse video metadata: \(detail)"
        }
    }
}

// MARK: - VideoIngestService

/// Downloads metadata + captions (or audio) for a video URL.
///
/// An `actor` so concurrent ingests don't trample each other's temp dirs and
/// so all the blocking `Process` work stays off the main thread.
public actor VideoIngestService {

    // MARK: Tool paths

    /// Homebrew defaults; we fall back to a PATH lookup if these don't exist.
    private static let ytDlpDefault = "/opt/homebrew/bin/yt-dlp"
    private static let ffmpegDefault = "/opt/homebrew/bin/ffmpeg"

    private let ytDlpPath: String
    private let ffmpegPath: String

    /// Root cache dir for downloaded artifacts (thumbnails + WAVs we keep).
    private let cacheRoot: URL

    /// - Parameters:
    ///   - ytDlpPath: override for the `yt-dlp` binary (defaults to Homebrew / PATH).
    ///   - ffmpegPath: override for the `ffmpeg` binary (defaults to Homebrew / PATH).
    public init(ytDlpPath: String? = nil, ffmpegPath: String? = nil) {
        self.ytDlpPath = ytDlpPath
            ?? Self.resolveTool("yt-dlp", default: Self.ytDlpDefault)
            ?? Self.ytDlpDefault
        self.ffmpegPath = ffmpegPath
            ?? Self.resolveTool("ffmpeg", default: Self.ffmpegDefault)
            ?? Self.ffmpegDefault

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.cacheRoot = caches.appendingPathComponent("VoiceVideoIngest", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    /// Ingest a single video URL.
    ///
    /// Order of operations:
    ///   1. Validate the URL.
    ///   2. Fetch metadata (`yt-dlp --dump-json`).
    ///   3. Download the thumbnail (best-effort).
    ///   4. Try captions; if found, return ``VideoIngestResult/Transcript/captions(_:)``.
    ///   5. Otherwise download audio + transcode to 16 kHz mono WAV and return
    ///      ``VideoIngestResult/Transcript/needsLocalASR(audioWavPath:)``.
    ///
    /// - Throws: ``VideoIngestError`` on any unrecoverable failure.
    public func ingest(urlString: String) async throws -> VideoIngestResult {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            throw VideoIngestError.invalidURL(urlString)
        }

        // Per-ingest scratch dir, cleaned up before we return.
        let work = cacheRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // 1. Metadata
        let meta = try await fetchMetadata(urlString: trimmed)

        // 2. Thumbnail (best-effort, kept under the persistent cache root)
        let thumbLocal = await downloadThumbnail(meta.thumbnailURL, videoID: meta.videoID)

        // 3. Captions-first fast path
        if let captionText = try await fetchCaptions(urlString: trimmed, workDir: work),
           !captionText.isEmpty {
            return VideoIngestResult(
                sourceURL: trimmed,
                videoID: meta.videoID,
                title: meta.title,
                channel: meta.channel,
                durationSeconds: meta.durationSeconds,
                thumbnailLocalPath: thumbLocal,
                thumbnailURL: meta.thumbnailURL,
                transcript: .captions(captionText)
            )
        }

        // 4. Audio fallback → 16 kHz mono WAV (kept under persistent cache root)
        let wavPath = try await downloadAndTranscodeAudio(
            urlString: trimmed,
            workDir: work,
            videoID: meta.videoID
        )

        return VideoIngestResult(
            sourceURL: trimmed,
            videoID: meta.videoID,
            title: meta.title,
            channel: meta.channel,
            durationSeconds: meta.durationSeconds,
            thumbnailLocalPath: thumbLocal,
            thumbnailURL: meta.thumbnailURL,
            transcript: .needsLocalASR(audioWavPath: wavPath)
        )
    }

    /// Delete all cached artifacts (thumbnails + WAVs) produced by this service.
    public func clearCache() {
        try? FileManager.default.removeItem(at: cacheRoot)
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
    }

    // MARK: - Metadata

    private struct Metadata {
        let title: String
        let channel: String?
        let durationSeconds: Double?
        let thumbnailURL: String?
        let videoID: String?
    }

    /// `yt-dlp --dump-json --no-playlist <url>` → parsed metadata.
    private func fetchMetadata(urlString: String) async throws -> Metadata {
        let result = try await runProcess(
            executable: ytDlpPath,
            args: ["--dump-json", "--no-playlist", "--no-warnings", urlString]
        )
        guard result.exitCode == 0 else {
            throw VideoIngestError.ytDlpFailed(stderr: result.stderr, exitCode: result.exitCode)
        }

        // `--dump-json` emits one JSON object per line; take the first.
        let firstLine = result.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? result.stdout

        guard let data = firstLine.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw VideoIngestError.metadataParseFailed("yt-dlp did not emit valid JSON")
        }

        let title = (obj["title"] as? String)
            ?? (obj["fulltitle"] as? String)
            ?? "Untitled"
        let channel = (obj["channel"] as? String)
            ?? (obj["uploader"] as? String)
            ?? (obj["uploader_id"] as? String)
        let duration: Double? = {
            if let d = obj["duration"] as? Double { return d }
            if let i = obj["duration"] as? Int { return Double(i) }
            if let s = obj["duration_string"] as? String { return Self.parseDuration(s) }
            return nil
        }()
        let videoID = obj["id"] as? String
        let thumbnail = (obj["thumbnail"] as? String) ?? Self.bestThumbnail(from: obj)

        return Metadata(
            title: title,
            channel: channel,
            durationSeconds: duration,
            thumbnailURL: thumbnail,
            videoID: videoID
        )
    }

    /// Pick the highest-preference thumbnail from the `thumbnails` array.
    private static func bestThumbnail(from obj: [String: Any]) -> String? {
        guard let thumbs = obj["thumbnails"] as? [[String: Any]] else { return nil }
        let sorted = thumbs.sorted { a, b in
            let pa = (a["preference"] as? Int) ?? Int((a["preference"] as? Double) ?? -999)
            let pb = (b["preference"] as? Int) ?? Int((b["preference"] as? Double) ?? -999)
            if pa != pb { return pa > pb }
            let wa = (a["width"] as? Int) ?? 0
            let wb = (b["width"] as? Int) ?? 0
            return wa > wb
        }
        return sorted.first?["url"] as? String
    }

    /// Parse "HH:MM:SS" / "MM:SS" into seconds.
    private static func parseDuration(_ s: String) -> Double? {
        let parts = s.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0.0) { $0 * 60 + $1 }
    }

    // MARK: - Captions

    /// Try to fetch an existing (manual or auto) English caption track and
    /// parse it into plain text. Returns `nil` if no caption file is produced.
    ///
    /// Uses:
    /// `yt-dlp --skip-download --write-subs --write-auto-subs
    ///         --sub-format vtt --sub-langs "en.*" -o <tmpl> <url>`
    private func fetchCaptions(urlString: String, workDir: URL) async throws -> String? {
        let template = workDir.appendingPathComponent("caption.%(ext)s").path
        let result = try await runProcess(
            executable: ytDlpPath,
            args: [
                "--skip-download",
                "--write-subs",
                "--write-auto-subs",
                "--sub-format", "vtt",
                "--sub-langs", "en.*",
                "--no-playlist",
                "--no-warnings",
                "-o", template,
                urlString
            ]
        )
        // A non-zero exit here is non-fatal — many videos simply have no subs.
        // We decide purely on whether a caption file landed on disk.
        _ = result

        let files = (try? FileManager.default.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil)) ?? []
        let captionFiles = files.filter {
            let ext = $0.pathExtension.lowercased()
            return ext == "vtt" || ext == "srt"
        }
        guard let captionURL = preferEnglish(captionFiles) else { return nil }

        guard let raw = try? String(contentsOf: captionURL, encoding: .utf8) else { return nil }
        let text = Self.parseCaptions(raw, ext: captionURL.pathExtension.lowercased())
        return text.isEmpty ? nil : text
    }

    /// Prefer a manual `en` track over an auto-generated / regional one.
    private func preferEnglish(_ files: [URL]) -> URL? {
        guard !files.isEmpty else { return nil }
        // Manual "en" beats "en-auto"/"en-US" etc. Shorter language tag ~= cleaner.
        return files.sorted { a, b in
            let an = a.lastPathComponent.lowercased()
            let bn = b.lastPathComponent.lowercased()
            let aAuto = an.contains("auto")
            let bAuto = bn.contains("auto")
            if aAuto != bAuto { return !aAuto }
            return an.count < bn.count
        }.first
    }

    /// Strip cue numbers, timestamps, WEBVTT headers, and inline markup from a
    /// VTT or SRT file, collapsing it into de-duplicated plain text.
    ///
    /// Auto-captions repeat rolling lines heavily, so we drop consecutive
    /// duplicate lines.
    static func parseCaptions(_ raw: String, ext: String) -> String {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var out: [String] = []
        var lastAdded = ""

        for rawLine in lines {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line == "WEBVTT" || line.hasPrefix("WEBVTT") { continue }
            if line.hasPrefix("Kind:") || line.hasPrefix("Language:")
                || line.hasPrefix("NOTE") || line.hasPrefix("STYLE") { continue }
            // SRT cue index: a bare integer line.
            if Int(line) != nil { continue }
            // Timestamp cue line: "00:00:01.000 --> 00:00:03.000 align:..."
            if line.contains("-->") { continue }

            // Strip VTT/SRT inline tags: <00:00:01.000>, <c>, </c>, <v Name>, etc.
            line = Self.stripTags(line)
            // Decode the handful of entities captions commonly carry.
            line = line
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&nbsp;", with: " ")
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            // Drop consecutive duplicates (rolling auto-caption artifact).
            if line == lastAdded { continue }
            out.append(line)
            lastAdded = line
        }

        return out.joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Remove any `<...>` markup span from a caption line.
    private static func stripTags(_ s: String) -> String {
        var result = ""
        result.reserveCapacity(s.count)
        var inTag = false
        for ch in s {
            if ch == "<" { inTag = true; continue }
            if ch == ">" { inTag = false; continue }
            if !inTag { result.append(ch) }
        }
        return result
    }

    // MARK: - Audio fallback

    /// Download `bestaudio`, extract to m4a, then transcode to 16 kHz mono WAV.
    ///
    /// Step 1: `yt-dlp -f bestaudio -x --audio-format m4a -o <tmpl> <url>`
    /// Step 2: `ffmpeg -y -i <in> -ac 1 -ar 16000 -c:a pcm_s16le <out>.wav`
    ///
    /// The WAV (16 kHz, mono) matches the format `TranscriptionEngine`
    /// expects (see TranscriptionEngine.swift / TranscriptionService.swift,
    /// which reads via AVAudioFile and resamples to 16 kHz mono Float32).
    ///
    /// - Returns: absolute path to the produced WAV, kept under the cache root.
    private func downloadAndTranscodeAudio(
        urlString: String,
        workDir: URL,
        videoID: String?
    ) async throws -> String {
        let audioTemplate = workDir.appendingPathComponent("audio.%(ext)s").path

        // Step 1 — download + extract audio.
        let dl = try await runProcess(
            executable: ytDlpPath,
            args: [
                "-f", "bestaudio/best",
                "-x",
                "--audio-format", "m4a",
                "--no-playlist",
                "--no-warnings",
                "-o", audioTemplate,
                urlString
            ]
        )
        guard dl.exitCode == 0 else {
            throw VideoIngestError.ytDlpFailed(stderr: dl.stderr, exitCode: dl.exitCode)
        }

        // Locate whatever audio file yt-dlp actually wrote (extension may vary
        // if the requested format wasn't honored).
        let produced = ((try? FileManager.default.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("audio.") }
        guard let inputAudio = produced.first else {
            throw VideoIngestError.noAudioOrCaptions
        }

        // Step 2 — transcode to 16 kHz mono signed-16-bit PCM WAV.
        let stem = videoID.map { Self.sanitize($0) } ?? UUID().uuidString
        let outWav = cacheRoot.appendingPathComponent("\(stem).wav")
        try? FileManager.default.removeItem(at: outWav)

        let conv = try await runProcess(
            executable: ffmpegPath,
            args: [
                "-y",
                "-i", inputAudio.path,
                "-ac", "1",            // mono
                "-ar", "16000",        // 16 kHz
                "-c:a", "pcm_s16le",   // signed 16-bit little-endian PCM
                outWav.path
            ]
        )
        guard conv.exitCode == 0,
              FileManager.default.fileExists(atPath: outWav.path) else {
            throw VideoIngestError.ffmpegFailed(stderr: conv.stderr, exitCode: conv.exitCode)
        }

        return outWav.path
    }

    // MARK: - Thumbnail

    /// Download the thumbnail to the cache and return its local path.
    /// Best-effort: returns `nil` on any failure (UI can fall back to the URL).
    private func downloadThumbnail(_ urlString: String?, videoID: String?) async -> String? {
        guard let urlString, let url = URL(string: urlString) else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard !data.isEmpty else { return nil }
            let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
            let stem = videoID.map { Self.sanitize($0) } ?? UUID().uuidString
            let dest = cacheRoot.appendingPathComponent("\(stem)_thumb.\(ext)")
            try data.write(to: dest, options: .atomic)
            return dest.path
        } catch {
            return nil
        }
    }

    // MARK: - Process helper

    private struct ProcessResult {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    /// Run a subprocess to completion, capturing stdout/stderr without
    /// deadlocking on large pipe buffers. Bridged into async via a
    /// continuation resumed from the process's `terminationHandler`.
    private func runProcess(executable: String, args: [String]) async throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw VideoIngestError.toolNotFound(executable)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args

            // Ensure Homebrew tools resolve their own deps regardless of the
            // sandboxed app's environment.
            var env = ProcessInfo.processInfo.environment
            let extraPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            env["PATH"] = (env["PATH"].map { "\(extraPath):\($0)" }) ?? extraPath
            process.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            // Drain pipes concurrently to avoid filling the OS buffer (which
            // would stall the child) on verbose ffmpeg/yt-dlp output.
            let outData = DataAccumulator()
            let errData = DataAccumulator()
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    outData.append(chunk)
                }
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    errData.append(chunk)
                }
            }

            process.terminationHandler = { proc in
                // Flush any residual buffered data.
                let restOut = outPipe.fileHandleForReading.readDataToEndOfFile()
                if !restOut.isEmpty { outData.append(restOut) }
                let restErr = errPipe.fileHandleForReading.readDataToEndOfFile()
                if !restErr.isEmpty { errData.append(restErr) }
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil

                let result = ProcessResult(
                    stdout: outData.string,
                    stderr: errData.string,
                    exitCode: proc.terminationStatus
                )
                continuation.resume(returning: result)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Resolve a tool: prefer the given absolute default, else `/usr/bin/which`.
    private static func resolveTool(_ name: String, default def: String) -> String? {
        if FileManager.default.isExecutableFile(atPath: def) { return def }
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        which.arguments = ["which", name]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = Pipe()
        do {
            try which.run()
            which.waitUntilExit()
            guard which.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let path, !path.isEmpty,
               FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        } catch {
            return nil
        }
        return nil
    }

    /// Make a string safe for use as a filename stem.
    private static func sanitize(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let cleaned = String(scalars)
        return cleaned.isEmpty ? UUID().uuidString : cleaned
    }
}

// MARK: - DataAccumulator

/// Thread-safe byte sink for draining `Process` pipes from background handlers.
private final class DataAccumulator: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
