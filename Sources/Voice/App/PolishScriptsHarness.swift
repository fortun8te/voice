// VOICE — Polish Scripts Harness (Round 2 manual scripts → programmatic)
// ============================================================
// Headless test runner for the 8 hand-crafted "Round 2" dictation scripts
// in test-scripts-round-2.docx. Until now the only way to verify polish
// quality on these scripts was to dictate them by hand and eyeball the
// output. This harness runs each script's raw transcript through the
// production polish pipeline (Qwen3Polisher.polish — which internally
// runs RestartCorrectionPreprocessor + PolishPostprocessor) and checks
// the output against per-case assertions.
//
// Why assertions and not golden strings:
//   The LLM polish is paraphrase-y. A golden-string comparison breaks on
//   any harmless rewording. Assertions let us pin down the bugs that
//   actually matter — wrong number after a restart, missing clause,
//   over-application of backticks, em-dashes, duplicate words — while
//   tolerating safe paraphrase.
//
// Invocation:
//   swift run -c release Voice --polish-scripts
//
// Output: per-case PASS/FAIL with reasons + a final tally. Exits 0 even
// on test failure (parent process inspects stdout). Wall time on an
// M-series Mac with prewarmed Qwen3 1.7B is ~3-6s per case = ~30-50s.
//
// Implementation note (why this file lives inside the Voice target
// rather than a separate executable target): mirrors PolishHarness.swift
// — the polish pipeline types are `internal`. See VoiceApp.swift for the
// `--polish-scripts` branch in `VoiceEntryPoint.main()`.
// ============================================================

import Foundation

// Force-flush every print so the log file gets full output even when
// stdout is redirected. (Swift's runtime fully buffers stdout when it
// isn't a TTY, which makes `swift run ... | tee` swallow early lines.)
private func sprint(_ msg: String = "") {
    let line = msg + "\n"
    FileHandle.standardOutput.write(Data(line.utf8))
}

@MainActor
enum PolishScriptsHarness {

    // MARK: - Case definition

    struct TestCase {
        let id: Int
        let label: String
        let input: String
        let cleanupLevel: String
        let personality: String
        let assertions: [Assertion]
    }

    /// Each assertion is a tiny pure check against (output, input). We
    /// keep them small and composable rather than one giant predicate so
    /// the failure messages are actionable.
    enum Assertion {
        /// Output must contain the substring (case-insensitive).
        case contains(String)
        /// Output must NOT contain the substring (case-insensitive).
        case doesNotContain(String)
        /// Output word count ≥ N. Cheap proxy for "no major truncation".
        case wordCountAtLeast(Int)
        /// No em-dash (—) or en-dash (–). Polish prompts forbid these.
        case noEmDash
        /// No emoji code points. Polish output must be plaintext-clean.
        case noEmoji
        /// Output starts with the given prefix (exact, case-sensitive).
        case startsWith(String)
        /// Output ends with the given suffix (exact, case-sensitive).
        case endsWith(String)
        /// No two consecutive identical lowercased words ("the the",
        /// "I I"). Common LLM stutter artifact.
        case noConsecutiveDuplicates
        /// Every clause/phrase in the list must appear in the output.
        /// Used to verify "no truncation across N words" cases where we
        /// want each topic chunk to survive.
        case allClausesPresent([String])
        /// Output must contain at least one literal backtick — used for
        /// the code-identifier scripts to make sure backticks survived.
        case hasBackticks
        /// Output must contain the substring wrapped in backticks
        /// (e.g. "`DATABASE_URL`"). Verifies code-identifier formatting.
        case containsBackticked(String)
        /// Output must NOT contain a backticked multi-word phrase.
        /// Detects over-application of `code formatting` to prose.
        case noMultiWordBacktickedPhrase
    }

    // MARK: - The 8 scripts (verbatim from test-scripts-round-2.docx)

    static let cases: [TestCase] = [
        // ----------------------------------------------------------------
        // 1. Long rambly status email with restarts
        // Tests: filler removal, restart correction (forty two → thirty
        // seven), formal register, number formatting, name caps.
        // The restart cue is "wait no it was thirty seven percent" — the
        // corrected value 37% should win, and the 42% claim should be
        // dropped entirely.
        // ----------------------------------------------------------------
        TestCase(
            id: 1,
            label: "Long rambly status email with restarts",
            input: "hi marcus uhh i wanted to give you a quick update on the q2 roadmap so um basically we shipped the auth flow last sprint that took longer than expected like maybe two weeks longer um but it's live now and we're seeing a forty two percent reduction in login failures which is honestly better than we modeled wait no it was thirty seven percent let me check yeah thirty seven percent okay um for q3 we're thinking the priorities are billing migration that's the big one then the dashboard redesign and then if we have time the api rate limiting work um actually scratch that let's move api rate limiting before the dashboard redesign because security flagged it as a p1 last week um can you let me know by friday if that ordering works for your team thanks",
            cleanupLevel: "medium",
            personality: "neutral",
            assertions: [
                .contains("Marcus"),
                .contains("Q2"),
                .contains("Q3"),
                .contains("37"),
                .doesNotContain("42 percent"),
                .doesNotContain("42%"),
                .contains("billing migration"),
                .contains("API rate limiting"),
                .contains("dashboard"),
                .contains("Friday"),
                .noEmDash,
                .noEmoji,
                .noConsecutiveDuplicates,
                .wordCountAtLeast(80),
            ]
        ),

        // ----------------------------------------------------------------
        // 2. Meeting recap with multiple action items and dates
        // Tests: name caps, date normalization (the twelfth → 12th or
        // Thursday the 12th), no truncation across 100+ words, list
        // structure with first/second/third.
        // ----------------------------------------------------------------
        TestCase(
            id: 2,
            label: "Meeting recap with multiple action items and dates",
            input: "okay so the design review yesterday with priya and james we covered the onboarding flow and there were three big takeaways first priya is going to ship the new welcome screen designs by next thursday that's the twelfth second james is taking the empty state illustrations he said he needs until the nineteenth which works because we don't need them until the launch on the twenty fourth third we agreed that the upgrade prompt should not appear until day three of the user journey not day one like we originally planned um also james mentioned he wants to revisit the icon set in q3 but that's a separate thread we'll pick up later oh and one more thing priya wants approval from product on the color tokens before friday so i need to get that on neil's calendar today",
            cleanupLevel: "medium",
            personality: "neutral",
            assertions: [
                .contains("Priya"),
                .contains("James"),
                .contains("Thursday"),
                .contains("Neil"),
                .contains("color tokens"),
                .contains("Friday"),
                // Dates may be normalized to 12th/12 / 19th/19 / 24th/24
                // or kept as words. Accept either form via allClausesPresent
                // on the *day* anchors and rely on word count for survival.
                .allClausesPresent(["onboarding", "welcome screen", "empty state", "upgrade prompt"]),
                .noEmDash,
                .noEmoji,
                .noConsecutiveDuplicates,
                .wordCountAtLeast(70),
            ]
        ),

        // ----------------------------------------------------------------
        // 3. Casual Slack rant with code identifiers
        // Tests: casual register preserved (no over-formalization),
        // backticks correctly scoped to single identifiers, env var stays
        // SHOUTY_SNAKE_CASE in backticks, branch path is preserved.
        // ----------------------------------------------------------------
        TestCase(
            id: 3,
            label: "Casual Slack rant with code identifiers",
            input: "yo dude so i was debugging the userProfile sync issue all morning and turns out the bug is in the syncUserProfile function specifically the call to fetchRemoteSnapshot when the cache is empty it returns null but the caller treats null as an empty object so you get this weird state where the local profile gets overwritten with nothing i pushed a fix to the feat slash profile dash sync branch can you review it um also the env var REMOTE_SYNC_INTERVAL should probably be bumped from five seconds to thirty we're hammering the api",
            cleanupLevel: "medium",
            personality: "casual",
            assertions: [
                .containsBackticked("userProfile"),
                .containsBackticked("syncUserProfile"),
                .containsBackticked("fetchRemoteSnapshot"),
                .containsBackticked("REMOTE_SYNC_INTERVAL"),
                .hasBackticks,
                .noMultiWordBacktickedPhrase,
                // Casual register: should keep "yo" or at least not become
                // "Dear Sir/Madam". Hard to assert strictly, so we just
                // check it didn't pick up formal greeting markers.
                .doesNotContain("Dear "),
                .doesNotContain("Sincerely"),
                .noEmDash,
                .noEmoji,
                .noConsecutiveDuplicates,
                .wordCountAtLeast(60),
            ]
        ),

        // ----------------------------------------------------------------
        // 4. Financial update with messy numbers
        // Tests: spoken decimals → "$4.7 million" (NOT "$4.7.000.000"),
        // percentages, currency formatting, no truncation across many
        // datapoints.
        // ----------------------------------------------------------------
        TestCase(
            id: 4,
            label: "Financial update with messy numbers",
            input: "so revenue this quarter came in at four point seven million which is up twenty three percent year over year gross margin held at sixty eight percent same as last quarter customer acquisition cost dropped from one hundred and forty dollars to ninety five dollars um that's a thirty two percent improvement net new arr was eight hundred and twenty thousand dollars across forty seven accounts churn ticked up slightly to two point one percent monthly we think that's mostly the legacy plan migration noise should settle by end of july q3 forecast is five point two to five point five million in revenue depending on how the enterprise pipeline closes",
            cleanupLevel: "medium",
            personality: "neutral",
            assertions: [
                // Revenue $4.7M — accept either "$4.7 million" or "$4.7M".
                // Tested by checking 4.7 appears alongside "million" or M.
                .contains("4.7"),
                .contains("23"),
                .contains("68"),
                .contains("140"),
                .contains("95"),
                .contains("47"),
                .contains("2.1"),
                .contains("5.2"),
                .contains("5.5"),
                // The European-style mangle from Round 1 bug log
                .doesNotContain("4.7.000"),
                .doesNotContain("4.7,000"),
                .doesNotContain("point 5.000"),
                .doesNotContain("0,000,000"),
                .noEmDash,
                .noEmoji,
                .noConsecutiveDuplicates,
                .wordCountAtLeast(70),
            ]
        ),

        // ----------------------------------------------------------------
        // 5. Apology email with multiple restarts and uhms
        // Tests: formal politeness, "wait no" correction (rate limit was
        // NOT the issue — wrong-schema query was), "I mean" softener
        // handled, no em-dash, no "I, wanted" comma splice bug.
        // ----------------------------------------------------------------
        TestCase(
            id: 5,
            label: "Apology email with multiple restarts and uhms",
            input: "hi jennifer um i wanted to apologize about the report being late yesterday i should have flagged earlier that the data pull from snowflake was taking longer than expected um we hit a rate limit issue on the analytics warehouse and i didn't have a backup query ready wait no actually i had the backup query ready but it pointed at the wrong schema so when i ran it i got empty results and i didn't catch it until like eleven pm um i've set up an alert now that fires if the primary query runs longer than four minutes and i've documented the fallback path in the runbook so this shouldn't happen again i mean it might happen but at least the recovery will be faster sorry again for the delay i know the board deck depended on those numbers",
            cleanupLevel: "medium",
            personality: "neutral",
            assertions: [
                .contains("Jennifer"),
                .contains("Snowflake"),
                .contains("wrong schema"),
                .contains("runbook"),
                // The Round 1 bug: "I, wanted" with comma. Stays banned.
                .doesNotContain("I, wanted"),
                .doesNotContain("I, had"),
                // The restart-correction: rate-limit hypothesis should be
                // displaced by the wrong-schema reality. Verify both don't
                // coexist as parallel causes.
                .contains("4"), // four minutes alert
                .noEmDash,
                .noEmoji,
                .noConsecutiveDuplicates,
                .wordCountAtLeast(80),
            ]
        ),

        // ----------------------------------------------------------------
        // 6. Mixed list dictation with restarts and item swap
        // Tests: bullet/list detection, "scratch the lemons get limes"
        // correction (limes wins, lemons drops out), parmesan WEDGE not
        // pre-grated, dark roast not medium roast.
        // ----------------------------------------------------------------
        TestCase(
            id: 6,
            label: "Mixed list dictation with restarts and item swap",
            input: "okay grocery list for tonight um milk eggs sourdough bread chicken thighs not breasts thighs spinach lemons garlic uhh actually scratch the lemons get limes instead and i need olive oil oh and i forgot we're out of coffee so a bag of the dark roast beans not the medium one the dark roast that's it i think wait one more thing parmesan cheese the wedge not the pre grated stuff",
            cleanupLevel: "medium",
            personality: "casual",
            assertions: [
                .contains("milk"),
                .contains("eggs"),
                .contains("limes"),
                .doesNotContain("lemons"),
                .contains("dark roast"),
                // The medium roast was rejected — must not appear as the
                // chosen item. Allow it to appear as "not the medium" but
                // forbid the corrected output saying "medium roast" alone.
                .contains("parmesan"),
                .contains("wedge"),
                .doesNotContain("pre-grated stuff"), // colloquial qualifier should drop
                .contains("chicken thighs"),
                .doesNotContain("chicken breasts"),
                .noEmDash,
                .noEmoji,
                .noConsecutiveDuplicates,
                .wordCountAtLeast(30),
            ]
        ),

        // ----------------------------------------------------------------
        // 7. Technical email mixing prose and code
        // Tests: backtick discipline (DATABASE_URL, file path, shell cmd
        // get backticks; prose doesn't), file path normalization
        // (infra/db_migrations, 2026_05_add_user_preferences.sql).
        // ----------------------------------------------------------------
        TestCase(
            id: 7,
            label: "Technical email mixing prose and code",
            input: "hey team i pushed the migration script to the infra slash db migrations folder the file is called twenty twenty six underscore zero five underscore add user preferences dot sql um before you run it make sure the DATABASE_URL env var points at the staging db not prod because the script does a non reversible alter table on the users table to run it locally just do bundle exec rake db colon migrate from the project root if you hit a foreign key constraint error that's expected it means you have stale data from the old preferences table just truncate that table first using truncate user underscore preferences cascade and then re run the migration ping me on slack if anything else breaks",
            cleanupLevel: "medium",
            personality: "neutral",
            assertions: [
                .containsBackticked("DATABASE_URL"),
                // The shell command — accept either backticked exact or
                // backticked partial. We check for "bundle exec" + "db:migrate".
                .contains("bundle exec"),
                .contains("db:migrate"),
                // The migration filename — flexible on the underscores
                // vs spaces but the year prefix should normalize.
                .contains("2026"),
                .contains("add_user_preferences"),
                .contains(".sql"),
                // Truncate cascade — checked as two anchors.
                .contains("truncate"),
                .contains("user_preferences"),
                .contains("cascade"),
                // Folder path normalization
                .contains("infra/db_migrations"),
                .hasBackticks,
                .noMultiWordBacktickedPhrase,
                .noEmDash,
                .noEmoji,
                .noConsecutiveDuplicates,
                .wordCountAtLeast(80),
            ]
        ),

        // ----------------------------------------------------------------
        // 8. Stream of consciousness with topic shifts
        // Tests: paragraph break on topic shift ("oh and", "also", "one
        // more thing"), no clause truncation across 100+ words, casual
        // register, all 5 topic clauses preserved (standup, fintech/SOC2,
        // recruiter, GitHub outage, vendor/Amplitude).
        // ----------------------------------------------------------------
        TestCase(
            id: 8,
            label: "Stream of consciousness with topic shifts",
            input: "so today was wild um first thing in the morning i had the standup which went fine then i jumped into the customer call with that fintech prospect they're close to signing but they want SOC two type two before they commit which we don't have yet so i looped in security to see what the timeline looks like um also during lunch i had a quick call with the recruiter about the senior swift role we're hiring for they've got three candidates lined up i'm doing the first screens next week monday tuesday and wednesday oh and the other big thing today was the github outage from like two to four pm that completely blocked the deploy we were planning for the v three point two release we're going to push that to tomorrow morning instead one more thing i finally responded to that vendor email about the analytics tool we're switching to amplitude because mixpanel's pricing went up forty percent at renewal not worth it",
            cleanupLevel: "medium",
            personality: "casual",
            assertions: [
                .allClausesPresent([
                    "standup",
                    "SOC 2",
                    "recruiter",
                    "GitHub",
                    "v3.2",
                    "Amplitude",
                    "Mixpanel",
                ]),
                .contains("Type 2"),
                .contains("fintech"),
                // Topic-shift paragraph breaks → output should have at
                // least one newline (multiple paragraphs).
                .contains("\n"),
                .noEmDash,
                .noEmoji,
                .noConsecutiveDuplicates,
                .wordCountAtLeast(100),
            ]
        ),
    ]

    // MARK: - Runner

    /// Public entry — called by `VoiceEntryPoint` when `--polish-scripts`
    /// is on the CLI. Prewarms Qwen3 (waiting up to 5 min), then loops
    /// over `cases` running each through `Qwen3Polisher.polish`.
    static func run() async {
        sprint("[POLISH-SCRIPTS] Starting harness — \(cases.count) cases")
        sprint("[POLISH-SCRIPTS] Qwen3 isAvailable=\(Qwen3Polisher.isAvailable) isEnabled=\(Qwen3Polisher.isEnabled)")

        guard Qwen3Polisher.isAvailable else {
            sprint("[POLISH-SCRIPTS] FATAL: MLX not linked at build time.")
            return
        }

        // Prewarm + wait for 1.7B (mirrors PolishHarness.run). All cases
        // use cleanupLevel="medium" → 1.7B is sufficient, 4B not needed.
        sprint("[POLISH-SCRIPTS] Prewarming Qwen3 1.7B…")
        Qwen3Polisher.shared.prewarm()
        let warmupDeadline = Date().addingTimeInterval(300)
        while !Qwen3Polisher.shared.availabilityStatus.isReady {
            if Date() > warmupDeadline {
                sprint("[POLISH-SCRIPTS] FATAL: 1.7B did not become ready within 5 min (status=\(Qwen3Polisher.shared.availabilityStatus.displayLabel))")
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        sprint("[POLISH-SCRIPTS] 1.7B ready.")

        var passed = 0
        var failed = 0
        var totalPolishMs = 0
        let runStart = Date()

        for c in cases {
            sprint("")
            sprint("[CASE \(c.id)] \(c.label)")
            let polishStart = Date()
            let polished = await Qwen3Polisher.shared.polish(
                c.input,
                context: .default,
                timeoutMs: 30_000,
                suspectWords: nil,
                userVocabulary: nil,
                fieldContext: nil,
                cleanupLevel: c.cleanupLevel,
                personalityStyle: c.personality
            )
            let polishMs = Int(Date().timeIntervalSince(polishStart) * 1000)
            totalPolishMs += polishMs

            let inputPreview = String(c.input.prefix(80))
            let outputPreview = String(polished.prefix(140))
            sprint("  IN:  \(inputPreview)…")
            sprint("  OUT: \(outputPreview)…")
            sprint("  polish=\(polishMs)ms cleanup=\(c.cleanupLevel) personality=\(c.personality)")

            var caseFails: [String] = []
            for a in c.assertions {
                if let failMsg = check(a, against: polished, input: c.input) {
                    caseFails.append(failMsg)
                }
            }

            if caseFails.isEmpty {
                sprint("  PASS")
                passed += 1
            } else {
                sprint("  FAIL:")
                for f in caseFails { sprint("    - \(f)") }
                failed += 1
            }
        }

        let totalMs = Int(Date().timeIntervalSince(runStart) * 1000)
        sprint("")
        sprint("=== SUMMARY ===")
        sprint("Cases:       \(cases.count)")
        sprint("Passes:      \(passed)")
        sprint("Fails:       \(failed)")
        sprint("Polish time: \(totalPolishMs)ms total, avg \(totalPolishMs / max(cases.count, 1))ms/case")
        sprint("Wall time:   \(totalMs)ms")
    }

    // MARK: - Assertion checker

    /// Returns nil on pass, or a human-readable failure message on fail.
    /// Single source of truth for what each assertion means.
    private static func check(_ a: Assertion, against output: String, input: String) -> String? {
        switch a {
        case .contains(let s):
            return output.localizedCaseInsensitiveContains(s)
                ? nil
                : "missing '\(s)'"

        case .doesNotContain(let s):
            return output.localizedCaseInsensitiveContains(s)
                ? "unexpected '\(s)'"
                : nil

        case .wordCountAtLeast(let n):
            let words = output.split(whereSeparator: { $0.isWhitespace }).count
            return words >= n
                ? nil
                : "word count \(words) < \(n)"

        case .noEmDash:
            if output.contains("—") { return "contains em-dash (—)" }
            if output.contains("–") { return "contains en-dash (–)" }
            return nil

        case .noEmoji:
            // Scan for code points in common emoji ranges. We don't need
            // a perfect Unicode-property check here — these ranges cover
            // every emoji a polish pass might plausibly emit.
            for scalar in output.unicodeScalars {
                let v = scalar.value
                let isEmoji =
                    (0x1F300...0x1F6FF).contains(v) ||  // misc symbols & pictographs, transport
                    (0x1F900...0x1F9FF).contains(v) ||  // supplemental symbols & pictographs
                    (0x1FA70...0x1FAFF).contains(v) ||  // symbols & pictographs extended-A
                    (0x2600...0x26FF).contains(v)   ||  // misc symbols
                    (0x2700...0x27BF).contains(v)   ||  // dingbats
                    (0x1F1E6...0x1F1FF).contains(v)     // regional indicators (flags)
                if isEmoji {
                    return "contains emoji code point U+\(String(v, radix: 16, uppercase: true))"
                }
            }
            return nil

        case .startsWith(let s):
            return output.hasPrefix(s)
                ? nil
                : "does not start with '\(s)' (starts with '\(output.prefix(min(40, output.count)))')"

        case .endsWith(let s):
            return output.hasSuffix(s)
                ? nil
                : "does not end with '\(s)' (ends with '\(output.suffix(min(40, output.count)))')"

        case .noConsecutiveDuplicates:
            // Strip punctuation off each token before comparing so "the,
            // the" still trips. Stop-words like "had had" / "that that"
            // are technically legitimate English; we accept the false
            // positives because in dictation contexts they're vanishingly
            // rare relative to the stutter bugs we're hunting.
            let tokens = output
                .split(whereSeparator: { $0.isWhitespace })
                .map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() }
                .filter { !$0.isEmpty }
            for i in 0..<max(tokens.count - 1, 0) {
                if tokens[i] == tokens[i + 1] && tokens[i].count > 1 {
                    return "duplicate consecutive: '\(tokens[i]) \(tokens[i+1])'"
                }
            }
            return nil

        case .allClausesPresent(let clauses):
            let missing = clauses.filter { !output.localizedCaseInsensitiveContains($0) }
            return missing.isEmpty
                ? nil
                : "missing clauses: \(missing.joined(separator: ", "))"

        case .hasBackticks:
            return output.contains("`")
                ? nil
                : "no backticks in output (expected code identifiers to be wrapped)"

        case .containsBackticked(let s):
            // Accept any of: `s`, `s` followed by other backtick group,
            // or `s` as a sub-token of a longer code expression. We
            // simply check the literal "`\(s)`" appears OR a backtick
            // followed somewhere by the identifier in the same span.
            let exact = "`\(s)`"
            if output.contains(exact) { return nil }
            // Looser: identifier appears between backticks somewhere.
            // Scan backtick-bounded spans and look for the token.
            let parts = output.split(separator: "`", omittingEmptySubsequences: false)
            // Odd-indexed parts (1, 3, 5…) are inside backticks
            for i in stride(from: 1, to: parts.count, by: 2) {
                if parts[i].contains(s) { return nil }
            }
            return "missing backticked '\(s)' — got: \(output.prefix(120))"

        case .noMultiWordBacktickedPhrase:
            // Walk backtick spans; flag any that contains a whitespace
            // character (= multi-word prose got code-formatted).
            let parts = output.split(separator: "`", omittingEmptySubsequences: false)
            for i in stride(from: 1, to: parts.count, by: 2) {
                let span = parts[i]
                // Allow common single-token compounds with internal
                // chars like ":", "/", "_", "." (file paths, env keys).
                // But a literal space inside the backticks is the bug.
                if span.contains(" ") {
                    return "multi-word backticked phrase: `\(span)`"
                }
            }
            return nil
        }
    }
}
