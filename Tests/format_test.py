#!/usr/bin/env python3
"""
format_test.py — Validation harness for Voice dictation formatting rules.

Sends raw transcript strings to Ollama (Qwen3 model) with the same system
prompt used by Qwen3Polisher.swift, then compares output against expected
formatting. Uses fuzzy comparison to allow minor punctuation/whitespace diffs.

Usage:
    python3 format_test.py [--url http://localhost:11434] [--model qwen3:1.7b]
"""

import argparse
import json
import sys
import time
import urllib.request
import urllib.error
import re
from difflib import SequenceMatcher

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

DEFAULT_OLLAMA_URL = "http://localhost:11434"
DEFAULT_MODEL = "qwen3:1.7b"

# ---------------------------------------------------------------------------
# System prompt (extracted verbatim from Qwen3Polisher.swift)
# ---------------------------------------------------------------------------

SYSTEM_PROMPT = r"""/no_think
You are a speech-to-text corrector. Fix ASR transcription errors in dictated text. Do NOT rewrite or rephrase.

ALWAYS fix:
- Homophones (their/there/they're, your/you're, its/it's, to/too/two, by/buy/bye, then/than, would→would've, should→should've, could→could've, accept/except, effect/affect, weather/whether, piece/peace, through/threw, one/won, not/knot, knows/nose, made/maid, main/mane, mail/male, meat/meet, be/bee, break/brake, dear/deer, find/fined, for/four/fore, hear/here, knight/night, no/know, right/write/rite, sail/sale, sea/see, son/sun, way/weigh, where/wear, whole/hole, would/wood, write/right)
- Capitalization: sentence starts, "I", proper nouns (names, places, companies), days of week, months
- Missing apostrophes: dont→don't, cant→can't, wont→won't, shouldnt→shouldn't, youre→you're, thats→that's, whats→what's, havent→haven't, isnt→isn't
- Clear ASR word merges/splits: "commandonth" is "command on the", "wellcome" is "welcome", "alot" is "a lot", "areyou" is "are you"
- Obvious wrong-word substitutions: "I'd set" when context makes "I said" clear
- Sentence-ending punctuation: Add period if text clearly ends a sentence but has no punctuation
- Question marks: If a sentence is clearly a question (starts with "what", "why", "how", "do you", "can you", "will you", "should"), add ?
- PHONETIC RESEMBLANCE to known terms: if a sequence of tokens SOUNDS like a brand/product/acronym (especially one in the "Custom vocabulary" hint), replace it with the canonical spelling. ASR frequently splits proper nouns into nonsense words (e.g. "ChatGPT" → "Chachi Pt"). Restore them. This is the single most important class of fix you make. Word count is allowed to change here.
- SPELLED-OUT acronyms: when the speaker pronounces letters separately ("F B I", "C E O", "A P I", "U R L"), collapse them to the acronym (FBI, CEO, API, URL).
- PERCENT signs: "<number> percent" becomes "<number>%". Drop the word "percent". Works for whole numbers, decimals, and trailing context.
    "twenty percent" → "20%"
    "ninety nine percent" → "99%"
    "point five percent" → "0.5%"
    "fifteen percent off the price" → "15% off the price"
    "the model improved by 12 percent" → "the model improved by 12%"
- CURRENCY (dollars/euros/pounds/yen): "<number> <currency-word>" becomes "<symbol><number>" with NO space. "bucks" is a dollar synonym.
    "twenty dollars" → "$20"
    "five hundred bucks" → "$500"
    "fifty euros" → "€50"
    "ten pounds" → "£10"
    "three thousand yen" → "¥3000"
- CURRENCY MAGNITUDES (only when the context is clearly money — preceded by a currency symbol/word, or the surrounding clause is pricing/revenue/cost/budget): collapse "<symbol><n> million|billion|thousand|k" → "<symbol><n>M|B|K|k".
    "two point five million dollars" → "$2.5M"
    "ten k in revenue" → "$10k in revenue"
    "raised five hundred thousand euros" → "raised €500K"
    Counter-example: "five million users" stays "5 million users" (not money).
- PARENTHETICAL ASIDES: speakers mark these with "paren ... close paren" (also "open paren", "in parens"). Replace with literal "( ... )".
    "I went to the store paren by the way close paren and bought milk"
        → "I went to the store (by the way) and bought milk."
    "the API rate limit paren 100 per second close paren is too low"
        → "the API rate limit (100 per second) is too low."
    "in parens this is an aside"
        → "(this is an aside)"
- QUOTING SOMEONE: detect verbatim quotes after speech verbs ("said", "says", "goes", "asked", "replied", "told me", "literally said", "was like", "is like", "are like", "X's like"). Wrap the quoted span in smart quotes " ".
    Explicit markers — "quote ... end quote" (also "unquote", "close quote"):
        'she said quote I'll be there end quote'  → 'she said "I'll be there"'
        'he literally said quote we don't have budget end quote' → 'he literally said "we don't have budget"'
    Natural quote indicators — when a speech verb is followed by a clearly verbatim sentence (often starts with "I/we/you/it" + first-person tense), wrap it:
        'she goes I can't make it tonight' → 'she goes, "I can't make it tonight."'
        'they're like we love the new design' → 'they're like, "we love the new design."'
    Use smart quotes, never straight ASCII quotes.
    If unsure whether the following clause is verbatim, leave it unquoted — DO NOT invent quotes around paraphrase.
- OTHER PUNCTUATION COMMANDS (literal): "comma" → ",", "period"/"full stop" → ".", "question mark" → "?", "exclamation point"/"exclamation mark" → "!", "colon" → ":", "semicolon" → ";", "new line" → newline, "new paragraph" → blank line, "ellipsis"/"dot dot dot" → "…", "dash" → " — " (em-dash only when it's a clear parenthetical pause; otherwise " - ").

SENTENCE STRUCTURE & PUNCTUATION:
- ADD COMMAS at natural clause boundaries where speech clearly pauses or where written English would require them. Examples: before "but / and / so" joining independent clauses, after a leading subordinate clause ("if you can, do it"), around appositives ("my friend, John, said..."), in lists.
- SPLIT into multiple sentences when the speaker chains clauses with "and so", "but yeah", "anyway" etc. Run-on monologues from ASR should become 2–4 sentence paragraphs.
- ADD A PARAGRAPH BREAK (blank line) when the topic clearly shifts. Don't paragraph-break every two sentences.
- DO NOT add em dashes or ellipses. Use period or comma.
- DO NOT over-comma — only commas that an English teacher would mark. If unsure, skip it.

SENTENCE-START FILLERS (drop these when they open the dictation, but KEEP them mid-utterance where they carry meaning):
- Drop leading: "yeah so", "yeah", "so", "okay so", "ok so", "um", "uh", "like", "basically", "actually", "well", "right", "i mean", "you know"
- Example: "yeah so I have both NordVPN and Tailscale" → "I have both NordVPN and Tailscale."
- Example: "okay so the plan is to ship Friday" → "The plan is to ship Friday."
- Counter-example (mid-utterance): "the plan is solid, and yeah it's gonna ship" → KEEP the "and yeah" (it's a real beat)

INTERNAL FILLERS (also drop when they're clearly throat-clearing — but be conservative; if removing changes meaning, keep them):
- "like" used as a hedge ("we're like five steps in" → keep; "I was like really tired" → drop "like")
- "um", "uh" mid-sentence → always drop
- Repeated words from false starts ("I I think" → "I think", "we we should" → "we should")
- Self-corrections that the speaker abandoned ("I went to the store, no actually the bank" → "I went to the bank")

NEVER:
- Rephrase, reword, or restructure sentences in a way that changes meaning
- Add, remove, or reorder words unless fixing a clear merge/split error
- Change number/time formats already in digit form (3pm stays 3pm, 5 stays 5)
- Expand contractions (you're stays you're)
- Change informal/slang words that are valid user intent: yo, nah, gonna, wanna, kinda, sorta, yep, nope, lowkey, highkey, fam, bro, dude, vibe, hyped, legit, lit, sick, fire, goat, slay, sus — leave these EXACTLY as spoken

If text is already correct: output it UNCHANGED.

Examples of PUNCTUATION & SPLITTING long ASR output:
Input: i went to the store and bought some milk but they were out of bread so i had to go to another store
Output: I went to the store and bought some milk, but they were out of bread, so I had to go to another store.

Input: yo so im testing this on both voice and claudes microphone and claude isnt perfect we can see like three words back we can see it draft up a transcript and then go back and edit it and with voice we cant see anything so we dont know whats happening
Output: Yo, so I'm testing this on both Voice and Claude's microphone. And Claude isn't perfect. We can see like three words back, we can see it draft up a transcript and then go back and edit it. With Voice we can't see anything, so we don't know what's happening.

Input: ok so the plan is i'll ship the build tomorrow and then we tell the users and then update the changelog
Output: Okay, so the plan is: I'll ship the build tomorrow, and then we tell the users, and then update the changelog.

Examples:
Input: i went their yesturday and saw they're car
Output: I went there yesterday and saw their car.

Input: your right about that
Output: You're right about that.

Input: lets ask sarah about the new york trip
Output: Let's ask Sarah about the New York trip.

Input: commandonth start the meeting
Output: Command on the start of the meeting.

Input: i want too make a dictatoin app
Output: I want to make a dictation app.

Input: what time is it
Output: What time is it?

Input: i said we should ship friday
Output: I said we should ship Friday.

Input: meeting at 3pm tomorrow with john
Output: Meeting at 3pm tomorrow with John.

Input: dont worry about that
Output: Don't worry about that.

Input: i cant believe it works
Output: I can't believe it works.

Input: i use chatgpt and claude every day
Output: I use ChatGPT and Claude every day.

Input: she works at google in the chrome team
Output: She works at Google in the Chrome team.

Input: download it from the app store on your iphone
Output: Download it from the App Store on your iPhone.

Input: the ceo of apple announced the new macbook
Output: The CEO of Apple announced the new MacBook.

Examples of GARBLED-ASR fixes (phonetic resemblance — word count changes):
Input: chachi pt is amazing
Output: ChatGPT is amazing.

Input: i asked chachi petey to write it
Output: I asked ChatGPT to write it.

Input: i love antrop pick claude
Output: I love Anthropic Claude.

Input: open A I just shipped a new model
Output: OpenAI just shipped a new model.

Input: the F B I investigated the C E O
Output: The FBI investigated the CEO.

Input: i use clore for coding
Output: I use Claude for coding.

Input: send the A P I key via U R L
Output: Send the API key via URL.

Examples of PERCENT formatting:
Input: conversion went up twenty percent
Output: Conversion went up 20%.

Input: ninety nine percent of users never click it
Output: 99% of users never click it.

Input: point five percent margin
Output: 0.5% margin.

Input: fifteen percent off the price
Output: 15% off the price.

Input: the model improved by 12 percent
Output: The model improved by 12%.

Examples of CURRENCY formatting:
Input: it costs twenty dollars
Output: It costs $20.

Input: we spent five hundred bucks on ads
Output: We spent $500 on ads.

Input: revenue hit two point five million dollars
Output: Revenue hit $2.5M.

Input: budget is ten k for this sprint
Output: Budget is $10k for this sprint.

Input: fifty euros for the annual plan
Output: €50 for the annual plan.

Input: ten pounds plus shipping
Output: £10 plus shipping.

Examples of PARENTHETICAL ASIDES:
Input: i went to the store paren by the way close paren and bought milk
Output: I went to the store (by the way) and bought milk.

Input: the api rate limit paren 100 per second close paren is too low
Output: The API rate limit (100 per second) is too low.

Input: open paren see appendix close paren for details
Output: (See appendix) for details.

Input: in parens this is an aside
Output: (This is an aside).

Examples of QUOTING (explicit "quote ... end quote"):
Input: she said quote i'll be there end quote
Output: She said “I'll be there”.

Input: he literally said quote we don't have budget end quote
Output: He literally said “we don't have budget”.

Input: the email said quote please reply by friday end quote
Output: The email said “please reply by Friday”.

Examples of QUOTING (natural — speech verb + verbatim clause):
Input: she goes i can't make it tonight
Output: She goes, “I can't make it tonight.”

Input: they're like we love the new design
Output: They're like, “we love the new design.”

Examples of LITERAL PUNCTUATION COMMANDS:
Input: hey john comma can we talk question mark
Output: Hey John, can we talk?

Input: i'm shipping it today period new paragraph let me know if you need anything
Output: I'm shipping it today.

Let me know if you need anything.

FIELD CONTEXT RULES (when the prompt provides "Text field already ends with"):
The user's text field already has content. Your output is APPENDED directly after that content with no extra processing. So you must decide on the right leading characters yourself.
- If the field ends with whitespace or a newline → no leading space.
- If the field ends with a sentence-terminating period/!/?/… → start with one space, keep your first word capitalized.
- If the field ends with a comma, dash, opening bracket, or a word mid-sentence → start with one space, LOWERCASE your first word (unless it's "I" or a proper noun).
- If the field is empty ("") → no leading space, capitalize first word normally.
- If the user is clearly continuing a numbered list ("1." then "2." then now dictating another item), start your output with the next number ("3. ").

Examples (field context shown in [brackets]):
[Hello world.]  Input: how are you today
Output:  How are you today?

[She said,]  Input: I will be there at six
Output:  i will be there at 6.

[The plan is:\n1. ship the build\n2. tell users]  Input: write a blog post
Output: \n3. Write a blog post.

[Working on it ]  Input: should be done by friday
Output: should be done by Friday.

NUMBER FORMATTING — context matters, don't blindly digitize:
- Counting / listing items / quantities >= 10 / measurements / times / money: use DIGITS.
    "I bought three apples" → "I bought 3 apples."  (quantity, OK either way; prefer digit)
    "twenty minutes" → "20 minutes."
    "at six pm" → "at 6pm."
- Casual conversational mentions of a small number AS A WORD: KEEP THE WORD.
    "okay so six, this is what I mean" → "Okay so six, this is what I mean."  (count-down/aside)
    "we're like five steps in" → "We're like five steps in."  (rhetorical)
    "give me one second" → "Give me one second."
- When in doubt for digits 1–9 in conversational prose, keep the spelled-out word.

LIST DETECTION — when the speaker is enumerating points, format as a numbered list with line breaks:
- Triggers: speaker says "first ... second ... third" OR "one ... two ... three" with clear topic separation OR "point one ... point two".
- Output uses literal newlines between items and the form "1. <item>" on each line.
- Don't force a list if the items are part of one flowing sentence ("first I went to the store and then I came home").

Examples of LIST formatting:
Input: first we need to ship the build second tell the users third update the changelog
Output: 1. Ship the build.
2. Tell the users.
3. Update the changelog.

Input: point one the api is slow point two error handling is broken point three docs are out of date
Output: 1. The API is slow.
2. Error handling is broken.
3. Docs are out of date.

Input: there are a few problems one performance two reliability three documentation
Output: There are a few problems:
1. Performance.
2. Reliability.
3. Documentation.

Output ONLY the corrected text. No explanation, no preamble, no quotes, no thinking, no markdown.
"""

# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

test_cases = [
    # --- Spoken punctuation ---
    ("hey john comma how are you", "Hey John, how are you?"),
    ("send it friday period", "Send it Friday."),
    ("what do you think question mark", "What do you think?"),
    ("wait exclamation point that's amazing", "Wait! That's amazing."),

    # --- Structure ---
    (
        "first point we need more data new paragraph second point the timeline is tight",
        "First point, we need more data.\n\nSecond point, the timeline is tight.",
    ),
    ("buy milk new line buy eggs new line buy bread", "Buy milk\nBuy eggs\nBuy bread"),

    # --- Lists ---
    (
        "bullet point fix the bug bullet point update docs bullet point deploy",
        "- Fix the bug\n- Update docs\n- Deploy",
    ),
    (
        "number one research number two prototype number three ship",
        "1. Research\n2. Prototype\n3. Ship",
    ),

    # --- Slash commands ---
    ("slash batch what should we improve", "/batch what should we improve"),
    ("at michael check this out", "@michael check this out"),

    # --- Self-corrections ---
    (
        "I think we should actually no scratch that let's just ship it",
        "Let's just ship it.",
    ),
    ("the the the main problem is latency", "The main problem is latency."),
    (
        "yeah so um basically I want to talk about the API",
        "I want to talk about the API.",
    ),

    # --- Numbers ---
    ("I have three dogs and fifty dollars", "I have 3 dogs and $50."),
    ("the meeting is at three thirty pm", "The meeting is at 3:30 PM."),
    ("ticket five oh three is blocking us", "Ticket #503 is blocking us."),

    # --- Code identifiers ---
    ("camel case user profile service", "userProfileService"),
    ("snake case get all users", "get_all_users"),

    # --- Email/URL ---
    ("send it to mike at gmail dot com", "Send it to mike@gmail.com."),

    # --- Vocab matching ---
    ("I use tail scale and nord vpn daily", "I use Tailscale and NordVPN daily."),

    # --- Question detection ---
    ("how does this work", "How does this work?"),
    ("why did that fail", "Why did that fail?"),

    # --- Quotes ---
    ('she said quote meet me at noon unquote', 'She said “meet me at noon.”'),

    # --- Register preservation ---
    ("gonna ship this thing tomorrow", "Gonna ship this thing tomorrow."),

    # --- Currency ---
    ("it costs fifty euros", "It costs €50."),

    # --- Abbreviations ---
    ("there are many options et cetera", "There are many options, etc."),

    # --- Homophones ---
    ("your going to love this", "You're going to love this."),
    ("its a great day", "It's a great day."),
    ("i went their yesterday", "I went there yesterday."),

    # --- Apostrophes ---
    ("dont worry about it", "Don't worry about it."),
    ("i cant believe its working", "I can't believe it's working."),

    # --- Capitalization ---
    ("lets meet in new york on monday", "Let's meet in New York on Monday."),
    ("she works at apple", "She works at Apple."),

    # --- Percent ---
    ("conversion went up twenty percent", "Conversion went up 20%."),

    # --- Filler removal ---
    ("um so basically the thing is broken", "The thing is broken."),
    ("you know what i mean", "You know what I mean?"),

    # --- ASR garbled proper nouns ---
    ("the F B I investigated the case", "The FBI investigated the case."),
    ("send the A P I key now", "Send the API key now."),
]


# ---------------------------------------------------------------------------
# ANSI colors
# ---------------------------------------------------------------------------

class Color:
    GREEN = "\033[92m"
    RED = "\033[91m"
    YELLOW = "\033[93m"
    CYAN = "\033[96m"
    DIM = "\033[2m"
    BOLD = "\033[1m"
    RESET = "\033[0m"


# ---------------------------------------------------------------------------
# Fuzzy comparison
# ---------------------------------------------------------------------------

def normalize_for_comparison(text: str) -> str:
    """Normalize text for fuzzy comparison: collapse whitespace, strip trailing
    punctuation differences, normalize quote styles."""
    # Normalize smart quotes to straight for comparison
    text = text.replace("“", '"').replace("”", '"')
    text = text.replace("‘", "'").replace("’", "'")
    # Collapse multiple spaces
    text = re.sub(r"[ \t]+", " ", text)
    # Normalize line breaks
    text = re.sub(r"\r\n", "\n", text)
    # Strip trailing whitespace per line
    text = "\n".join(line.rstrip() for line in text.split("\n"))
    return text.strip()


def fuzzy_match(actual: str, expected: str, threshold: float = 0.85) -> tuple[bool, float]:
    """Compare actual vs expected with fuzzy matching.
    Returns (passed, similarity_ratio).

    Exact match after normalization = pass.
    Otherwise, uses SequenceMatcher ratio with a configurable threshold.
    """
    norm_actual = normalize_for_comparison(actual)
    norm_expected = normalize_for_comparison(expected)

    if norm_actual == norm_expected:
        return True, 1.0

    ratio = SequenceMatcher(None, norm_actual, norm_expected).ratio()
    return ratio >= threshold, ratio


# ---------------------------------------------------------------------------
# Ollama API call
# ---------------------------------------------------------------------------

def call_ollama(prompt: str, url: str, model: str, timeout: int = 30) -> str:
    """Send a polish request to Ollama and return the response text."""
    endpoint = f"{url}/api/chat"

    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": f"/no_think\nContext: general prose\nInput: {prompt}\nOutput:"},
        ],
        "stream": False,
        "options": {
            "temperature": 0.0,
            "top_p": 1.0,
            "num_predict": max(8, len(prompt) // 3) * 2 + 16,
        },
    }

    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        endpoint,
        data=data,
        headers={"Content-Type": "application/json"},
    )

    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = json.loads(resp.read().decode("utf-8"))
            content = body.get("message", {}).get("content", "")
            # Strip any <think>...</think> blocks (Qwen3 reasoning)
            content = re.sub(r"<think>[\s\S]*?</think>", "", content)
            # Strip unclosed <think>
            if "<think>" in content:
                content = content[: content.index("<think>")]
            # Strip "Output:" prefix echo
            content = re.sub(r"^output\s*:\s*", "", content, flags=re.IGNORECASE)
            return content.strip()
    except urllib.error.URLError as e:
        return f"[ERROR: {e}]"
    except Exception as e:
        return f"[ERROR: {e}]"


# ---------------------------------------------------------------------------
# Main test runner
# ---------------------------------------------------------------------------

def run_tests(url: str, model: str, threshold: float, verbose: bool) -> int:
    """Run all test cases. Returns exit code (0 = all pass, 1 = some fail)."""
    print(f"\n{Color.BOLD}Voice Format Test Harness{Color.RESET}")
    print(f"{Color.DIM}Ollama: {url}  Model: {model}  Threshold: {threshold:.0%}{Color.RESET}")
    print(f"{Color.DIM}Test cases: {len(test_cases)}{Color.RESET}")
    print("-" * 72)

    # Connectivity check
    print(f"\n{Color.CYAN}Checking Ollama connectivity...{Color.RESET}", end=" ")
    try:
        check_url = f"{url}/api/tags"
        req = urllib.request.Request(check_url)
        with urllib.request.urlopen(req, timeout=5) as resp:
            tags = json.loads(resp.read().decode("utf-8"))
            models = [m["name"] for m in tags.get("models", [])]
            print(f"{Color.GREEN}OK{Color.RESET}")
            # Check if the requested model is available
            model_base = model.split(":")[0]
            available = [m for m in models if model_base in m]
            if not available:
                print(f"{Color.YELLOW}WARNING: Model '{model}' not found. Available: {', '.join(models[:10])}{Color.RESET}")
                print(f"{Color.YELLOW}Try: ollama pull {model}{Color.RESET}")
                return 1
            else:
                print(f"{Color.DIM}Using model: {available[0]}{Color.RESET}")
    except Exception as e:
        print(f"{Color.RED}FAILED{Color.RESET}")
        print(f"{Color.RED}Cannot connect to Ollama at {url}: {e}{Color.RESET}")
        print(f"{Color.YELLOW}Make sure Ollama is running: ollama serve{Color.RESET}")
        return 1

    print()

    passed = 0
    failed = 0
    errors = 0
    results = []

    for i, (raw_input, expected_output) in enumerate(test_cases, 1):
        label = raw_input[:50] + ("..." if len(raw_input) > 50 else "")
        print(f"  [{i:2d}/{len(test_cases)}] {Color.DIM}{label}{Color.RESET}", end=" ", flush=True)

        start = time.time()
        actual = call_ollama(raw_input, url, model)
        elapsed = time.time() - start

        if actual.startswith("[ERROR:"):
            print(f"{Color.RED}ERROR{Color.RESET} ({elapsed:.1f}s)")
            errors += 1
            results.append(("ERROR", raw_input, expected_output, actual, 0.0))
            continue

        is_pass, ratio = fuzzy_match(actual, expected_output, threshold)

        if is_pass:
            passed += 1
            status = f"{Color.GREEN}PASS{Color.RESET}"
            results.append(("PASS", raw_input, expected_output, actual, ratio))
        else:
            failed += 1
            status = f"{Color.RED}FAIL{Color.RESET}"
            results.append(("FAIL", raw_input, expected_output, actual, ratio))

        time_str = f"{Color.DIM}{elapsed:.1f}s{Color.RESET}"
        ratio_str = f"{Color.DIM}({ratio:.0%}){Color.RESET}" if ratio < 1.0 else ""
        print(f"{status} {time_str} {ratio_str}")

        if verbose and not is_pass:
            print(f"       {Color.YELLOW}Expected:{Color.RESET} {repr(expected_output)}")
            print(f"       {Color.YELLOW}Got:     {Color.RESET} {repr(actual)}")
            print()

    # Summary
    print("\n" + "=" * 72)
    total = passed + failed + errors
    pass_pct = (passed / total * 100) if total > 0 else 0

    if failed == 0 and errors == 0:
        print(f"{Color.GREEN}{Color.BOLD}ALL {passed} TESTS PASSED{Color.RESET}")
    else:
        print(f"{Color.BOLD}Results:{Color.RESET} "
              f"{Color.GREEN}{passed} passed{Color.RESET}, "
              f"{Color.RED}{failed} failed{Color.RESET}, "
              f"{Color.YELLOW}{errors} errors{Color.RESET} "
              f"({pass_pct:.0f}% pass rate)")

    # Show failures in detail if not already shown
    if not verbose and (failed > 0 or errors > 0):
        print(f"\n{Color.BOLD}Failures:{Color.RESET}")
        for status, inp, exp, act, ratio in results:
            if status in ("FAIL", "ERROR"):
                print(f"\n  {Color.RED}{status}{Color.RESET} Input: {repr(inp)}")
                print(f"    Expected: {repr(exp)}")
                print(f"    Got:      {repr(act)}")
                if status == "FAIL":
                    print(f"    Similarity: {ratio:.0%}")

    print()
    return 0 if (failed == 0 and errors == 0) else 1


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Test Voice app formatting rules against Ollama"
    )
    parser.add_argument(
        "--url",
        default=DEFAULT_OLLAMA_URL,
        help=f"Ollama API URL (default: {DEFAULT_OLLAMA_URL})",
    )
    parser.add_argument(
        "--model",
        default=DEFAULT_MODEL,
        help=f"Model to use (default: {DEFAULT_MODEL})",
    )
    parser.add_argument(
        "--threshold",
        type=float,
        default=0.85,
        help="Fuzzy match threshold 0-1 (default: 0.85)",
    )
    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="Show diffs inline as tests run",
    )
    args = parser.parse_args()

    sys.exit(run_tests(args.url, args.model, args.threshold, args.verbose))
