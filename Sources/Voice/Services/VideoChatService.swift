// VideoChatService.swift
//
// Grounded Q&A over a transcribed video.
//
// Product insight: a summary is great, but people also want to interrogate a
// video. "Where did they say X?", "What's the counterargument they raised?",
// "Did they give a number for that?". This service answers those questions
// using ONLY the video's transcript + summary as context, so it never drifts
// into the model's general knowledge.
//
// It MIRRORS the cloud-request approach in VideoSummarizer.swift: the same
// NVIDIA NIM endpoint (mistralai/mistral-small-4-119b-2603, OpenAI-compatible
// /v1/chat/completions), the same Bearer auth via NVIDIAPolisher.apiKey, and
// the same SSE delta accumulation. The `complete(...)` helper is copied here
// (kept self-contained, since it can't be cleanly shared across files) but
// adapted for plain-text chat rather than JSON: no response_format, and it
// takes a full messages array so prior turns can be threaded through.
//
// `TranscribedVideo` and `VideoChatMessage` are defined in
// TranscribedVideoStore.swift; this file references them and does not redefine.

import Foundation

// MARK: - Service

@MainActor
public final class VideoChatService {
    public static let shared = VideoChatService()
    public init() {}

    // Same NVIDIA NIM surface the app already uses for polish + summaries.
    private let model = "mistralai/mistral-small-4-119b-2603"
    private let endpoint = URL(string: "https://integrate.api.nvidia.com/v1/chat/completions")!

    // Chat answers read a (possibly large) transcript and write a short reply.
    // Be generous on time, modest on output tokens.
    private let requestTimeout: TimeInterval = 60

    // How much transcript we are willing to inline as context. ~40k chars keeps
    // us comfortably inside the model's window after the system prompt, summary,
    // and chat history are added. Longer transcripts are truncated with a note.
    private let transcriptCharBudget = 40_000

    // MARK: - Errors

    public enum VideoChatError: Error, LocalizedError {
        case notConfigured
        case emptyQuestion
        case requestFailed(String)
        case emptyResponse

        public var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "NVIDIA API key is not configured (set it in Settings)."
            case .emptyQuestion:
                return "Ask a question first — the message was empty."
            case .requestFailed(let why):
                return "Chat request failed: \(why)"
            case .emptyResponse:
                return "Model returned an empty response."
            }
        }
    }

    // MARK: - Public API

    /// Answer `question` about `video`, grounded in its transcript + summary,
    /// continuing the conversation given by `history` (prior turns). Returns the
    /// assistant's plain-text reply.
    func ask(
        question: String,
        video: TranscribedVideo,
        history: [VideoChatMessage]
    ) async throws -> String {
        guard NVIDIAPolisher.apiKey != nil else {
            throw VideoChatError.notConfigured
        }
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty else {
            throw VideoChatError.emptyQuestion
        }

        // Build the messages array: system (with grounding context), then prior
        // history mapped to {role, content}, then the new user question.
        var messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt(for: video)]
        ]

        for msg in history {
            let content = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            // Normalize role to the two values the API expects; anything that
            // is not "assistant" is treated as a user turn.
            let role = (msg.role == "assistant") ? "assistant" : "user"
            messages.append(["role": role, "content": content])
        }

        messages.append(["role": "user", "content": trimmedQuestion])

        return try await complete(messages: messages, maxTokens: 1024)
    }

    // MARK: - Prompt + grounding context

    private func systemPrompt(for video: TranscribedVideo) -> String {
        var prompt = """
        You answer questions about a specific video. Ground every answer ONLY in the provided transcript and summary. If the video doesn't cover it, say so plainly. Be brief and direct: one short paragraph OR a few bullet points, whichever fits. Get straight to the point. No preamble, no filler, no restating the question. NEVER use em-dashes or en-dashes (use periods/commas or 'to'). No emojis. Don't make things up.

        """

        let title = video.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            prompt += "\nVideo title: \(title)\n"
        }

        // Summary block (tldr / thesis / topics / action items), each included
        // only when present so we never feed the model empty headers.
        var summaryLines: [String] = []
        if let tldr = video.tldr?.trimmingCharacters(in: .whitespacesAndNewlines), !tldr.isEmpty {
            summaryLines.append("TLDR: \(tldr)")
        }
        if let thesis = video.thesis?.trimmingCharacters(in: .whitespacesAndNewlines), !thesis.isEmpty {
            summaryLines.append("Thesis: \(thesis)")
        }
        if !video.topics.isEmpty {
            summaryLines.append("Topics: \(video.topics.joined(separator: ", "))")
        }
        if !video.actionItems.isEmpty {
            let items = video.actionItems
                .map { "- \($0)" }
                .joined(separator: "\n")
            summaryLines.append("Action items:\n\(items)")
        }
        if !summaryLines.isEmpty {
            prompt += "\nSummary:\n" + summaryLines.joined(separator: "\n") + "\n"
        }

        // Transcript, truncated to a sane budget to stay inside the context
        // window. We keep the head of the transcript and flag the cut.
        let transcript = video.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if transcript.isEmpty {
            prompt += "\nTranscript: (no transcript is available for this video)\n"
        } else if transcript.count > transcriptCharBudget {
            let truncated = String(transcript.prefix(transcriptCharBudget))
            prompt += "\nTranscript (truncated to the first \(transcriptCharBudget) characters; later portions are omitted):\n\(truncated)\n"
        } else {
            prompt += "\nTranscript:\n\(transcript)\n"
        }

        return prompt
    }

    // MARK: - NVIDIA request (mirrors VideoSummarizer.complete)

    /// Single completion call against NVIDIA NIM. Constructs the same
    /// OpenAI-compatible payload + Bearer auth as VideoSummarizer and
    /// accumulates the SSE `delta.content` stream into a string. Unlike the
    /// summarizer this requests plain text (no response_format) and takes a
    /// prebuilt messages array so chat history flows through unchanged.
    private func complete(messages: [[String: String]], maxTokens: Int) async throws -> String {
        guard let apiKey = NVIDIAPolisher.apiKey else {
            throw VideoChatError.notConfigured
        }

        let payload: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": 0.3,
            "max_tokens": maxTokens,
            "stream": true,
        ]

        var req = URLRequest(url: endpoint, timeoutInterval: requestTimeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            throw VideoChatError.requestFailed("payload encode failed")
        }

        do {
            let (asyncBytes, response) = try await URLSession.shared.bytes(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw VideoChatError.requestFailed("no HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else {
                var errBody = ""
                for try await line in asyncBytes.lines {
                    errBody += line
                    if errBody.count > 400 { break }
                }
                throw VideoChatError.requestFailed("HTTP \(http.statusCode): \(errBody.prefix(300))")
            }

            // SSE: accumulate delta.content chunks, same shape as the summarizer.
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
                throw VideoChatError.emptyResponse
            }
            return result.strippingDashes()
        } catch let err as VideoChatError {
            throw err
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw VideoChatError.requestFailed("timed out after \(Int(requestTimeout))s")
        } catch {
            throw VideoChatError.requestFailed("\(error)")
        }
    }
}
