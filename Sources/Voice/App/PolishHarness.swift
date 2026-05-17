// VOICE — Polish Harness
// ============================================================
// Headless CLI test harness for the polish pipeline. Loads every JSON file
// in Sources/Voice/Resources/GoldenCases/, runs each through the production
// polish pipeline (Qwen3Polisher.polish — which internally runs
// RestartCorrectionPreprocessor and PolishPostprocessor), compares against
// the `reference` field via trigram-Jaccard similarity, and prints per-case
// pass/fail plus aggregate stats.
//
// Invocation:
//   swift run -c release Voice --polish-harness [path/to/cases]
//
// Default cases dir: Sources/Voice/Resources/GoldenCases (relative to CWD).
//
// Implementation note (why this file lives inside the Voice target rather
// than a separate executable target): the polish pipeline types are
// `internal` and used extensively from the rest of the Voice target.
// Splitting them into a `VoiceCore` library would require making dozens of
// types `public` — too invasive for a read-only test harness. Gating off
// `--polish-harness` from `VoiceEntryPoint.main()` keeps the surface area
// of the change minimal. See VoiceApp.swift for the entry-point branch.
// ============================================================

import Foundation

// Force-flush every print so the log file gets output even when stdout is
// redirected to a file (which makes Swift's runtime use full buffering).
private func hprint(_ msg: String = "") {
    let line = msg + "\n"
    FileHandle.standardOutput.write(Data(line.utf8))
}

@MainActor
enum PolishHarness {

    // MARK: - Golden case schema

    struct GoldenCase: Codable {
        let id: String
        let title: String?
        let raw: String
        let reference: String
        let cleanupLevel: String
        let personality: String?
        let categories: [String]?
    }

    // MARK: - Similarity (trigram Jaccard)

    static func trigrams(_ s: String) -> [String] {
        // Normalize: lowercased, collapse whitespace, strip leading/trailing.
        let normalized = s.lowercased()
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        let chars = Array(normalized)
        guard chars.count >= 3 else { return [normalized] }
        return (0...(chars.count - 3)).map { String(chars[$0..<$0+3]) }
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        let aSet = Set(trigrams(a))
        let bSet = Set(trigrams(b))
        let inter = aSet.intersection(bSet).count
        let union = aSet.union(bSet).count
        return union == 0 ? 1.0 : Double(inter) / Double(union)
    }

    // MARK: - Runner

    static func run(goldenCasesDir: String) async {
        let dirURL = URL(fileURLWithPath: goldenCasesDir, isDirectory: true)
        hprint("[HARNESS] Loading cases from: \(dirURL.path)")

        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: dirURL, includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            hprint("[HARNESS] FATAL: cannot list directory \(dirURL.path): \(error)")
            return
        }

        let decoder = JSONDecoder()
        var cases: [GoldenCase] = []
        for url in urls {
            do {
                let data = try Data(contentsOf: url)
                let c = try decoder.decode(GoldenCase.self, from: data)
                cases.append(c)
            } catch {
                print("[HARNESS] skip \(url.lastPathComponent): decode error \(error)")
            }
        }
        hprint("[HARNESS] Loaded \(cases.count) golden cases")

        guard !cases.isEmpty else {
            hprint("[HARNESS] No cases — nothing to do.")
            return
        }

        // Prewarm Qwen3. polish() fails open immediately if not ready, so we
        // explicitly wait for both the 1.7B and (if any case uses high
        // cleanup) the 4B before starting.
        hprint("[HARNESS] Qwen3 isAvailable=\(Qwen3Polisher.isAvailable) isEnabled=\(Qwen3Polisher.isEnabled)")
        guard Qwen3Polisher.isAvailable else {
            hprint("[HARNESS] FATAL: MLX not linked at build time.")
            return
        }

        let needsLarge = cases.contains { $0.cleanupLevel.lowercased() == "high" }
        hprint("[HARNESS] Prewarming Qwen3 (needs 4B model: \(needsLarge))…")
        Qwen3Polisher.shared.prewarm()

        // Wait for the 1.7B (1.7B "ready" is what polish() requires).
        let warmupDeadline = Date().addingTimeInterval(300) // 5 min cap
        while !Qwen3Polisher.shared.availabilityStatus.isReady {
            if Date() > warmupDeadline {
                print("[HARNESS] FATAL: 1.7B did not become ready within 5 min (status=\(Qwen3Polisher.shared.availabilityStatus.displayLabel))")
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        hprint("[HARNESS] 1.7B ready.")

        if needsLarge {
            let largeDeadline = Date().addingTimeInterval(300)
            while !Qwen3Polisher.shared.isLargeModelReady {
                if Date() > largeDeadline {
                    print("[HARNESS] WARN: 4B did not warm in 5 min — high-cleanup cases may fall back to 1.7B")
                    break
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            if Qwen3Polisher.shared.isLargeModelReady {
                print("[HARNESS] 4B ready.")
            }
        }

        // Per-case run
        struct Failure {
            let id: String
            let sim: Double
            let got: String
            let expected: String
        }
        var totalSim = 0.0
        var passes = 0
        var failures: [Failure] = []
        var totalPolishMs = 0
        let runStart = Date()

        for c in cases {
            let polishStart = Date()
            let got = await Qwen3Polisher.shared.polish(
                c.raw,
                context: .default,
                timeoutMs: 30_000,
                suspectWords: nil,
                userVocabulary: nil,
                fieldContext: nil,
                cleanupLevel: c.cleanupLevel,
                personalityStyle: c.personality ?? "neutral"
            )
            let polishMs = Int(Date().timeIntervalSince(polishStart) * 1000)
            totalPolishMs += polishMs

            let sim = similarity(got, c.reference)
            totalSim += sim
            let passed = sim >= 0.5  // trigram Jaccard threshold (LLM polish is paraphrase-y)
            if passed {
                passes += 1
            } else {
                failures.append(Failure(id: c.id, sim: sim, got: got, expected: c.reference))
            }
            let mark = passed ? "PASS" : "FAIL"
            hprint("[\(mark)] \(c.id) sim=\(String(format: "%.3f", sim)) polish=\(polishMs)ms cleanup=\(c.cleanupLevel)")
        }

        let totalMs = Int(Date().timeIntervalSince(runStart) * 1000)
        let avg = totalSim / Double(cases.count)

        hprint("")
        hprint("=== SUMMARY ===")
        hprint("Cases:       \(cases.count)")
        hprint("Passes:      \(passes)")
        hprint("Fails:       \(cases.count - passes)")
        hprint("Avg sim:     \(String(format: "%.3f", avg))")
        hprint("Polish time: \(totalPolishMs)ms total, avg \(totalPolishMs / max(cases.count, 1))ms/case")
        hprint("Wall time:   \(totalMs)ms")

        if !failures.isEmpty {
            // Sort by worst first; show up to 5
            let sorted = failures.sorted { $0.sim < $1.sim }
            hprint("")
            hprint("=== FAILURES (worst first) ===")
            for f in sorted.prefix(5) {
                print("")
                print("--- \(f.id) (sim=\(String(format: "%.3f", f.sim))) ---")
                print("EXPECTED:")
                print(f.expected)
                print("GOT:")
                print(f.got)
            }
        }
    }
}
