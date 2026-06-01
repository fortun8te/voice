// CerebrasPolisher.swift
//
// Optional cloud polish path using Cerebras Inference API. Free tier hosts
// Llama 3.3 70B at ~2000 tokens/sec — polish lands in 200-500ms with
// near-frontier quality, compared to ~600-1500ms on our local 4B model.
//
// Use cases:
//   - User opts in via Settings → "Cloud polish (Cerebras)"
//   - Long / multi-topic / complex dictations route to Cerebras
//   - Short utterances stay local for offline use and minimal latency
//
// Privacy: Cerebras' TOS (as of late 2025) explicitly does NOT train on
// API requests. Data is processed for the inference call and not retained
// for training. Still — this is opt-in only, and text leaves the device,
// so the toggle copy must be explicit about that.
//
// Get a free API key at cloud.cerebras.ai. The key goes into Keychain (or
// UserDefaults for v1 — Keychain hardening can come later).
//
// API surface: OpenAI-compatible /v1/chat/completions endpoint.
//
// Retry policy: transient errors (network/DNS/5xx/empty body) retry up to
// 2 times with exponential backoff (200ms, 500ms). Permanent errors
// (auth/bad-request/rate-limit) surface immediately so the caller can
// pick the right fallback (Groq vs local vs surface-to-user).

import Foundation

@MainActor
public final class CerebrasPolisher {
    public static let shared = CerebrasPolisher()
    private init() {}

    /// Free-tier model on Cerebras. OpenAI GPT-OSS 120B (dense).
    /// ~3000 tokens/sec on Cerebras' wafer-scale silicon — fastest production model.
    /// Production tier (stable, won't be discontinued like Preview models qwen-3-235b
    /// or zai-glm-4.7). Better quality than llama3.1-8b for prose polish.
    private let model = "gpt-oss-120b"

    private let endpoint = URL(string: "https://api.cerebras.ai/v1/chat/completions")!

    // MARK: - Retry policy

    /// Maximum retry attempts for transient errors (in addition to the
    /// initial try). 2 retries → up to 3 total attempts.
    private let maxRetries = 2

    /// Backoff between retries, in milliseconds. Indexed by attempt number.
    /// attempt=0 → first retry waits 200ms, attempt=1 → second retry waits 500ms.
    private let backoffMs: [Int] = [200, 500]

    // MARK: - Toggles / config (read from UserDefaults)

    public static var isEnabled: Bool {
        // Default to true if unset — cloud is the default engine.
        if UserDefaults.standard.object(forKey: "cerebrasEnabled") == nil { return true }
        return UserDefaults.standard.bool(forKey: "cerebrasEnabled")
    }

    /// API key. Prefers UserDefaults override, falls back to the bundled key
    /// in `CerebrasKey.swift` (which is gitignored — see that file).
    /// Validates the UserDefaults value looks like a real Cerebras key
    /// (starts with `csk-`) — if it doesn't, ignore it and use the bundled
    /// key. This prevents the case where a user accidentally dictates into
    /// the API key field and corrupts it with arbitrary text.
    public static var apiKey: String {
        let stored = UserDefaults.standard.string(forKey: "cerebrasAPIKey") ?? ""
        let looksValid = stored.hasPrefix("csk-") && stored.count >= 20
        return looksValid ? stored : CerebrasKey.bundled
    }

    /// Whether the cloud path is fully ready to use (toggle ON + key set).
    public static var isAvailable: Bool {
        isEnabled && !apiKey.isEmpty
    }

    /// Word threshold for routing to cloud. Lowered from 20 → 8 now that SSE
    /// streaming gives us near-instant TTFT. The adaptive routing logic in
    /// Qwen3Polisher will still fall back to local if cloud is running slow.
    public static var minWordCount: Int { 8 }

    // MARK: - Latency tracking (for adaptive routing)

    /// Wall-clock ms of the most recent successful cloud polish.
    public private(set) var lastLatencyMs: Int = 0

    /// Rolling exponential average of cloud latency. Updated after every
    /// successful call. Used by the caller to decide whether cloud is
    /// currently competitive vs. local.
    public private(set) var avgLatencyMs: Double = 0

    /// Number of successful cloud polish calls this session.
    public private(set) var sampleCount: Int = 0

    // MARK: - Metrics (Step 6)

    /// Number of polish() calls that returned a non-nil result this session.
    public private(set) var successCount: Int = 0

    /// Per-reason failure tally. Keys are the structured reason strings
    /// defined in `FailureReason` below.
    public private(set) var failureCounts: [String: Int] = [:]

    /// Timestamp of the most recent successful polish, used by `isHealthy()`.
    public private(set) var lastSuccessAt: Date?

    /// One-line metrics snapshot for logging. Example:
    /// `"Cerebras: 47 successes, avg=312ms, fails={timeout-firsttoken: 3, rate-limit: 1}"`
    public var metrics: String {
        let total = successCount + failureCounts.values.reduce(0, +)
        if total == 0 { return "Cerebras: idle" }
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
        return "Cerebras: \(successCount) successes, avg=\(Int(avgLatencyMs))ms, \(failsPart)"
    }

    // MARK: - Health probe (Step 7)

    /// True if cloud appears healthy. The caller can use this to short-
    /// circuit straight to local when cloud has been failing repeatedly.
    ///
    /// Healthy when EITHER:
    ///   - There has been a successful polish in the last 60 seconds, OR
    ///   - There are no recorded failures yet (fresh session).
    public func isHealthy() -> Bool {
        if failureCounts.isEmpty { return true }
        if let ts = lastSuccessAt, Date().timeIntervalSince(ts) < 60 {
            return true
        }
        return false
    }

    // MARK: - Polish

    /// Last failure reason, if any. Set by polish() when a cloud call fails.
    /// Used by the orchestrator to surface a toast.
    ///
    /// Structured values (see `FailureReason` enum):
    ///   - "rate-limit"           — HTTP 429
    ///   - "auth"                 — HTTP 401/403
    ///   - "timeout-firsttoken"   — no first SSE byte within first-token budget
    ///   - "timeout-total"        — request exceeded total timeout
    ///   - "network"              — connection/DNS failure
    ///   - "server-error"         — HTTP 5xx
    ///   - "bad-request"          — HTTP 400
    ///   - "empty-response"       — empty body / no streamed content
    ///   - "not-configured"       — toggle off or missing API key
    ///   - "encode-failed"        — JSON serialization of payload failed
    ///   - "rate-limit-local"     — local rate limiter blocked the call
    /// Compound values get a "transient: …" / "permanent: …" prefix to
    /// indicate the retry layer's verdict.
    public private(set) var lastFailureReason: String?

    /// Internal result type for the single-attempt helper.
    private enum AttemptResult {
        case success(String)
        case transientFailure(String)
        case permanentFailure(String)
    }

    /// Polish via Cerebras. Returns the polished text on success, or `nil`
    /// on any failure (network error, API error, bad key, timeout). Callers
    /// fall back to the local polish path on `nil`, then inspect
    /// `lastFailureReason` to surface a toast.
    public func polish(
        _ text: String,
        systemPrompt: String,
        maxTokens: Int = 2048,
        cacheKey: String? = nil,
        timeoutSeconds: TimeInterval? = nil
    ) async -> String? {
        guard Self.isAvailable else {
            lastFailureReason = "not-configured"
            return nil
        }
        // Adaptive timeout: short inputs almost always return in <1s; longer
        // inputs need more headroom for streaming. Raised the short-input
        // ceiling from 2.0s → 3.0s — Cerebras has occasional cold-start
        // latency that exceeded 2s and caused premature local fallback.
        let resolvedTotalTimeout: TimeInterval = timeoutSeconds ?? (text.count <= 80 ? 3.0 : 4.5)

        // First-token (TTFT) timeout — separate from total. 3s leaves
        // headroom for Cerebras cold starts; streaming should kick in
        // within that window for a healthy session.
        let firstTokenTimeout: TimeInterval = min(3.0, resolvedTotalTimeout)

        let apiKey = Self.apiKey
        lastFailureReason = nil

        // Rate limit check — gate before network call. This is a local-only
        // check (our own quota tracker), distinct from HTTP 429 from the API.
        let estimatedTokens = CerebrasRateLimiter.estimateTokens(systemPrompt: systemPrompt, userText: text)
        guard await CerebrasRateLimiter.shared.canProceed(estimatedTokens: estimatedTokens) else {
            recordFailure("rate-limit-local")
            lastFailureReason = "rate-limit-local"
            return nil
        }

        // Retry loop. Permanent errors short-circuit; transient errors
        // retry with backoff. Cloud-polishing flag stays on across retries
        // so the pill keeps showing the cloud glyph during the retry window.
        PolishStatus.shared.isCloudPolishing = true
        defer { PolishStatus.shared.isCloudPolishing = false }

        for attempt in 0...maxRetries {
            let result = await polishOnce(
                text: text,
                systemPrompt: systemPrompt,
                apiKey: apiKey,
                maxTokens: maxTokens,
                cacheKey: cacheKey,
                totalTimeout: resolvedTotalTimeout,
                firstTokenTimeout: firstTokenTimeout,
                estimatedTokens: estimatedTokens
            )

            switch result {
            case .success(let polished):
                return polished

            case .transientFailure(let reason):
                // 429 rate-limit: RETRY with short backoff. The free tier's
                // shared queue clears in well under a second (measured ~0.5s),
                // so a 200ms→500ms retry (≤0.7s total) almost always lands
                // cloud. The alternative — falling straight to the local model
                // — costs ~60s. An earlier version skipped the retry on the
                // assumption the backoff was ~11s; it's actually ≤0.7s, so
                // retrying is strictly better than a 60s local demote.
                //
                // Still skip retry for genuinely slow/deterministic failures:
                // first-token/total timeouts (already burned the full budget)
                // and empty-response (a reasoning model that spent its budget
                // thinking will do the same again).
                let noRetry = reason == "timeout-firsttoken"
                    || reason == "timeout-total"
                    || reason == "empty-response"
                if noRetry {
                    recordFailure(reason)
                    lastFailureReason = reason
                    print("[CEREBRAS] \(reason) — falling through immediately (no retry)")
                    return nil
                }
                if attempt < maxRetries {
                    let delay = backoffMs[attempt]
                    print("[CEREBRAS] transient failure (\(reason)) — retry \(attempt + 1)/\(maxRetries) in \(delay)ms")
                    try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                    continue
                }
                // Final attempt failed — record under base reason, surface
                // with attempt count so caller / logs can see we tried.
                recordFailure(reason)
                lastFailureReason = reason
                print("[CEREBRAS] transient: \(reason) (after \(maxRetries + 1) attempts)")
                return nil

            case .permanentFailure(let reason):
                recordFailure(reason)
                lastFailureReason = reason
                print("[CEREBRAS] permanent: \(reason)")
                return nil
            }
        }
        return nil
    }

    /// Single-attempt request. Returns success / transient / permanent so
    /// the outer retry loop can decide whether to back off and try again.
    private func polishOnce(
        text: String,
        systemPrompt: String,
        apiKey: String,
        maxTokens: Int,
        cacheKey: String?,
        totalTimeout: TimeInterval,
        firstTokenTimeout: TimeInterval,
        estimatedTokens: Int
    ) async -> AttemptResult {
        let started = CFAbsoluteTimeGetCurrent()

        // Build OpenAI-compatible payload. max_tokens is caller-supplied so
        // short inputs don't reserve a full 2048-token window unnecessarily.
        //
        // prompt_cache_key: routes requests that share the same system prompt
        // to the same Cerebras cache slot. The system prompt is 1200+ tokens
        // and never changes call-to-call — caching it drops TTFT measurably.
        // Cached in 128-token blocks with a 5-min TTL (up to 1h under load).
        //
        // stream_options.include_usage: Cerebras sends a final usage chunk
        // so we can record actual token counts for the rate limiter.
        var payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": text],
            ],
            "temperature": 0.2,
            "max_tokens": maxTokens,
            // gpt-oss-120b is a REASONING model: at default effort it spends
            // the whole max_tokens budget "thinking" before emitting the
            // answer, so on larger inputs `content` came back EMPTY → the app
            // demoted to the slow local 4B (the "it's using local / it's slow"
            // bug). Light-touch polish needs zero reasoning — "low" makes it
            // emit the cleaned text immediately. Cerebras accepts this field.
            "reasoning_effort": "low",
            "stream": true,
            "stream_options": ["include_usage": true],
        ]
        if let key = cacheKey {
            payload["prompt_cache_key"] = key
        }

        var req = URLRequest(url: endpoint, timeoutInterval: totalTimeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        // Cerebras sits behind Cloudflare, which 1010-blocks requests with a
        // non-browser fingerprint (URLSession's default CFNetwork UA gets
        // banned). A browser-style User-Agent is required or every call fails
        // with HTTP 403 "error code: 1010". This was the silent cause of cloud
        // never working in-app.
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            print("[CEREBRAS] payload encode failed: \(error)")
            // Encode failures are deterministic — not transient.
            return .permanentFailure("encode-failed")
        }

        do {
            // SSE streaming — lower TTFT vs. waiting for the full response.
            let (asyncBytes, response) = try await URLSession.shared.bytes(for: req)
            guard let http = response as? HTTPURLResponse else {
                print("[CEREBRAS] no HTTP response")
                return .transientFailure("network")
            }
            guard (200..<300).contains(http.statusCode) else {
                // Drain a few KB of the error body for diagnostics.
                var errBody = ""
                for try await line in asyncBytes.lines {
                    errBody += line
                    if errBody.count > 400 { break }
                }
                print("[CEREBRAS] HTTP \(http.statusCode): \(errBody.prefix(300))")
                return classifyHTTPStatus(http.statusCode)
            }

            // Parse SSE lines: `data: {...}` chunks; `data: [DONE]` terminates.
            // The final chunk (before [DONE]) carries usage when stream_options.include_usage=true.
            var accumulated = ""
            // Fallback buffer: some models (notably gpt-oss on some hosts)
            // stream the final answer in `delta.reasoning` /
            // `delta.reasoning_content` with `delta.content` null. We keep this
            // separate and only use it if `content` ends up empty (see below)
            // so we never splice chain-of-thought into normal output.
            var accumulatedReasoning = ""
            var inputTokens = 0; var outputTokens = 0; var cachedTokens = 0
            var firstTokenSeen = false

            // First-token timeout: wrap the streaming consumer in a race
            // against a timeout task. If no first SSE byte arrives within
            // firstTokenTimeout, abandon the attempt as transient.
            let streamResult: AttemptResult? = await withTaskGroup(of: AttemptResult?.self) { group -> AttemptResult? in
                group.addTask { [firstTokenTimeout] in
                    try? await Task.sleep(nanoseconds: UInt64(firstTokenTimeout * 1_000_000_000))
                    // If we make it here, the consume task hasn't produced
                    // a first token yet. Signal first-token timeout.
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
                                // Capture reasoning-channel text as a fallback
                                // only. gpt-oss on some hosts emits the answer
                                // here with content null. We never merge it into
                                // `accumulated` directly.
                                if let r = delta["reasoning"] as? String {
                                    accumulatedReasoning += r
                                } else if let r = delta["reasoning_content"] as? String {
                                    accumulatedReasoning += r
                                }
                            }
                            if let usage = parsed["usage"] as? [String: Any] {
                                inputTokens  = usage["prompt_tokens"]     as? Int ?? 0
                                outputTokens = usage["completion_tokens"] as? Int ?? 0
                                if let details = usage["prompt_tokens_details"] as? [String: Any] {
                                    cachedTokens = details["cached_tokens"] as? Int ?? 0
                                }
                            }
                        }
                        // Stream completed cleanly.
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

                // Wait for whichever finishes first. If the consume task
                // wins with nil (clean completion), we want to keep the
                // accumulated buffer; if the timeout task wins, return
                // its timeout-firsttoken result.
                if let firstResult = await group.next() {
                    group.cancelAll()
                    // firstResult might be nil from the consume task (success-ish),
                    // or a non-nil transient failure (from either task).
                    if firstResult == nil { return nil }
                    // Only honor first-token timeout if no token actually arrived.
                    if case .transientFailure("timeout-firsttoken") = firstResult, firstTokenSeen {
                        // Token did arrive — wait for the streaming task to
                        // finish naturally. Drain remaining results.
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
            // Robust extraction: if `content` was empty/null but the model
            // streamed its answer on the reasoning channel, recover it. Guard
            // with a heuristic so we don't surface visible chain-of-thought:
            // skip text that opens with obvious thinking markers.
            if result.isEmpty {
                let reasoning = accumulatedReasoning.trimmingCharacters(in: .whitespacesAndNewlines)
                if !reasoning.isEmpty, !Self.looksLikeChainOfThought(reasoning) {
                    print("[CEREBRAS] content empty — recovered answer from reasoning field (\(reasoning.count) chars)")
                    result = reasoning
                }
            }
            guard !result.isEmpty else {
                print("[CEREBRAS] empty streamed response")
                return .transientFailure("empty-response")
            }

            // Update latency stats for adaptive routing.
            lastLatencyMs = dt
            sampleCount += 1
            avgLatencyMs = avgLatencyMs + (Double(dt) - avgLatencyMs) / Double(sampleCount)

            // Record metrics.
            successCount += 1
            lastSuccessAt = Date()

            // Record actual usage in the rate limiter.
            let effectiveIn = inputTokens > 0 ? inputTokens : estimatedTokens
            await CerebrasRateLimiter.shared.record(
                inputTokens:  effectiveIn,
                outputTokens: outputTokens,
                cachedTokens: cachedTokens
            )
            print("[CEREBRAS] \(dt)ms | in=\(inputTokens) out=\(outputTokens) cached=\(cachedTokens) | avg=\(Int(avgLatencyMs))ms")
            print("[VOICE-CEREBRAS] prompt_chars=\(systemPrompt.count) input_chars=\(text.count) latency_ms=\(dt)")
            return .success(result)

        } catch let urlError as URLError where urlError.code == .timedOut {
            print("[CEREBRAS] request timed out")
            return .transientFailure("timeout-total")
        } catch let urlError as URLError where urlError.code == .notConnectedToInternet
                                                  || urlError.code == .networkConnectionLost
                                                  || urlError.code == .dnsLookupFailed
                                                  || urlError.code == .cannotConnectToHost {
            print("[CEREBRAS] network failure: \(urlError.code)")
            return .transientFailure("network")
        } catch {
            print("[CEREBRAS] request failed: \(error)")
            return .transientFailure("network")
        }
    }

    /// Map HTTP status to a structured AttemptResult. Permanent vs. transient
    /// classification follows the policy in the file header.
    private func classifyHTTPStatus(_ code: Int) -> AttemptResult {
        switch code {
        case 400: return .permanentFailure("bad-request")
        case 401, 403: return .permanentFailure("auth")
        case 404: return .permanentFailure("bad-request")
        case 429:
            // Cerebras free tier is 30 RPM. A 429 doesn't mean "this request
            // is unrecoverable forever" — it means "you sent too many in the
            // last 60 seconds." The rate window typically resets within
            // 5-15 seconds for a burst, so a transient retry with the
            // existing backoff (200ms + 500ms) gives the window a chance to
            // clear. If it's still 429 after 2 retries, the caller falls
            // through to local. Treat as transient so the retry layer kicks
            // in instead of immediately demoting.
            return .transientFailure("rate-limit")
        case 500..<600: return .transientFailure("server-error")
        default: return .transientFailure("server-error")
        }
    }

    /// Increment the per-reason failure tally.
    private func recordFailure(_ reason: String) {
        failureCounts[reason, default: 0] += 1
    }

    /// Heuristic guard for the reasoning-channel fallback. Returns true when
    /// the text reads like exposed chain-of-thought rather than a final
    /// answer, so we can refuse to surface it. Conservative on purpose: we'd
    /// rather drop a borderline case than splice "Let me think..." into the
    /// user's polished output.
    ///
    /// NOTE: This only runs when `content` was empty AND a reasoning field had
    /// text — the common gpt-oss-on-some-hosts case where the *entire* answer
    /// lands in `reasoning`. If a host interleaves true CoT with the answer in
    /// the same field we can't separate them here; that case returns true and
    /// the polish fails fast to the next provider rather than leaking CoT.
    static func looksLikeChainOfThought(_ text: String) -> Bool {
        let head = text.prefix(80).lowercased()
        let markers = [
            "let me think", "let's think", "let me ", "we need to",
            "first, ", "okay, ", "ok, so", "the user wants",
            "the user is asking", "i need to", "i should", "analysis:",
            "<think", "reasoning:",
        ]
        return markers.contains { head.hasPrefix($0) || head.contains($0) }
    }
}
