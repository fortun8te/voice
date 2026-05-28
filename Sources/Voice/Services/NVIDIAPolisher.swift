// NVIDIAPolisher.swift
//
// NVIDIA NIM is the PRIMARY cloud polish provider, sitting at the top of the
// fallback chain:
//   NVIDIA → Cerebras → Hyperbolic → Groq → local
//
// Why primary:
//   - Hosts gpt-oss-120b on NVIDIA's own NIM infrastructure with strong
//     quality parity to Cerebras / Hyperbolic.
//   - Free tier is account-level: 40 RPM with 1000-5000 lifetime credits,
//     no credit card required to start.
//   - Separate quota from Cerebras / Hyperbolic / Groq → when one provider
//     is rate-limited, the others usually aren't.
//
// API surface: OpenAI-compatible /v1/chat/completions (same as Cerebras /
// Hyperbolic / Groq).
// Endpoint: https://integrate.api.nvidia.com/v1/chat/completions
// Model: openai/gpt-oss-120b (note the `openai/` prefix — NVIDIA namespaces
// the model differently from Cerebras's plain `gpt-oss-120b`).
//
// Get a free API key at build.nvidia.com (key format: nvapi-...). Store it
// in UserDefaults under key "voice.nvidiaAPIKey". No bundled key — NVIDIA
// is opt-in via the Settings UI.
//
// Privacy: NVIDIA NIM's terms (as of 2025) do not train on API requests for
// the integrate.api.nvidia.com endpoint. Data leaves the device only for
// the duration of the inference call.
//
// Retry policy: matches Cerebras / Hyperbolic / Groq vocabulary. Transient
// errors retry up to 2 times with exponential backoff (200ms, 500ms). On
// rate-limit (HTTP 429), fall through immediately to the next provider —
// retrying just burns the budget before we have to demote anyway.
//
// Timeout: HARD 8s total. NVIDIA's 120B model has documented occasional
// hangs where the SSE stream stalls mid-response; the hard ceiling guards
// against the routing layer waiting forever. First-token timeout is 4s
// so we fail fast on cold-start or dead-key situations.
//
// Reasoning effort: `reasoning_effort: "low"` is sent in the payload — for
// gpt-oss the lowest setting still produces clean polish output without
// the extra latency of higher reasoning tiers. NVIDIA accepts this field;
// other OpenAI-compatible providers ignore it harmlessly.

import Foundation

@MainActor
public final class NVIDIAPolisher {
    public static let shared = NVIDIAPolisher()
    private init() {}

    /// NVIDIA NIM model ID. Note the `openai/` prefix — NVIDIA namespaces
    /// models by author, unlike Cerebras (plain `gpt-oss-120b`).
    private let model = "openai/gpt-oss-120b"

    private let endpoint = URL(string: "https://integrate.api.nvidia.com/v1/chat/completions")!

    // MARK: - Retry policy

    private let maxRetries = 2
    private let backoffMs: [Int] = [200, 500]

    // MARK: - Config

    /// API key read from UserDefaults. Returns nil (not empty string) when absent
    /// so callers can distinguish "key not set" from "key is an empty string".
    /// NVIDIA NIM keys have the `nvapi-` prefix — we validate both prefix and
    /// length (>= 20) to filter out paste errors.
    public static var apiKey: String? {
        let stored = UserDefaults.standard.string(forKey: "voice.nvidiaAPIKey") ?? ""
        let looksValid = stored.hasPrefix("nvapi-") && stored.count >= 20
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
        if total == 0 { return "NVIDIA: idle" }
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
        return "NVIDIA: \(successCount) successes, avg=\(Int(avgLatencyMs))ms, \(failsPart)"
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

    /// Structured failure reason (matches Cerebras / Hyperbolic / Groq
    /// vocabulary so the caller can switch on one set of strings).
    public private(set) var lastFailureReason: String?

    private enum AttemptResult {
        case success(String)
        case transientFailure(String)
        case permanentFailure(String)
    }

    // MARK: - Polish

    /// Polish via NVIDIA NIM. Same contract as the other polishers — returns
    /// the polished text on success, nil on any failure. Callers fall back to
    /// Cerebras (or further down the chain) on nil.
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

        // HARD 8s total ceiling regardless of input length. NVIDIA's 120B
        // model has documented occasional hangs where the SSE stream STARTS
        // then stalls mid-response — the 4s first-token budget already catches
        // a dead/cold endpoint, so this ceiling only governs a mid-stream
        // stall. Dictation outputs are short (a healthy response finishes well
        // under 4s), so 8s is generous while keeping the p95 fail-over to
        // Cerebras fast instead of making the user wait 15s on a stall.
        let resolvedTotalTimeout: TimeInterval = timeoutSeconds ?? 8.0
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
                // Rate-limit: don't retry. NVIDIA free tier is 40 RPM
                // account-level — if we got rejected, the window is
                // congested and waiting for a retry burns budget before
                // we have to demote anyway. Matches Cerebras / Hyperbolic
                // policy: fall through immediately.
                if reason == "rate-limit" {
                    recordFailure(reason)
                    lastFailureReason = reason
                    print("[NVIDIA] rate-limit — falling through immediately (no retry)")
                    return nil
                }
                if attempt < maxRetries {
                    let delay = backoffMs[attempt]
                    print("[NVIDIA] transient failure (\(reason)) — retry \(attempt + 1)/\(maxRetries) in \(delay)ms")
                    try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                    continue
                }
                recordFailure(reason)
                lastFailureReason = reason
                print("[NVIDIA] transient: \(reason) (after \(maxRetries + 1) attempts)")
                return nil

            case .permanentFailure(let reason):
                recordFailure(reason)
                lastFailureReason = reason
                print("[NVIDIA] permanent: \(reason)")
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

        // OpenAI-compatible payload. `reasoning_effort: "low"` is an NVIDIA-
        // specific field for gpt-oss — lowest tier still polishes cleanly
        // and avoids the latency cost of higher reasoning. Other OpenAI-
        // compatible providers ignore unknown fields, so this would be
        // harmless if reused.
        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": text],
            ],
            "temperature": 0.2,
            "max_tokens": maxTokens,
            "reasoning_effort": "low",
            "stream": true,
        ]

        var req = URLRequest(url: endpoint, timeoutInterval: totalTimeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            print("[NVIDIA] payload encode failed: \(error)")
            return .permanentFailure("encode-failed")
        }

        do {
            let (asyncBytes, response) = try await URLSession.shared.bytes(for: req)
            guard let http = response as? HTTPURLResponse else {
                print("[NVIDIA] no HTTP response")
                return .transientFailure("network")
            }
            guard (200..<300).contains(http.statusCode) else {
                var errBody = ""
                for try await line in asyncBytes.lines {
                    errBody += line
                    if errBody.count > 400 { break }
                }
                print("[NVIDIA] HTTP \(http.statusCode): \(errBody.prefix(300))")
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
                print("[NVIDIA] empty streamed response")
                return .transientFailure("empty-response")
            }

            lastLatencyMs = dt
            sampleCount += 1
            avgLatencyMs = avgLatencyMs + (Double(dt) - avgLatencyMs) / Double(sampleCount)
            successCount += 1
            lastSuccessAt = Date()
            print("[NVIDIA] \(dt)ms | avg=\(Int(avgLatencyMs))ms")
            return .success(result)

        } catch let urlError as URLError where urlError.code == .timedOut {
            print("[NVIDIA] request timed out (hard 8s ceiling)")
            return .transientFailure("timeout-total")
        } catch let urlError as URLError where urlError.code == .notConnectedToInternet
                                                  || urlError.code == .networkConnectionLost
                                                  || urlError.code == .dnsLookupFailed
                                                  || urlError.code == .cannotConnectToHost {
            print("[NVIDIA] network failure: \(urlError.code)")
            return .transientFailure("network")
        } catch {
            print("[NVIDIA] request failed: \(error)")
            return .transientFailure("network")
        }
    }

    /// Classification matches Cerebras / Hyperbolic / Groq with NVIDIA-specific
    /// add: 402 maps to credits-exhausted (NVIDIA's free tier has a lifetime
    /// credit cap separate from RPM).
    private func classifyHTTPStatus(_ code: Int) -> AttemptResult {
        switch code {
        case 400: return .permanentFailure("bad-request")
        case 401: return .permanentFailure("auth")
        case 402: return .permanentFailure("credits-exhausted")
        case 403: return .permanentFailure("access-denied")
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
