// HyperbolicPolisher.swift
//
// Hyperbolic fallback for cloud polish. Sits between Cerebras and Groq in the
// fallback chain: when Cerebras returns 429 / times out, we try Hyperbolic
// before demoting to Groq's smaller llama-3.1-8b.
//
// Why between Cerebras and Groq:
//   - Hyperbolic hosts the same gpt-oss-120b model as Cerebras → quality parity.
//   - ~571 tokens/sec measured — slower than Cerebras's ~3000 t/s but still well
//     ahead of local Qwen3 4B and noticeably better quality than Groq's 8B.
//   - Free tier is 60 RPM with no credit card, separate from Cerebras's quota.
//
// API surface: OpenAI-compatible /v1/chat/completions (same as Cerebras/Groq).
// Model: openai/gpt-oss-120b.
//
// Get a free API key at hyperbolic.xyz. Store it in UserDefaults under
// key "voice.hyperbolicAPIKey". No bundled key — Hyperbolic is opt-in via the
// Settings UI, just like Groq.
//
// Privacy: Hyperbolic's TOS (as of 2025) does not train on API requests.
// Data leaves the device only for the duration of the inference call.
//
// Retry policy: matches CerebrasPolisher / GroqPolisher vocabulary. Transient
// errors retry up to 2 times with exponential backoff (200ms, 500ms). On
// rate-limit (HTTP 429), fall through immediately to the next fallback —
// retrying just burns the ~3s budget before we have to demote anyway.

import Foundation

@MainActor
public final class HyperbolicPolisher {
    public static let shared = HyperbolicPolisher()
    private init() {}

    /// Free-tier model on Hyperbolic. Same gpt-oss-120b as Cerebras hosts —
    /// quality parity with the primary path, just slower per-token.
    private let model = "openai/gpt-oss-120b"

    private let endpoint = URL(string: "https://api.hyperbolic.xyz/v1/chat/completions")!

    // MARK: - Retry policy

    private let maxRetries = 2
    private let backoffMs: [Int] = [200, 500]

    // MARK: - Config

    /// API key read from UserDefaults. Returns nil (not empty string) when absent
    /// so callers can distinguish "key not set" from "key is an empty string".
    /// Hyperbolic keys don't share a stable prefix the way Cerebras (`csk-`) or
    /// Groq (`gsk_`) do, so we just validate length.
    public static var apiKey: String? {
        let stored = UserDefaults.standard.string(forKey: "voice.hyperbolicAPIKey") ?? ""
        let looksValid = stored.count >= 20
        return looksValid ? stored : nil
    }

    public static var isAvailable: Bool {
        apiKey != nil
    }

    // MARK: - Latency tracking

    public private(set) var lastLatencyMs: Int = 0
    public private(set) var avgLatencyMs: Double = 0
    public private(set) var sampleCount: Int = 0

    // MARK: - Metrics

    public private(set) var successCount: Int = 0
    public private(set) var failureCounts: [String: Int] = [:]
    public private(set) var lastSuccessAt: Date?

    /// One-line metrics snapshot for logging.
    public var metrics: String {
        let total = successCount + failureCounts.values.reduce(0, +)
        if total == 0 { return "Hyperbolic: idle" }
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
        return "Hyperbolic: \(successCount) successes, avg=\(Int(avgLatencyMs))ms, \(failsPart)"
    }

    // MARK: - Health probe

    /// Healthy when there's been a success in the last 60s OR no failures yet.
    public func isHealthy() -> Bool {
        if failureCounts.isEmpty { return true }
        if let ts = lastSuccessAt, Date().timeIntervalSince(ts) < 60 {
            return true
        }
        return false
    }

    // MARK: - Last failure reason

    /// Structured failure reason (matches CerebrasPolisher / GroqPolisher
    /// vocabulary so the caller can switch on one set of strings).
    public private(set) var lastFailureReason: String?

    private enum AttemptResult {
        case success(String)
        case transientFailure(String)
        case permanentFailure(String)
    }

    // MARK: - Polish

    /// Polish via Hyperbolic. Same contract as CerebrasPolisher.polish /
    /// GroqPolisher.polish — returns the polished text on success, nil on
    /// any failure. Callers fall back to Groq (or local MLX) on nil.
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

        // Hyperbolic is ~5x slower than Cerebras per token (~571 t/s vs
        // ~3000 t/s) and has higher TTFT. Give it more headroom than Groq
        // gets — 15s total — but keep the first-token budget tight (4s)
        // so we fail fast on cold-start or dead-key situations.
        let resolvedTotalTimeout: TimeInterval = timeoutSeconds ?? (text.count <= 80 ? 8.0 : 15.0)
        let firstTokenTimeout: TimeInterval = min(4.0, resolvedTotalTimeout)

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
                // Rate-limit: don't retry. Hyperbolic free tier is 60 RPM —
                // if we got rejected, the window is congested and waiting
                // for a retry only burns the fallback budget. Fall through
                // to the next fallback immediately. Matches CerebrasPolisher
                // policy.
                if reason == "rate-limit" {
                    recordFailure(reason)
                    lastFailureReason = reason
                    print("[HYPERBOLIC] rate-limit — falling through immediately (no retry)")
                    return nil
                }
                if attempt < maxRetries {
                    let delay = backoffMs[attempt]
                    print("[HYPERBOLIC] transient failure (\(reason)) — retry \(attempt + 1)/\(maxRetries) in \(delay)ms")
                    try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                    continue
                }
                recordFailure(reason)
                lastFailureReason = reason
                print("[HYPERBOLIC] transient: \(reason) (after \(maxRetries + 1) attempts)")
                return nil

            case .permanentFailure(let reason):
                recordFailure(reason)
                lastFailureReason = reason
                print("[HYPERBOLIC] permanent: \(reason)")
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

        // OpenAI-compatible payload. No prompt_cache_key — Hyperbolic does
        // not advertise prompt caching on the free tier.
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
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            print("[HYPERBOLIC] payload encode failed: \(error)")
            return .permanentFailure("encode-failed")
        }

        do {
            let (asyncBytes, response) = try await URLSession.shared.bytes(for: req)
            guard let http = response as? HTTPURLResponse else {
                print("[HYPERBOLIC] no HTTP response")
                return .transientFailure("network")
            }
            guard (200..<300).contains(http.statusCode) else {
                var errBody = ""
                for try await line in asyncBytes.lines {
                    errBody += line
                    if errBody.count > 400 { break }
                }
                print("[HYPERBOLIC] HTTP \(http.statusCode): \(errBody.prefix(300))")
                return classifyHTTPStatus(http.statusCode)
            }

            // SSE streaming with first-token timeout race.
            var accumulated = ""
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
                               let delta = choices.first?["delta"] as? [String: Any],
                               let chunk = delta["content"] as? String {
                                accumulated += chunk
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
            let result = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !result.isEmpty else {
                print("[HYPERBOLIC] empty streamed response")
                return .transientFailure("empty-response")
            }

            lastLatencyMs = dt
            sampleCount += 1
            avgLatencyMs = avgLatencyMs + (Double(dt) - avgLatencyMs) / Double(sampleCount)
            successCount += 1
            lastSuccessAt = Date()
            print("[HYPERBOLIC] \(dt)ms | avg=\(Int(avgLatencyMs))ms")
            return .success(result)

        } catch let urlError as URLError where urlError.code == .timedOut {
            print("[HYPERBOLIC] request timed out")
            return .transientFailure("timeout-total")
        } catch let urlError as URLError where urlError.code == .notConnectedToInternet
                                                  || urlError.code == .networkConnectionLost
                                                  || urlError.code == .dnsLookupFailed
                                                  || urlError.code == .cannotConnectToHost {
            print("[HYPERBOLIC] network failure: \(urlError.code)")
            return .transientFailure("network")
        } catch {
            print("[HYPERBOLIC] request failed: \(error)")
            return .transientFailure("network")
        }
    }

    /// Same classification policy as CerebrasPolisher / GroqPolisher.
    private func classifyHTTPStatus(_ code: Int) -> AttemptResult {
        switch code {
        case 400: return .permanentFailure("bad-request")
        case 401, 403: return .permanentFailure("auth")
        case 404: return .permanentFailure("bad-request")
        case 429: return .transientFailure("rate-limit")
        case 500..<600: return .transientFailure("server-error")
        default: return .transientFailure("server-error")
        }
    }

    private func recordFailure(_ reason: String) {
        failureCounts[reason, default: 0] += 1
    }
}
