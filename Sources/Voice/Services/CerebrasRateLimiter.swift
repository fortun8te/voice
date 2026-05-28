// CerebrasRateLimiter.swift
//
// Tracks Cerebras free-tier usage and gates cloud calls before they hit limits.
//
// Free tier limits (as of 2025):
//   Requests:  5/min  · 150/hr  · 2,400/day
//   Tokens:    30,000/min  · 1,000,000/hr  · 1,000,000/day
//
// Strategy: rolling windows. Every request and its token count are timestamped.
// Before each cloud call, stale entries are purged and we check all 6 limits.
// If any limit is within a safety buffer (80% for requests, 90% for tokens),
// the call falls back to local instead of risking a 429.
//
// Token estimation before the call uses a rough heuristic (chars / 4).
// Actual token usage is recorded from the API response after the call.

import Foundation

@MainActor
final class CerebrasRateLimiter {
    static let shared = CerebrasRateLimiter()
    private init() {}

    // MARK: - Limits (free tier)

    // The user explicitly chose cloud in Settings — their choice wins. Our
    // local quota check is no longer authoritative; we let the Cerebras
    // server's 429 be the source of truth. Raised from 5/min → 30/min so
    // typical dictation cadence (one polish every couple of seconds) doesn't
    // trip a local block. The hourly and daily caps stay generous as a
    // long-horizon safety net against runaway loops.
    private let maxReqPerMinute  = 30
    private let maxReqPerHour    = 600
    private let maxReqPerDay     = 4_000

    private let maxTokPerMinute  = 30_000
    private let maxTokPerHour    = 1_000_000
    private let maxTokPerDay     = 1_000_000

    // Safety margin tightened: stop at 60% of per-minute requests, 90% of
    // longer-window limits. The 60% factor leaves 12 RPM of headroom — so
    // bursty user dictation can't push us into Cerebras's actual 30 RPM
    // ceiling. Previous 0.80 was letting bursts slip through and earning
    // real server-side 429s, which fell through to local. Better to slow
    // OURSELVES at 18/min than let Cerebras 429 us at 30/min.
    private let reqSafetyFactor  = 0.60
    private let tokSafetyFactor  = 0.90

    // MARK: - Rolling windows

    private struct Entry { let timestamp: Date; let tokens: Int }
    private var entries: [Entry] = []

    // MARK: - Session-level counters (exposed for UI / debug)

    private(set) var totalRequestsThisSession = 0
    private(set) var totalInputTokensThisSession  = 0
    private(set) var totalOutputTokensThisSession = 0
    private(set) var totalCachedTokensThisSession = 0

    // MARK: - Gate

    /// Returns true if a call with the estimated token count can proceed.
    /// Purges stale entries first. Call this BEFORE sending to Cerebras.
    func canProceed(estimatedTokens: Int) -> Bool {
        purgeStale()
        let now = Date()

        let reqMin  = entries.filter { now.timeIntervalSince($0.timestamp) <= 60 }.count
        let reqHr   = entries.filter { now.timeIntervalSince($0.timestamp) <= 3600 }.count
        let reqDay  = entries.count   // all remaining are within 24h after purge

        let tokMin  = entries.filter { now.timeIntervalSince($0.timestamp) <= 60 }.reduce(0) { $0 + $1.tokens }
        let tokHr   = entries.filter { now.timeIntervalSince($0.timestamp) <= 3600 }.reduce(0) { $0 + $1.tokens }
        let tokDay  = entries.reduce(0) { $0 + $1.tokens }

        let reqMinOK  = Double(reqMin)  < Double(maxReqPerMinute) * reqSafetyFactor
        let reqHrOK   = Double(reqHr)   < Double(maxReqPerHour)   * reqSafetyFactor
        let reqDayOK  = Double(reqDay)  < Double(maxReqPerDay)     * reqSafetyFactor
        let tokMinOK  = Double(tokMin + estimatedTokens) < Double(maxTokPerMinute) * tokSafetyFactor
        let tokHrOK   = Double(tokHr  + estimatedTokens) < Double(maxTokPerHour)   * tokSafetyFactor
        let tokDayOK  = Double(tokDay + estimatedTokens) < Double(maxTokPerDay)     * tokSafetyFactor

        if !reqMinOK  { print("[CEREBRAS-RL] blocked: req/min \(reqMin)/\(maxReqPerMinute)") }
        if !reqHrOK   { print("[CEREBRAS-RL] blocked: req/hr \(reqHr)/\(maxReqPerHour)") }
        if !reqDayOK  { print("[CEREBRAS-RL] blocked: req/day \(reqDay)/\(maxReqPerDay)") }
        if !tokMinOK  { print("[CEREBRAS-RL] blocked: tok/min \(tokMin)+\(estimatedTokens)/\(maxTokPerMinute)") }
        if !tokHrOK   { print("[CEREBRAS-RL] blocked: tok/hr \(tokHr)+\(estimatedTokens)/\(maxTokPerHour)") }
        if !tokDayOK  { print("[CEREBRAS-RL] blocked: tok/day \(tokDay)+\(estimatedTokens)/\(maxTokPerDay)") }

        return reqMinOK && reqHrOK && reqDayOK && tokMinOK && tokHrOK && tokDayOK
    }

    /// Record a completed call. Pass actual token counts from the API response.
    func record(inputTokens: Int, outputTokens: Int, cachedTokens: Int) {
        let total = inputTokens + outputTokens
        entries.append(Entry(timestamp: Date(), tokens: total))
        totalRequestsThisSession      += 1
        totalInputTokensThisSession   += inputTokens
        totalOutputTokensThisSession  += outputTokens
        totalCachedTokensThisSession  += cachedTokens
        print("[CEREBRAS-RL] recorded \(total) tokens (in=\(inputTokens) out=\(outputTokens) cached=\(cachedTokens)) | session totals: \(totalRequestsThisSession) reqs, \(totalInputTokensThisSession+totalOutputTokensThisSession) tokens")
    }

    // MARK: - Quota snapshot (for UI or logs)

    struct QuotaSnapshot {
        let reqMin: Int; let maxReqMin: Int
        let reqHr:  Int; let maxReqHr:  Int
        let reqDay: Int; let maxReqDay: Int
        let tokMin: Int; let maxTokMin: Int
        let tokHr:  Int; let maxTokHr:  Int
        let tokDay: Int; let maxTokDay: Int
    }

    func snapshot() -> QuotaSnapshot {
        purgeStale()
        let now = Date()
        let rm = entries.filter { now.timeIntervalSince($0.timestamp) <= 60 }
        let rh = entries.filter { now.timeIntervalSince($0.timestamp) <= 3600 }
        return QuotaSnapshot(
            reqMin: rm.count,      maxReqMin: maxReqPerMinute,
            reqHr:  rh.count,      maxReqHr:  maxReqPerHour,
            reqDay: entries.count, maxReqDay:  maxReqPerDay,
            tokMin: rm.reduce(0) { $0 + $1.tokens },  maxTokMin: maxTokPerMinute,
            tokHr:  rh.reduce(0) { $0 + $1.tokens },  maxTokHr:  maxTokPerHour,
            tokDay: entries.reduce(0) { $0 + $1.tokens }, maxTokDay: maxTokPerDay
        )
    }

    // MARK: - Helpers

    private func purgeStale() {
        let cutoff = Date().addingTimeInterval(-86_400)  // 24h
        entries.removeAll { $0.timestamp < cutoff }
    }

    /// Rough token estimate from text length. Accurate enough for gating.
    static func estimateTokens(systemPrompt: String, userText: String) -> Int {
        // ~4 chars per token on average for English + JSON
        return (systemPrompt.count + userText.count) / 4 + 50
    }
}
