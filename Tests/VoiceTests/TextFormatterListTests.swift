// VOICE — TextFormatter list/paragraph tests
// ============================================================
// Verifies spoken-list detection and transitional-paragraph
// detection added to TextFormatter. Each test runs through the
// full `format()` pipeline so we catch interactions with the
// other passes (capitalization, terminal punctuation, etc.).
// ============================================================

import Testing
import Foundation
@testable import Voice

@Suite("TextFormatter — spoken list detection")
struct TextFormatterListTests {

    // Build a formatter with deterministic config — UserDefaults state on the
    // dev machine shouldn't change test outcomes.
    private func makeFormatter(bullets: Bool = false) -> TextFormatter {
        var cfg = TextFormatterConfig()
        cfg.detectLists = true
        cfg.preferBulletsForOrdinalOnly = bullets
        return TextFormatter(config: cfg)
    }

    @Test("point-N list with three items")
    func pointNList() {
        let f = makeFormatter()
        let got = f.format("point one this is a test point two another point point three last one")
        #expect(got == "1. This is a test\n2. Another point\n3. Last one.")
    }

    @Test("ordinal-only list with three items")
    func ordinalOnlyList() {
        let f = makeFormatter()
        let got = f.format("first I went to the store second I bought milk third I came home")
        #expect(got == "1. I went to the store\n2. I bought milk\n3. I came home.")
    }

    @Test("step-N list with two items")
    func stepNList() {
        let f = makeFormatter()
        let got = f.format("step one open the file step two save it")
        #expect(got == "1. Open the file\n2. Save it.")
    }

    @Test("single 'point one' in prose is NOT a list")
    func noFalsePositiveOnSingleTrigger() {
        let f = makeFormatter()
        let got = f.format("I want to point one out that this is wrong")
        // "point one" sits mid-clause (after "to "), so the boundary check
        // rejects it. No reformat.
        #expect(got == "I want to point one out that this is wrong.")
    }

    @Test("'my number one fan' is not a list")
    func noFalsePositiveNumberOneFan() {
        let f = makeFormatter()
        let got = f.format("she is my number one fan")
        #expect(got == "She is my number one fan.")
    }

    @Test("bullets mode swaps numbered for dash bullets on ordinal-only runs")
    func bulletsModeForOrdinalOnly() {
        let f = makeFormatter(bullets: true)
        let got = f.format("first I went to the store second I bought milk")
        #expect(got == "- I went to the store\n- I bought milk.")
    }

    @Test("bullets mode keeps numbered list when prefix 'point' was used")
    func bulletsModeIgnoresPrefixedRuns() {
        let f = makeFormatter(bullets: true)
        let got = f.format("point one open the file point two save it")
        #expect(got == "1. Open the file\n2. Save it.")
    }

    @Test("mixed 'number N' triggers numbered list")
    func numberNList() {
        let f = makeFormatter()
        let got = f.format("number one buy eggs number two buy milk")
        #expect(got == "1. Buy eggs\n2. Buy milk.")
    }
}

@Suite("TextFormatter — transitional paragraph breaks")
struct TextFormatterParagraphTests {

    private func makeFormatter() -> TextFormatter {
        TextFormatter(config: TextFormatterConfig())
    }

    @Test("'So,' starts a new paragraph")
    func soBreaksParagraph() {
        let f = makeFormatter()
        let got = f.format("I went to the store. So, I bought milk.")
        #expect(got == "I went to the store.\n\nSo, I bought milk.")
    }

    @Test("'Anyway,' starts a new paragraph")
    func anywayBreaksParagraph() {
        let f = makeFormatter()
        let got = f.format("That was strange. Anyway, here is the news.")
        #expect(got == "That was strange.\n\nAnyway, here is the news.")
    }

    @Test("'Moving on' starts a new paragraph")
    func movingOnBreaksParagraph() {
        let f = makeFormatter()
        let got = f.format("we will skip that one. Moving on to the next item.")
        #expect(got == "We will skip that one.\n\nMoving on to the next item.")
    }
}

@Suite("TextFormatter — segment-gap paragraph breaks")
struct TextFormatterSegmentGapTests {

    @Test("gap of 1.5s+ between segments inserts \\n\\n")
    func gapTriggersParagraphBreak() {
        let f = TextFormatter(config: TextFormatterConfig())
        let segments: [(text: String, startTime: TimeInterval, endTime: TimeInterval)] = [
            ("I went to the store.", 0.0, 1.0),
            ("Then I came home.",    2.6, 3.5),  // 1.6s gap
        ]
        let got = f.formatSegments(segments)
        #expect(got.contains("\n\n"))
    }

    @Test("gap of <1.5s between segments does NOT split paragraphs")
    func shortGapDoesNotSplit() {
        let f = TextFormatter(config: TextFormatterConfig())
        let segments: [(text: String, startTime: TimeInterval, endTime: TimeInterval)] = [
            ("I went to the store.", 0.0, 1.0),
            ("Then I came home.",    1.5, 2.4),  // 0.5s gap
        ]
        let got = f.formatSegments(segments)
        #expect(!got.contains("\n\n"))
    }
}
