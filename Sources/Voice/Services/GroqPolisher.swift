// GroqPolisher.swift
//
// Groq fallback for cloud polish. Used when Cerebras returns 429 (rate limit)
// or times out without a first token in >3s.
//
// API surface: OpenAI-compatible /v1/chat/completions (same as Cerebras).
// Model: llama-3.1-8b-instant — fastest free model on Groq, ~500 tokens/s.
//
// Get a free API key at console.groq.com. Store it in UserDefaults under
// key "voice.groqAPIKey". No bundled key — Groq is a fallback, not the
// primary path, so it is opt-in via the Settings UI.
//
// Privacy: Groq's TOS (as of 2025) does not train on API requests.
// Data leaves the device for the duration of the inference call only.
//
// Retry policy: same as CerebrasPolisher — transient errors retry up to
// 2 times with exponential backoff (200ms, 500ms). Structured failure
// reasons match Cerebras so the caller can switch on one vocabulary.

import Foundation

@MainActor
public final class GroqPolisher {
    public static let shared = GroqPolisher()
    private init() {}

    /// Free-tier model on Groq. llama-3.3-70b-versatile: real fallback quality
    /// (70B, far better than 8b-instant at self-correction / formatting), still
    /// fast (~0.6s) and — unlike gpt-oss — NOT a reasoning model, so it never
    /// burns its token budget thinking and returns empty. This is the lane that
    /// catches a Cerebras 429, so quality matters: it must produce output the
    /// user would actually paste, not a degraded local-tier result.
    private let model = "llama-3.3-70b-versatile"

    private let endpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions")!

    // MARK: - Retry policy

    private let maxRetries = 2
    private let backoffMs: [Int] = [200, 500]

    // MARK: - Config

    /// API key read from UserDefaults. Returns nil (not empty string) when absent
    /// so callers can distinguish "key not set" from "key is an empty string".
    public static var apiKey: String? {
        let stored = UserDefaults.standard.string(forKey: "voice.groqAPIKey") ?? ""
        // Groq keys start with "gsk_"
        let looksValid = stored.hasPrefix("gsk_") && stored.count >= 20
        return looksValid ? stored : nil
    }

    public static var isAvailable: Bool {
        apiKey != nil
    }

    // MARK: - Latency tracking

    public private(set) var lastLatencyMs: Int = 0
    public private(set) var avgLatencyMs: Double = 0
    public private(set) var sampleCount: Int = 0

    // MARK: - Metrics (Step 6)

    public private(set) var successCount: Int = 0
    public private(set) var failureCounts: [String: Int] = [:]
    public private(set) var lastSuccessAt: Date?

    /// One-line metrics snapshot for logging.
    public var metrics: String {
        let total = successCount + failureCounts.values.reduce(0, +)
        if total == 0 { return "Groq: idle" }
        let failsPart: String
        if failureCounts.isEmpty {
            failsPart = "fails={}"
        } else {
            let pairs = failureCounts
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)" }
                .joined(separator: ", ")
            failsPart = "fails={\(pairs)}"
        }
        return "Groq: \(successCount) successes, avg=\(Int(avgLatencyMs))ms, \(failsPart)"
    }

    // MARK: - Health probe (Step 7)

    /// Healthy when there's been a success in the last 60s OR no failures yet.
    public func isHealthy() -> Bool {
        if failureCounts.isEmpty { return true }
        if let ts = lastSuccessAt, Date().timeIntervalSince(ts) < 60 {
            return true
        }
        return false
    }

    // MARK: - Last failure reason

    /// Structured failure reason (matches CerebrasPolisher vocabulary).
    public private(set) var lastFailureReason: String?

    private enum AttemptResult {
        case success(String)
        case transientFailure(String)
        case permanentFailure(String)
    }

    // MARK: - Polish

    /// Polish via Groq. Same contract as CerebrasPolisher.polish — returns
    /// the polished text on success, nil on any failure. Callers fall back
    /// to local MLX on nil.
    public func polish(
        _ text: String,
        systemPrompt: String,
        maxTokens: Int = 1024,
        timeoutSeconds: TimeInterval? = nil
    ) async -> String? {
        guard let apiKey = Self.apiKey else {
            lastFailureReason = "not-configured"
            return nil
        }
        lastFailureReason = nil

        // Groq is faster than Cerebras per token but slightly higher TTFT —
        // raised short-input ceiling 2.5s → 3.0s to align with the Cerebras
        // bump (cold-start headroom).
        let resolvedTotalTimeout: TimeInterval = timeoutSeconds ?? (text.count <= 80 ? 3.0 : 4.5)
        let firstTokenTimeout: TimeInterval = min(3.0, resolvedTotalTimeout)

        for attempt in 0...maxRetries {
            let result = await polishOnce(
                text: text,
                systemPrompt: systemPrompt,
                apiKey: apiKey,
                maxTokens: maxTokens,
                totalTimeout: resolvedTotalTimeout,
                firstTokenTimeout: firstTokenTimeout
            )

            switch result {
            case .success(let polished):
                return polished

            case .transientFailure(let reason):
                // Don't retry rate-limit or timeouts — Groq is last in the
                // cloud chain, so a stacked retry here directly delays the
                // local-MLX fallback. A hung/congested endpoint won't recover
                // in a 200ms backoff. Network blips still get one retry.
                let noRetry = reason == "rate-limit"
                    || reason == "timeout-firsttoken"
                    || reason == "timeout-total"
                    // empty-response is deterministic — retrying just delays the
                    // local-MLX fallback (Groq is the last cloud link).
                    || reason == "empty-response"
                if noRetry {
                    recordFailure(reason)
                    lastFailureReason = reason
                    print("[GROQ] \(reason) — falling through immediately (no retry)")
                    return nil
                }
                if attempt < maxRetries {
                    let delay = backoffMs[attempt]
                    print("[GROQ] transient failure (\(reason)) — retry \(attempt + 1)/\(maxRetries) in \(delay)ms")
                    try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                    continue
                }
                recordFailure(reason)
                lastFailureReason = reason
                print("[GROQ] transient: \(reason) (after \(maxRetries + 1) attempts)")
                return nil

            case .permanentFailure(let reason):
                recordFailure(reason)
                lastFailureReason = reason
                print("[GROQ] permanent: \(reason)")
                return nil
            }
        }
        return nil
    }

    private func polishOnce(
        text: String,
        systemPrompt: String,
        apiKey: String,
        maxTokens: Int,
        totalTimeout: TimeInterval,
        firstTokenTimeout: TimeInterval
    ) async -> AttemptResult {
        let started = CFAbsoluteTimeGetCurrent()

        // OpenAI-compatible payload. No prompt_cache_key — Groq does not
        // expose prompt caching on the free tier.
        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": text],
            ],
            "temperature": 0.2,
            "max_tokens": maxTokens,
            "stream": true,
        ]

        var req = URLRequest(url: endpoint, timeoutInterval: totalTimeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        // Browser-style User-Agent. Mirrors CerebrasPolisher's Cloudflare 1010
        // fix; harmless on hosts that aren't Cloudflare-fronted.
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            print("[GROQ] payload encode failed: \(error)")
            return .permanentFailure("encode-failed")
        }

        do {
            let (asyncBytes, response) = try await URLSession.shared.bytes(for: req)
            guard let http = response as? HTTPURLResponse else {
                print("[GROQ] no HTTP response")
                return .transientFailure("network")
            }
            guard (200..<300).contains(http.statusCode) else {
                var errBody = ""
                for try await line in asyncBytes.lines {
                    errBody += line
                    if errBody.count > 400 { break }
                }
                print("[GROQ] HTTP \(http.statusCode): \(errBody.prefix(300))")
                return classifyHTTPStatus(http.statusCode)
            }

            // SSE streaming with first-token timeout race.
            var accumulated = ""
            // Fallback buffer for the reasoning channel — see Cerebras for the
            // rationale. Some models stream the answer in `delta.reasoning` /
            // `delta.reasoning_content` with content null.
            var accumulatedReasoning = ""
            var firstTokenSeen = false

            let streamResult: AttemptResult? = await withTaskGroup(of: AttemptResult?.self) { group -> AttemptResult? in
                group.addTask { [firstTokenTimeout] in
                    try? await Task.sleep(nanoseconds: UInt64(firstTokenTimeout * 1_000_000_000))
                    return .transientFailure("timeout-firsttoken")
                }
                group.addTask {
                    do {
                        for try await line in asyncBytes.lines {
                            if !firstTokenSeen, !line.isEmpty {
                                firstTokenSeen = true
                            }
                            if line.isEmpty { continue }
                            if line == "data: [DONE]" { break }
                            guard line.hasPrefix("data: ") else { continue }
                            let jsonStr = String(line.dropFirst(6))
                            guard let jsonData = jsonStr.data(using: .utf8),
                                  let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { continue }
                            if let choices = parsed["choices"] as? [[String: Any]],
                               let delta = choices.first?["delta"] as? [String: Any] {
                                if let chunk = delta["content"] as? String {
                                    accumulated += chunk
                                }
                                if let r = delta["reasoning"] as? String {
                                    accumulatedReasoning += r
                                } else if let r = delta["reasoning_content"] as? String {
                                    accumulatedReasoning += r
                                }
                            }
                        }
                        return nil
                    } catch let urlError as URLError where urlError.code == .timedOut {
                        return .transientFailure("timeout-total")
                    } catch let urlError as URLError where urlError.code == .notConnectedToInternet
                                                              || urlError.code == .networkConnectionLost
                                                              || urlError.code == .dnsLookupFailed
                                                              || urlError.code == .cannotConnectToHost {
                        return .transientFailure("network")
                    } catch {
                        return .transientFailure("network")
                    }
                }

                if let firstResult = await group.next() {
                    group.cancelAll()
                    if firstResult == nil { return nil }
                    if case .transientFailure("timeout-firsttoken") = firstResult, firstTokenSeen {
                        return await group.next() ?? nil
                    }
                    return firstResult
                }
                return nil
            }

            if let earlyExit = streamResult {
                return earlyExit
            }

            let dt = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
            var result = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            // Recover the answer from the reasoning channel if content was
            // empty and the text doesn't look like exposed chain-of-thought.
            if result.isEmpty {
                let reasoning = accumulatedReasoning.trimmingCharacters(in: .whitespacesAndNewlines)
                if !reasoning.isEmpty, !CerebrasPolisher.looksLikeChainOfThought(reasoning) {
                    print("[GROQ] content empty — recovered answer from reasoning field (\(reasoning.count) chars)")
                    result = reasoning
                }
            }
            guard !result.isEmpty else {
                print("[GROQ] empty streamed response")
                return .transientFailure("empty-response")
            }

            lastLatencyMs = dt
            sampleCount += 1
            avgLatencyMs = avgLatencyMs + (Double(dt) - avgLatencyMs) / Double(sampleCount)
            successCount += 1
            lastSuccessAt = Date()
            print("[GROQ] \(dt)ms | avg=\(Int(avgLatencyMs))ms")
            return .success(result)

        } catch let urlError as URLError where urlError.code == .timedOut {
            print("[GROQ] request timed out")
            return .transientFailure("timeout-total")
        } catch let urlError as URLError where urlError.code == .notConnectedToInternet
                                                  || urlError.code == .networkConnectionLost
                                                  || urlError.code == .dnsLookupFailed
                                                  || urlError.code == .cannotConnectToHost {
            print("[GROQ] network failure: \(urlError.code)")
            return .transientFailure("network")
        } catch {
            print("[GROQ] request failed: \(error)")
            return .transientFailure("network")
        }
    }

    /// Same classification policy as CerebrasPolisher.
    private func classifyHTTPStatus(_ code: Int) -> AttemptResult {
        switch code {
        case 400: return .permanentFailure("bad-request")
        case 401, 403: return .permanentFailure("auth")
        case 404: return .permanentFailure("bad-request")
        case 429: return .permanentFailure("rate-limit")
        case 500..<600: return .transientFailure("server-error")
        default: return .transientFailure("server-error")
        }
    }

    private func recordFailure(_ reason: String) {
        failureCounts[reason, default: 0] += 1
    }
}
