// VOICE — stop-word detection tests
// ============================================================
// Verifies fuzzy trailing stop-word detection in
// RecordingCoordinator. The speech recognizer rarely transcribes
// the configured stop word ("finito") exactly, so matching must
// tolerate casing, 1-edit typos, and split tokens ("fin neato"),
// while a mid-utterance mention must NOT trigger.
// ============================================================

import Testing
import Foundation
@testable import Voice

@Suite("RecordingCoordinator — fuzzy stop-word detection")
struct StopWordDetectionTests {

    // endsWithStopWord takes the stop word as a parameter and does not read
    // UserDefaults, so these cases are deterministic.

    @Test("exact lowercase finito triggers")
    func exactFinito() {
        #expect(RecordingCoordinator.endsWithStopWord("hello there finito", stopWord: "finito"))
    }

    @Test("capitalized Finito triggers")
    func capitalizedFinito() {
        #expect(RecordingCoordinator.endsWithStopWord("hello there Finito", stopWord: "finito"))
    }

    @Test("ASR variant finita triggers (1-edit)")
    func variantFinita() {
        #expect(RecordingCoordinator.endsWithStopWord("all done finita.", stopWord: "finito"))
    }

    @Test("split variant 'fin neato' triggers via two-token join")
    func variantFinNeato() {
        #expect(RecordingCoordinator.endsWithStopWord("wrap it up fin neato", stopWord: "finito"))
    }

    @Test("trailing punctuation/whitespace is ignored")
    func trailingPunctuation() {
        #expect(RecordingCoordinator.endsWithStopWord("that's it, finito!  ", stopWord: "finito"))
    }

    @Test("mid-utterance finito does NOT trigger")
    func midUtteranceDoesNotTrigger() {
        #expect(!RecordingCoordinator.endsWithStopWord(
            "the word finito means finished in Italian", stopWord: "finito"))
    }

    @Test("unrelated trailing word does NOT trigger")
    func unrelatedTrailingWord() {
        #expect(!RecordingCoordinator.endsWithStopWord("let's keep going please", stopWord: "finito"))
    }

    @Test("custom stop word with 1-edit typo triggers")
    func customStopWordTypo() {
        // "donezo" (len 6, tolerance 2) vs spoken "donezzo" — 1 edit.
        #expect(RecordingCoordinator.endsWithStopWord("okay we are donezzo", stopWord: "donezo"))
    }

    @Test("custom short stop word rejects 2-edit drift")
    func customShortStopWordTooFar() {
        // "stop" (len 4, tolerance 1) vs "steep" — 2 edits, should reject.
        #expect(!RecordingCoordinator.endsWithStopWord("walk down the steep", stopWord: "stop"))
    }
}

@Suite("RecordingCoordinator — stripping trailing stop word")
struct StopWordStrippingTests {

    // strippingTrailingStopWord reads UserDefaults for the configured stop
    // word; set deterministic values per test.
    private func withStopWord(_ word: String, _ body: () -> Void) {
        let d = UserDefaults.standard
        let prevWord = d.string(forKey: "voice.stopWord")
        let prevEnabled = d.object(forKey: "voice.stopWordEnabled")
        d.set(true, forKey: "voice.stopWordEnabled")
        d.set(word, forKey: "voice.stopWord")
        body()
        if let prevWord { d.set(prevWord, forKey: "voice.stopWord") } else { d.removeObject(forKey: "voice.stopWord") }
        if let prevEnabled { d.set(prevEnabled, forKey: "voice.stopWordEnabled") } else { d.removeObject(forKey: "voice.stopWordEnabled") }
    }

    @Test("strips exact finito")
    func stripsExact() {
        withStopWord("finito") {
            #expect(RecordingCoordinator.strippingTrailingStopWord(from: "this is the message finito")
                == "this is the message")
        }
    }

    @Test("strips capitalized variant and trailing punctuation")
    func stripsVariant() {
        withStopWord("finito") {
            #expect(RecordingCoordinator.strippingTrailingStopWord(from: "all wrapped up Finita.")
                == "all wrapped up")
        }
    }

    @Test("strips split 'fin neato' variant")
    func stripsSplitVariant() {
        withStopWord("finito") {
            #expect(RecordingCoordinator.strippingTrailingStopWord(from: "send the email fin neato")
                == "send the email")
        }
    }

    @Test("leaves mid-utterance mention intact")
    func leavesMidUtterance() {
        withStopWord("finito") {
            let input = "the word finito means finished"
            #expect(RecordingCoordinator.strippingTrailingStopWord(from: input) == input)
        }
    }

    @Test("strips custom stop word with typo")
    func stripsCustomTypo() {
        withStopWord("donezo") {
            #expect(RecordingCoordinator.strippingTrailingStopWord(from: "ship it donezzo")
                == "ship it")
        }
    }
}
