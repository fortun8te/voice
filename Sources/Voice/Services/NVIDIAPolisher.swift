// NVIDIAPolisher.swift
//
// NVIDIA NIM is a cloud polish provider. NOTE: it is currently DISABLED in
// the dictation routing — Qwen3Polisher forces `nvidiaAvailable = false`
// because NVIDIA's gpt-oss-120b clogged mid-stream. Cerebras is now primary.
// This provider remains a ready fallback and is still used by VideoSummarizer.
//
// Effective dictation chain today:  Cerebras → Hyperbolic → Groq → local
// If re-enabled it would sit at:     NVIDIA → Cerebras → Hyperbolic → Groq → local
//
// Background:
//   - Hosts OpenAI-compatible models on NVIDIA's own NIM infrastructure.
//   - Free tier is account-level: 40 RPM with 1000-5000 lifetime credits,
//     no credit card required to start.
//   - Separate quota from Cerebras / Hyperbolic / Groq.
//
// API surface: OpenAI-compatible /v1/chat/completions (same as Cerebras /
// Hyperbolic / Groq).
// Endpoint: https://integrate.api.nvidia.com/v1/chat/completions
// Model: mistralai/mistral-small-4-119b-2603 (switched off gpt-oss-120b,
// which returns answers in a reasoning field / clogged).
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
// Timeout: HARD 6s total. NVIDIA's 120B model has documented occasional
// hangs where the SSE stream stalls mid-response; the hard ceiling guards
// against the routing layer waiting forever. First-token timeout is 3s
// so we fail fast on cold-start or dead-key situations, and a 3s MID-STREAM
// stall detector aborts when the stream starts then goes silent (the
// documented 120B hang). Timeout failures (first-token / total / stall) are
// NEVER retried — a hung endpoint won't recover in a 200ms backoff, and
// retrying just stacks latency before we demote to Cerebras anyway.
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
    private let model = "mistralai/mistral-small-4-119b-2603"

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

        // HARD 6s total ceiling regardless of input length. NVIDIA's 120B
        // model has documented occasional hangs where the SSE stream STARTS
        // then stalls mid-response — the 3s first-token budget catches a
        // dead/cold endpoint, the 3s mid-stream stall detector (see
        // `stallTimeout`) catches the start-then-hang case, and this ceiling
        // is the absolute backstop. Dictation outputs are short (a healthy
        // response finishes well under 3s), so this keeps the p95 fail-over
        // to Cerebras fast instead of stacking a long stall onto the chain.
        let resolvedTotalTimeout: TimeInterval = timeoutSeconds ?? 6.0
        let firstTokenTimeout: TimeInterval = min(3.0, resolvedTotalTimeout)
        // Mid-stream stall: if streaming has started but no new token arrives
        // for this long, abort and fall through. Targets the 120B mid-response
        // hang specifically.
        let stallTimeout: TimeInterval = 3.0

        for attempt in 0...maxRetries {
            let result = await polishOnce(
                text: text,
                systemPrompt: systemPrompt,
                apiKey: apiKey,
                maxTokens: maxTokens,
                totalTimeout: resolvedTotalTimeout,
                firstTokenTimeout: firstTokenTimeout,
                stallTimeout: stallTimeout
            )

            switch result {
            case .success(let polished):
                return polished

            case .transientFailure(let reason):
                // Don't retry rate-limit OR any timeout/stall. A hung 120B
                // stream won't recover within a 200ms backoff — retrying
                // just stacks 6s ceilings before we demote to Cerebras
                // anyway. Fall through immediately so the chain stays bounded.
                let noRetry = reason == "rate-limit"
                    || reason == "timeout-firsttoken"
                    || reason == "timeout-total"
                    || reason == "stall"
                    // empty-response is deterministic — retrying stacks 6s
                    // ceilings before demoting to Cerebras anyway.
                    || reason == "empty-response"
                if noRetry {
                    recordFailure(reason)
                    lastFailureReason = reason
                    print("[NVIDIA] \(reason) — falling through immediately (no retry)")
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
        firstTokenTimeout: TimeInterval,
        stallTimeout: TimeInterval
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

            // SSE streaming with a first-token timeout race AND a mid-stream
            // stall detector. NVIDIA's 120B occasionally emits a first token
            // then goes silent; `progress` tracks the wall-clock time of the
            // last token so the watchdog task can abort a stall.
            let progress = StreamProgress()

            let streamResult: AttemptResult? = await withTaskGroup(of: AttemptResult?.self) { group -> AttemptResult? in
                // Watchdog: first-token budget, then per-token stall budget.
                group.addTask { [firstTokenTimeout, stallTimeout] in
                    // Phase 1: wait for the first token.
                    try? await Task.sleep(nanoseconds: UInt64(firstTokenTimeout * 1_000_000_000))
                    if !progress.firstTokenSeen {
                        return .transientFailure("timeout-firsttoken")
                    }
                    // Phase 2: poll for mid-stream stalls. If the gap since the
                    // last token exceeds stallTimeout, abort.
                    let pollNs: UInt64 = 250_000_000  // 250ms
                    while !progress.done {
                        if progress.secondsSinceLastToken() > stallTimeout {
                            return .transientFailure("stall")
                        }
                        try? await Task.sleep(nanoseconds: pollNs)
                    }
                    return nil
                }
                group.addTask {
                    do {
                        for try await line in asyncBytes.lines {
                            if line.isEmpty { continue }
                            if line == "data: [DONE]" { break }
                            guard line.hasPrefix("data: ") else { continue }
                            let jsonStr = String(line.dropFirst(6))
                            guard let jsonData = jsonStr.data(using: .utf8),
                                  let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { continue }
                            if let choices = parsed["choices"] as? [[String: Any]],
                               let delta = choices.first?["delta"] as? [String: Any] {
                                if let chunk = delta["content"] as? String {
                                    progress.appendToken(chunk)
                                }
                                // Capture reasoning-channel text as a fallback
                                // only (see CerebrasPolisher). Also counts as a
                                // token for the stall watchdog so a reasoning-
                                // only stream isn't killed as a false stall.
                                if let r = delta["reasoning"] as? String {
                                    progress.appendReasoning(r)
                                } else if let r = delta["reasoning_content"] as? String {
                                    progress.appendReasoning(r)
                                }
                            }
                        }
                        progress.markDone()
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
                    // First-token timeout is only honored if no token arrived;
                    // otherwise the watchdog already transitioned to stall mode.
                    if case .transientFailure("timeout-firsttoken") = firstResult, progress.firstTokenSeen {
                        return await group.next() ?? nil
                    }
                    return firstResult
                }
                return nil
            }

            if let earlyExit = streamResult {
                if case .transientFailure("stall") = earlyExit {
                    let dt = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
                    print("[NVIDIA] mid-stream stall after \(dt)ms (no token for >\(Int(stallTimeout))s) — aborting")
                }
                return earlyExit
            }

            let dt = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
            var result = progress.accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            // Recover the answer from the reasoning channel if content was
            // empty and the text doesn't look like exposed chain-of-thought.
            if result.isEmpty {
                let reasoning = progress.accumulatedReasoning.trimmingCharacters(in: .whitespacesAndNewlines)
                if !reasoning.isEmpty, !CerebrasPolisher.looksLikeChainOfThought(reasoning) {
                    print("[NVIDIA] content empty — recovered answer from reasoning field (\(reasoning.count) chars)")
                    result = reasoning
                }
            }
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

/// Thread-safe progress tracker shared between the SSE consumer task and the
/// stall watchdog task. The consumer runs off the main actor; the watchdog
/// polls `secondsSinceLastToken()`. A plain lock keeps it `Sendable` without
/// pulling in actor hops on the hot streaming path.
private final class StreamProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var _accumulated = ""
    private var _accumulatedReasoning = ""
    private var _firstTokenSeen = false
    private var _done = false
    private var _lastTokenAt = CFAbsoluteTimeGetCurrent()

    func appendToken(_ chunk: String) {
        lock.lock(); defer { lock.unlock() }
        _accumulated += chunk
        _firstTokenSeen = true
        _lastTokenAt = CFAbsoluteTimeGetCurrent()
    }

    /// Reasoning-channel text, kept separate as a fallback. Counts as activity
    /// for the stall watchdog so a reasoning-only stream isn't false-killed.
    func appendReasoning(_ chunk: String) {
        lock.lock(); defer { lock.unlock() }
        _accumulatedReasoning += chunk
        _firstTokenSeen = true
        _lastTokenAt = CFAbsoluteTimeGetCurrent()
    }

    func markDone() {
        lock.lock(); defer { lock.unlock() }
        _done = true
    }

    var accumulated: String {
        lock.lock(); defer { lock.unlock() }
        return _accumulated
    }

    var accumulatedReasoning: String {
        lock.lock(); defer { lock.unlock() }
        return _accumulatedReasoning
    }

    var firstTokenSeen: Bool {
        lock.lock(); defer { lock.unlock() }
        return _firstTokenSeen
    }

    var done: Bool {
        lock.lock(); defer { lock.unlock() }
        return _done
    }

    func secondsSinceLastToken() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return CFAbsoluteTimeGetCurrent() - _lastTokenAt
    }
}
