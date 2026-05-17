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

import Foundation

@MainActor
public final class CerebrasPolisher {
    public static let shared = CerebrasPolisher()
    private init() {}

    /// Free-tier model on Cerebras. Qwen 3 235B (MoE, ~22B active) Instruct.
    /// 65,536 token context, ~1000+ tokens/sec on Cerebras' wafer-scale silicon.
    /// Strongest of the four free-tier options (alternatives: gpt-oss-120b,
    /// zai-glm-4.7, llama3.1-8b).
    private let model = "qwen-3-235b-a22b-instruct-2507"

    private let endpoint = URL(string: "https://api.cerebras.ai/v1/chat/completions")!

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

    /// Word threshold for routing to cloud — below this we stay local for
    /// minimal latency. Long inputs benefit the most from a bigger model.
    public static var minWordCount: Int { 20 }

    // MARK: - Polish

    /// Last failure reason, if any. Set by polish() when a cloud call fails.
    /// Used by the orchestrator to surface a toast.
    public private(set) var lastFailureReason: String?

    /// Polish via Cerebras. Returns the polished text on success, or `nil`
    /// on any failure (network error, API error, bad key, timeout). Callers
    /// fall back to the local polish path on `nil`, then inspect
    /// `lastFailureReason` to surface a toast.
    public func polish(
        _ text: String,
        systemPrompt: String,
        timeoutSeconds: TimeInterval = 8.0
    ) async -> String? {
        guard Self.isAvailable else {
            lastFailureReason = "not configured"
            return nil
        }
        let apiKey = Self.apiKey
        lastFailureReason = nil

        // Signal to the transcribing pill that the cloud glyph should show.
        // Reset in defer so failures/exits all clear the flag.
        PolishStatus.shared.isCloudPolishing = true
        defer { PolishStatus.shared.isCloudPolishing = false }

        let started = CFAbsoluteTimeGetCurrent()

        // Build OpenAI-compatible payload.
        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": text],
            ],
            "temperature": 0.2,
            "max_tokens": 2048,
            "stream": false,
        ]

        var req = URLRequest(url: endpoint, timeoutInterval: timeoutSeconds)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            print("[CEREBRAS] payload encode failed: \(error)")
            lastFailureReason = "encode failed"
            return nil
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                print("[CEREBRAS] no HTTP response")
                lastFailureReason = "no response"
                return nil
            }
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? "<binary>"
                print("[CEREBRAS] HTTP \(http.statusCode): \(body.prefix(300))")
                switch http.statusCode {
                case 401, 403: lastFailureReason = "invalid API key"
                case 429:      lastFailureReason = "rate limit hit"
                case 500..<600: lastFailureReason = "server error"
                default:       lastFailureReason = "HTTP \(http.statusCode)"
                }
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                print("[CEREBRAS] malformed response")
                lastFailureReason = "malformed response"
                return nil
            }
            let dt = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
            print("[CEREBRAS] polish complete in \(dt)ms (input \(text.count) chars → output \(content.count) chars)")
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let urlError as URLError where urlError.code == .timedOut {
            print("[CEREBRAS] request timed out")
            lastFailureReason = "timeout"
            return nil
        } catch let urlError as URLError where urlError.code == .notConnectedToInternet || urlError.code == .networkConnectionLost {
            print("[CEREBRAS] no internet")
            lastFailureReason = "no internet"
            return nil
        } catch {
            print("[CEREBRAS] request failed: \(error)")
            lastFailureReason = "network error"
            return nil
        }
    }
}
