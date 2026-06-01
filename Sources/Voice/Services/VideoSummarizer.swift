// VideoSummarizer.swift
//
// Summary-first output for transcribed video/YouTube content.
//
// Product insight: every other tool dumps a transcript wall. The useful thing
// is a tight TLDR + the thesis ("what is this video actually trying to say")
// + concrete action items, with the full transcript secondary. This service
// turns a raw transcript into that structured VideoSummary.
//
// It talks to the same NVIDIA NIM endpoint the app already uses for polish
// (mistralai/mistral-small-4-119b-2603, OpenAI-compatible /v1/chat/completions). It MIRRORS the
// request-construction approach in NVIDIAPolisher.swift — same endpoint, same
// model id, same Bearer-auth header, same SSE delta accumulation — and REUSES
// NVIDIAPolisher.apiKey for key retrieval rather than touching UserDefaults
// directly. It does not edit NVIDIAPolisher; it only reads it for the key.
//
// Differences from polishing:
//   - A summarization-specific system prompt (not dictation cleanup).
//   - Requests STRICT JSON and parses it defensively (strip code fences,
//     tolerate trailing text, find the outermost {...}).
//   - Longer timeouts and higher max_tokens — summaries can run long and the
//     model has to read a possibly-large transcript.
//   - Map-reduce for very long transcripts: chunk → summarize each chunk →
//     summarize the chunk summaries, so we never blow the context window.

import Foundation

// MARK: - Dash sanitization

// Models keep emitting em/en-dashes despite the prompt ban, so we strip them
// deterministically in code. This extension lives here and is reused by
// VideoChatService.swift (same module). Regular hyphens "-" are untouched.
extension String {
    /// Replace em-dashes (—) and en-dashes (–), with or without surrounding
    /// spaces, with ", ", then tidy up the resulting spacing/punctuation.
    /// Example: "mind—emotions, identity—and energy" -> "mind, emotions, identity, and energy".
    func strippingDashes() -> String {
        var s = self
        // Collapse a dash plus any surrounding spaces into a single ", ".
        s = s.replacingOccurrences(
            of: "\\s*[—–]\\s*",
            with: ", ",
            options: .regularExpression
        )
        // Tidy: collapse runs of spaces, and fix " ," -> ",".
        s = s.replacingOccurrences(of: " ,", with: ",")
        s = s.replacingOccurrences(
            of: " {2,}",
            with: " ",
            options: .regularExpression
        )
        return s
    }
}

// MARK: - Output model

public struct VideoSummary: Codable, Equatable {
    /// 2-4 sentence punchy summary.
    public let tldr: String
    /// One line: what the video is really arguing/saying.
    public let thesis: String
    /// Imperative, concrete; empty if the video implies no tasks.
    public let actionItems: [String]
    /// 3-6 key topics/sections.
    public let topics: [String]

    public init(tldr: String, thesis: String, actionItems: [String], topics: [String]) {
        self.tldr = tldr
        self.thesis = thesis
        self.actionItems = actionItems
        self.topics = topics
    }
}

// MARK: - Errors

public enum VideoSummarizerError: Error, LocalizedError {
    case notConfigured
    case emptyTranscript
    case requestFailed(String)
    case emptyResponse
    case jsonParseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "NVIDIA API key is not configured (set it in Settings)."
        case .emptyTranscript:
            return "Transcript is empty — nothing to summarize."
        case .requestFailed(let why):
            return "Summarization request failed: \(why)"
        case .emptyResponse:
            return "Model returned an empty response."
        case .jsonParseFailed(let why):
            return "Could not parse model output as JSON: \(why)"
        }
    }
}

// MARK: - Service

@MainActor
public final class VideoSummarizer {
    public static let shared = VideoSummarizer()
    public init() {}

    // Same NVIDIA NIM surface the app already uses for polish.
    private let model = "mistralai/mistral-small-4-119b-2603"
    private let endpoint = URL(string: "https://integrate.api.nvidia.com/v1/chat/completions")!

    // Summaries are bigger than dictation polish: read a long transcript, write
    // structured JSON. Be generous on both time and tokens.
    private let requestTimeout: TimeInterval = 60

    // Map-reduce threshold. Roughly 12k words. Words are counted by whitespace
    // splitting — cheap and good enough to decide whether to chunk.
    private let mapReduceWordThreshold = 12_000
    // Words per chunk for the map phase. ~3.5k words ≈ comfortable context with
    // room for prompt + completion.
    private let chunkWordSize = 3_500

    // MARK: - Public API

    /// Summarize a (possibly long) transcript into a structured, summary-first
    /// VideoSummary. `title` and `durationSeconds` are optional context hints.
    public func summarize(
        transcript: String,
        title: String?,
        durationSeconds: Double?
    ) async throws -> VideoSummary {
        guard NVIDIAPolisher.apiKey != nil else {
            throw VideoSummarizerError.notConfigured
        }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw VideoSummarizerError.emptyTranscript
        }

        let words = trimmed.split(whereSeparator: { $0.isWhitespace })
        if words.count > mapReduceWordThreshold {
            return try await summarizeLong(
                words: words,
                title: title,
                durationSeconds: durationSeconds
            )
        }

        let user = userMessage(transcript: trimmed, title: title, durationSeconds: durationSeconds)
        let raw = try await complete(system: summarizeSystemPrompt(), user: user, maxTokens: 2048)
        return try parseSummary(raw)
    }

    // MARK: - Map-reduce for long transcripts

    private func summarizeLong(
        words: [Substring],
        title: String?,
        durationSeconds: Double?
    ) async throws -> VideoSummary {
        // Map: break into chunks and produce a plain-prose digest of each.
        var chunkDigests: [String] = []
        var idx = 0
        var chunkNumber = 1
        let totalChunks = (words.count + chunkWordSize - 1) / chunkWordSize

        while idx < words.count {
            let end = min(idx + chunkWordSize, words.count)
            let chunkText = words[idx..<end].joined(separator: " ")
            idx = end

            let digest = try await complete(
                system: chunkDigestSystemPrompt(),
                user: "Part \(chunkNumber) of \(totalChunks) of the transcript:\n\n\(chunkText)",
                maxTokens: 700
            )
            chunkDigests.append("Part \(chunkNumber): \(digest.trimmingCharacters(in: .whitespacesAndNewlines))")
            chunkNumber += 1
        }

        // Reduce: feed the digests back through the structured summarizer.
        let combined = chunkDigests.joined(separator: "\n\n")
        let user = userMessage(
            transcript: combined,
            title: title,
            durationSeconds: durationSeconds,
            note: "The text below is an ordered set of partial digests of a long video transcript. Treat it as the full transcript and synthesize a single coherent summary across all parts."
        )
        let raw = try await complete(system: summarizeSystemPrompt(), user: user, maxTokens: 2048)
        return try parseSummary(raw)
    }

    // MARK: - Prompts

    private func summarizeSystemPrompt() -> String {
        """
        You explain videos the way a smart friend would. You get a video transcript and turn it into a short, friendly, skimmable digest.

        Output rules (follow exactly):
        - Respond with ONLY valid JSON. No preamble, no explanation, no markdown, no code fences, no trailing commentary.
        - The JSON object must have exactly these keys: "tldr", "thesis", "actionItems", "topics".
          - "tldr": a string, 1 to 2 short sentences MAX saying plainly what the video is about. Direct and concrete. No hype words, no buildup, no "in this video".
          - "thesis": a string, ONE short line that nails the main point the video is making. Say it straight.
          - "actionItems": an array of strings, each a short concrete thing the viewer should actually do. Start with a verb. Keep each to a few words. Use an empty array [] if the video implies no real tasks. Never make up tasks to fill it.
          - "topics": an array of 3 to 6 short labels (a few words each) naming what the video covers. Labels, not sentences.

        Voice and style:
        - Plain and direct, like a smart friend who gets to the point fast. Short sentences.
        - Easy to skim. No academic or stiff phrasing, no jargon, no hedging, no filler, no preamble, no hype.
        - Keep it tight. Shorter is better as long as it stays clear.

        Hard rules:
        - Be faithful to the transcript. Never invent claims, facts, names, numbers, or conclusions that are not in it.
        - NEVER use an em-dash (—) or an en-dash (–) anywhere. Not in any field. Use a period or comma instead, or the word "to" for ranges (for example "5 to 10 minutes").
        - No emojis.
        """
    }

    private func chunkDigestSystemPrompt() -> String {
        """
        You are summarizing one part of a long video transcript. Write a faithful plain digest of THIS part only (around 4 to 6 short sentences). Capture the main points, claims, and any concrete recommendations or tasks mentioned. Keep it clear and easy to read.

        Rules:
        - Be faithful. Do not invent anything not in this part.
        - Plain prose only. No JSON, no bullet symbols, no headings.
        - No emojis.
        - NEVER use an em-dash (—) or an en-dash (–). Use a period or comma instead, or "to" for ranges.
        """
    }

    private func userMessage(
        transcript: String,
        title: String?,
        durationSeconds: Double?,
        note: String? = nil
    ) -> String {
        var header = ""
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
            header += "Video title: \(title)\n"
        }
        if let durationSeconds, durationSeconds > 0 {
            let mins = Int(durationSeconds) / 60
            let secs = Int(durationSeconds) % 60
            header += "Duration: \(mins)m \(secs)s\n"
        }
        if let note {
            header += "\(note)\n"
        }
        if !header.isEmpty { header += "\n" }
        return "\(header)Transcript:\n\(transcript)"
    }

    // MARK: - NVIDIA request (mirrors NVIDIAPolisher.polishOnce)

    /// Single completion call against NVIDIA NIM. Constructs the same
    /// OpenAI-compatible payload + Bearer auth as NVIDIAPolisher and
    /// accumulates the SSE `delta.content` stream into a string.
    private func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        guard let apiKey = NVIDIAPolisher.apiKey else {
            throw VideoSummarizerError.notConfigured
        }

        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "temperature": 0.2,
            "max_tokens": maxTokens,
            // Ask NVIDIA's gpt-oss to emit a JSON object directly. The final
            // reduce/summary step relies on this; the map (chunk digest) step
            // emits prose, but JSON mode tolerates a single string object too.
            // We still parse defensively in case the field is ignored.
            "response_format": ["type": "json_object"],
            "stream": true,
        ]

        var req = URLRequest(url: endpoint, timeoutInterval: requestTimeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            throw VideoSummarizerError.requestFailed("payload encode failed")
        }

        do {
            let (asyncBytes, response) = try await URLSession.shared.bytes(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw VideoSummarizerError.requestFailed("no HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else {
                var errBody = ""
                for try await line in asyncBytes.lines {
                    errBody += line
                    if errBody.count > 400 { break }
                }
                throw VideoSummarizerError.requestFailed("HTTP \(http.statusCode): \(errBody.prefix(300))")
            }

            // SSE: accumulate delta.content chunks, same shape as the polisher.
            var accumulated = ""
            for try await line in asyncBytes.lines {
                if line.isEmpty { continue }
                if line == "data: [DONE]" { break }
                guard line.hasPrefix("data: ") else { continue }
                let jsonStr = String(line.dropFirst(6))
                guard let jsonData = jsonStr.data(using: .utf8),
                      let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
                else { continue }
                if let choices = parsed["choices"] as? [[String: Any]],
                   let delta = choices.first?["delta"] as? [String: Any],
                   let chunk = delta["content"] as? String {
                    accumulated += chunk
                }
            }

            let result = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !result.isEmpty else {
                throw VideoSummarizerError.emptyResponse
            }
            return result
        } catch let err as VideoSummarizerError {
            throw err
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw VideoSummarizerError.requestFailed("timed out after \(Int(requestTimeout))s")
        } catch {
            throw VideoSummarizerError.requestFailed("\(error)")
        }
    }

    // MARK: - Defensive JSON parsing

    private func parseSummary(_ raw: String) throws -> VideoSummary {
        let candidate = extractJSONObject(from: raw)
        guard let data = candidate.data(using: .utf8) else {
            throw VideoSummarizerError.jsonParseFailed("not valid UTF-8")
        }

        // Decode tolerantly: keys may be missing / typed loosely.
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VideoSummarizerError.jsonParseFailed("output was not a JSON object")
        }

        let tldr = (stringValue(obj["tldr"]) ?? "").strippingDashes()
        let thesis = (stringValue(obj["thesis"]) ?? "").strippingDashes()
        let actionItems = stringArray(obj["actionItems"]).map { $0.strippingDashes() }
        let topics = stringArray(obj["topics"]).map { $0.strippingDashes() }

        guard !tldr.isEmpty || !thesis.isEmpty else {
            throw VideoSummarizerError.jsonParseFailed("JSON missing both tldr and thesis")
        }

        return VideoSummary(
            tldr: tldr,
            thesis: thesis,
            actionItems: actionItems,
            topics: topics
        )
    }

    /// Pull the outermost {...} out of a possibly-noisy response: strips code
    /// fences and tolerates leading/trailing commentary the model may add.
    private func extractJSONObject(from raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip markdown code fences (```json ... ``` or ``` ... ```).
        if s.hasPrefix("```") {
            if let firstNewline = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: firstNewline)...])
            }
            if let fenceRange = s.range(of: "```", options: .backwards) {
                s = String(s[..<fenceRange.lowerBound])
            }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Slice from the first '{' to its matching '}' (brace-balanced),
        // ignoring braces inside string literals.
        guard let start = s.firstIndex(of: "{") else { return s }
        var depth = 0
        var inString = false
        var escaped = false
        var idx = start
        while idx < s.endIndex {
            let ch = s[idx]
            if escaped {
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                inString.toggle()
            } else if !inString {
                if ch == "{" { depth += 1 }
                else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(s[start...idx])
                    }
                }
            }
            idx = s.index(after: idx)
        }
        // Unbalanced — return from the first brace onward and let the JSON
        // parser surface the error.
        return String(s[start...])
    }

    private func stringValue(_ any: Any?) -> String? {
        if let s = any as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        // Some models return thesis as a single-element array — flatten it.
        if let arr = any as? [Any] {
            let joined = arr.compactMap { $0 as? String }.joined(separator: " ")
            let t = joined.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        return nil
    }

    private func stringArray(_ any: Any?) -> [String] {
        if let arr = any as? [Any] {
            return arr.compactMap { element -> String? in
                guard let s = element as? String else { return nil }
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            }
        }
        // Tolerate a single string where an array was expected.
        if let s = any as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? [] : [t]
        }
        return []
    }
}
