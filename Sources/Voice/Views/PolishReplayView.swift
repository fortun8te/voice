// PolishReplayView.swift
// ============================================================
// In-app polish-replay test harness.
//
// Three-pane window for systematically verifying polish output against a
// battery of golden cases. Load a golden case (raw transcript + reference
// "ideal" output), click Run polish, see what the actual pipeline produces
// side-by-side with the reference.
//
// Pipeline mirrors the production path: TextFormatter.format() ->
// Qwen3Polisher.shared.polish(). Uses the real shared MLX containers so
// routing (1.7B vs 4B), warmup, and cleanup-level prompts all behave the
// same as live dictation.
//
// Golden cases ship in Resources/GoldenCases/*.json and also load from
// ~/Library/Application Support/Voice/GoldenCases/ if present (user
// overrides bundled). Loaded lazily so the view does not block app launch.
// ============================================================

import SwiftUI
import AppKit

// MARK: - Model

struct GoldenCase: Identifiable, Codable, Equatable {
    let id: String
    let title: String
    let categories: [String]
    let raw: String
    let reference: String
    let notes: String?
    let cleanupLevel: String?
    let personality: String?
    /// Optional triple-ASR snapshot embedded in a golden case (lets a case
    /// freeze "what each model said" so the replay view shows the same data
    /// every run without needing to re-record).
    let tripleASR: TripleASRCapture?

    // Explicit CodingKeys + custom decode so older cases that omit
    // `tripleASR` continue to load.
    enum CodingKeys: String, CodingKey {
        case id, title, categories, raw, reference, notes, cleanupLevel, personality, tripleASR
    }

    init(
        id: String,
        title: String,
        categories: [String],
        raw: String,
        reference: String,
        notes: String?,
        cleanupLevel: String?,
        personality: String?,
        tripleASR: TripleASRCapture? = nil
    ) {
        self.id = id
        self.title = title
        self.categories = categories
        self.raw = raw
        self.reference = reference
        self.notes = notes
        self.cleanupLevel = cleanupLevel
        self.personality = personality
        self.tripleASR = tripleASR
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.categories = try c.decodeIfPresent([String].self, forKey: .categories) ?? []
        self.raw = try c.decode(String.self, forKey: .raw)
        self.reference = try c.decode(String.self, forKey: .reference)
        self.notes = try c.decodeIfPresent(String.self, forKey: .notes)
        self.cleanupLevel = try c.decodeIfPresent(String.self, forKey: .cleanupLevel)
        self.personality = try c.decodeIfPresent(String.self, forKey: .personality)
        self.tripleASR = try c.decodeIfPresent(TripleASRCapture.self, forKey: .tripleASR)
    }
}

// MARK: - TripleASRCapture
//
// Snapshot of all three ASR transcripts (Parakeet v2, Granite 4.0, Moonshine
// Tiny) plus the merged + polished outputs from a single dictation. Persisted
// to ~/Library/Application Support/Voice/last_triple_asr.json after each live
// dictation that took the triple-model merge path, so the Polish Replay
// window can surface "what each model said" even after a restart.
//
// Read-only consumer of the merge pipeline — nothing here changes ASR routing.

struct TripleASRCapture: Codable, Equatable {
    let timestamp: Date
    let parakeet: String?         // canonical ASR; usually present
    let granite: String?          // nil = model not run (opt-in / disabled / no audio)
    let moonshine: String?        // nil = model not run
    let merged: String?           // post-merge text fed to the polisher
    let polished: String?         // final polished output pasted to cursor

    /// Aggregate confidence per model when available (0..1). Surfaces low-
    /// confidence transcripts in the UI without round-tripping to the per-
    /// token-timings array (which we drop after polish).
    let parakeetConfidence: Float?
    let graniteConfidence: Float?
    let moonshineConfidence: Float?

    /// Free-form provenance ("live dictation", golden case ID, etc.).
    let source: String?

    init(
        timestamp: Date = Date(),
        parakeet: String? = nil,
        granite: String? = nil,
        moonshine: String? = nil,
        merged: String? = nil,
        polished: String? = nil,
        parakeetConfidence: Float? = nil,
        graniteConfidence: Float? = nil,
        moonshineConfidence: Float? = nil,
        source: String? = nil
    ) {
        self.timestamp = timestamp
        self.parakeet = parakeet
        self.granite = granite
        self.moonshine = moonshine
        self.merged = merged
        self.polished = polished
        self.parakeetConfidence = parakeetConfidence
        self.graniteConfidence = graniteConfidence
        self.moonshineConfidence = moonshineConfidence
        self.source = source
    }
}

// MARK: - TripleASRStore
//
// On-disk store for the most recent triple-ASR capture. Single-file JSON;
// best-effort writes (we never fail a dictation if persistence fails). Lives
// in ~/Library/Application Support/Voice/last_triple_asr.json.

enum TripleASRStore {
    static func fileURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("Voice", isDirectory: true)
        return dir.appendingPathComponent("last_triple_asr.json")
    }

    static func load() -> TripleASRCapture? {
        let url = fileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(TripleASRCapture.self, from: data)
        } catch {
            print("[POLISH-REPLAY] last_triple_asr.json decode failed: \(error)")
            return nil
        }
    }

    /// Best-effort save — logged-and-swallowed on failure so a write error in
    /// the dictation hot path never bubbles up.
    static func save(_ capture: TripleASRCapture) {
        let url = fileURL()
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(capture)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[POLISH-REPLAY] last_triple_asr.json save failed: \(error)")
        }
    }
}

private enum CleanupOption: String, CaseIterable, Identifiable {
    case light, medium, high
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

private enum PersonalityOption: String, CaseIterable, Identifiable {
    case neutral, formal, casual, excited
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

// MARK: - Loader

enum GoldenCaseLoader {
    /// Loads cases from the bundled Resources/GoldenCases folder, then merges
    /// in any user-saved cases from Application Support (user overrides
    /// bundled when ids collide).
    static func loadAll() -> [GoldenCase] {
        var byId: [String: GoldenCase] = [:]
        for c in loadBundled() { byId[c.id] = c }
        for c in loadUser() { byId[c.id] = c }
        // Sort by id for stable order (matches the lexical "01-..." prefix).
        return byId.values.sorted { $0.id < $1.id }
    }

    private static func loadBundled() -> [GoldenCase] {
        guard let url = Bundle.main.url(forResource: "GoldenCases", withExtension: nil) else {
            return []
        }
        return loadFromDirectory(url)
    }

    static func userDirectory() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("Voice/GoldenCases", isDirectory: true)
    }

    private static func loadUser() -> [GoldenCase] {
        let dir = userDirectory()
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        return loadFromDirectory(dir)
    }

    private static func loadFromDirectory(_ dir: URL) -> [GoldenCase] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return [] }
        var out: [GoldenCase] = []
        for url in items where url.pathExtension.lowercased() == "json" {
            do {
                let data = try Data(contentsOf: url)
                let c = try JSONDecoder().decode(GoldenCase.self, from: data)
                out.append(c)
            } catch {
                print("[POLISH-REPLAY] failed to decode \(url.lastPathComponent): \(error)")
            }
        }
        return out
    }

    /// Save a case to ~/Library/Application Support/Voice/GoldenCases/<id>.json.
    static func saveUser(_ c: GoldenCase) throws {
        let dir = userDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(c.id).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(c)
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - Routing prediction (mirrors Qwen3Polisher.polishWithMLX)

enum PolishRouter {
    /// Re-implements the routing predicate from Qwen3Polisher.polishWithMLX
    /// so the UI can display the predicted route BEFORE the polish runs and
    /// independently of log scraping. Kept in lockstep with the production
    /// rule; if that rule changes upstream, update this.
    static func predictedRoute(for text: String, cleanupLevel: String, forceLarge: Bool) -> String {
        if forceLarge { return "4B (forced)" }
        let cleaned = text
        let wordCount = cleaned.split(separator: " ").count
        let lowerInput = cleaned.lowercased()
        let topicShiftMarkers = ["also", "and then", "oh and", "then go", "and message",
                                  "next thing", "next up", "and finally", "and also"]
        let topicShiftHits = topicShiftMarkers.reduce(0) { acc, marker in
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: marker) + "\\b"
            guard let rx = try? NSRegularExpression(pattern: pattern) else { return acc }
            return acc + rx.numberOfMatches(in: lowerInput, range: NSRange(lowerInput.startIndex..., in: lowerInput))
        }
        let isMultiTopic = topicShiftHits >= 3
        let schemaPattern = #"(?i)\b(?:make|create|build|define)\s+(?:a\s+|an\s+)?(?:new\s+)?(?:table|schema|struct|object|model|class|record|type|interface)\b"#
        let hasSchemaSignal = cleaned.range(of: schemaPattern, options: .regularExpression) != nil
        let isLongHigh = (cleanupLevel.lowercased() == "high") && wordCount > 40
        let needsLarge = wordCount > 12
            || cleaned.contains("\n\n")
            || cleaned.contains("\n- ")
            || cleaned.contains("`")
            || cleaned.contains("\"")
            || isMultiTopic
            || hasSchemaSignal
            || isLongHigh
        return needsLarge ? "4B" : "1.7B"
    }

    static func detection(for text: String) -> (multiTopic: Bool, schema: Bool) {
        let lowerInput = text.lowercased()
        let topicShiftMarkers = ["also", "and then", "oh and", "then go", "and message",
                                  "next thing", "next up", "and finally", "and also"]
        let topicShiftHits = topicShiftMarkers.reduce(0) { acc, marker in
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: marker) + "\\b"
            guard let rx = try? NSRegularExpression(pattern: pattern) else { return acc }
            return acc + rx.numberOfMatches(in: lowerInput, range: NSRange(lowerInput.startIndex..., in: lowerInput))
        }
        let isMultiTopic = topicShiftHits >= 3
        let schemaPattern = #"(?i)\b(?:make|create|build|define)\s+(?:a\s+|an\s+)?(?:new\s+)?(?:table|schema|struct|object|model|class|record|type|interface)\b"#
        let hasSchemaSignal = text.range(of: schemaPattern, options: .regularExpression) != nil
        return (isMultiTopic, hasSchemaSignal)
    }
}

// MARK: - Similarity (Jaro-Winkler-ish + token overlap)

enum Similarity {
    /// Returns 0..1 score. Average of normalized Levenshtein distance and
    /// token-set Jaccard. Robust to whitespace/casing differences which we
    /// do NOT want to penalize for polish quality.
    static func score(_ a: String, _ b: String) -> Double {
        let na = normalize(a)
        let nb = normalize(b)
        if na.isEmpty && nb.isEmpty { return 1.0 }
        let lev = levenshtein(na, nb)
        let maxLen = max(na.count, nb.count)
        let charSim = maxLen == 0 ? 1.0 : 1.0 - Double(lev) / Double(maxLen)

        let ta = Set(na.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        let tb = Set(nb.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        let inter = ta.intersection(tb).count
        let union = ta.union(tb).count
        let tokenSim = union == 0 ? 1.0 : Double(inter) / Double(union)

        return max(0, min(1, (charSim + tokenSim) / 2))
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let s = Array(a)
        let t = Array(b)
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }
        var prev = Array(0...t.count)
        var curr = Array(repeating: 0, count: t.count + 1)
        for i in 1...s.count {
            curr[0] = i
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                curr[j] = Swift.min(
                    Swift.min(curr[j - 1] + 1, prev[j] + 1),
                    prev[j - 1] + cost
                )
            }
            swap(&prev, &curr)
        }
        return prev[t.count]
    }
}

// MARK: - View

struct PolishReplayView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var cases: [GoldenCase] = []
    @State private var selectedCaseID: String? = nil

    @State private var rawText: String = ""
    @State private var polishedText: String = ""
    @State private var referenceText: String = ""

    @State private var cleanupLevel: CleanupOption = .high
    @State private var personality: PersonalityOption = .neutral
    @State private var forceLarge: Bool = false

    @State private var isRunning: Bool = false
    @State private var elapsedMs: Int = 0
    @State private var actualRoute: String = "—"
    @State private var detectedMultiTopic: Bool = false
    @State private var detectedSchema: Bool = false
    @State private var similarity: Double? = nil

    @State private var batchOutput: String = ""
    @State private var showBatchSheet: Bool = false
    @State private var showSaveSheet: Bool = false
    @State private var saveID: String = ""
    @State private var saveTitle: String = ""

    // Triple-ASR panel state — most-recent capture from disk OR from the
    // golden case currently selected, refreshed when the window appears,
    // when a case loads, and on a NotificationCenter ping from the live
    // dictation path (see `.tripleASRCaptured` in VoiceApp).
    @State private var tripleASR: TripleASRCapture? = nil

    @State private var caseSearch: String = ""
    @State private var caseResults: [String: Double] = [:]
    @State private var showTripleASRSection: Bool = false

    private var filteredCases: [GoldenCase] {
        guard !caseSearch.isEmpty else { return cases }
        let q = caseSearch.lowercased()
        return cases.filter {
            $0.id.lowercased().contains(q) ||
            $0.title.lowercased().contains(q) ||
            $0.categories.joined(separator: " ").lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            VStack(spacing: 0) {
                header
                Divider()
                controlsBar
                Divider()
                mainPanes
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .onAppear {
            cases = GoldenCaseLoader.loadAll()
            if selectedCaseID == nil, let first = cases.first {
                load(case: first)
            }
            refreshTripleASR()
        }
        .onReceive(NotificationCenter.default.publisher(for: .tripleASRCaptured)) { _ in
            refreshTripleASR()
        }
        .sheet(isPresented: $showBatchSheet) {
            batchResultsSheet
        }
        .sheet(isPresented: $showSaveSheet) {
            saveCaseSheet
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                TextField("Filter cases", text: $caseSearch)
                    .textFieldStyle(.plain)
                    .font(.callout)
                if !caseSearch.isEmpty {
                    Button { caseSearch = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.gray.opacity(0.08))

            Divider()

            List(selection: Binding(
                get: { selectedCaseID },
                set: { newID in
                    if let id = newID, let c = cases.first(where: { $0.id == id }) {
                        load(case: c)
                    }
                }
            )) {
                ForEach(filteredCases) { c in
                    caseRow(c)
                        .tag(c.id)
                }
            }
            .listStyle(.sidebar)

            Divider()
            sidebarFooter
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
    }

    private func caseRow(_ c: GoldenCase) -> some View {
        let score = caseResults[c.id]
        return HStack(spacing: 8) {
            statusDot(for: score)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.id)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(c.title)
                    .font(.callout)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if let s = score {
                Text(String(format: "%.0f", s * 100))
                    .font(.caption.monospaced())
                    .foregroundStyle(similarityTint(s))
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusDot(for score: Double?) -> some View {
        Circle()
            .fill(score.map(similarityTint) ?? Color.gray.opacity(0.35))
            .frame(width: 8, height: 8)
    }

    private var sidebarFooter: some View {
        let pass = caseResults.values.filter { $0 >= 0.80 }.count
        let run = caseResults.count
        return HStack {
            Text("\(cases.count) cases")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if run > 0 {
                Text("\(pass)/\(run) passing")
                    .font(.caption.monospaced())
                    .foregroundStyle(pass == run ? .green : .secondary)
            }
        }
    }

    private var mainPanes: some View {
        GeometryReader { geo in
            let isWide = geo.size.width >= 1080
            ScrollView {
                if isWide {
                    HStack(alignment: .top, spacing: 0) {
                        pane(title: "Raw input", editable: true)
                            .frame(minHeight: 260)
                        Divider()
                        pane(title: "Polished output", editable: false)
                            .frame(minHeight: 260)
                        Divider()
                        pane(title: "Reference", editable: false)
                            .frame(minHeight: 260)
                    }
                    .frame(height: max(280, geo.size.height - (showTripleASRSection ? 240 : 0)))
                } else {
                    VStack(spacing: 0) {
                        pane(title: "Raw input", editable: true)
                            .frame(minHeight: 200)
                        Divider()
                        pane(title: "Polished output", editable: false)
                            .frame(minHeight: 200)
                        Divider()
                        pane(title: "Reference", editable: false)
                            .frame(minHeight: 200)
                    }
                }

                if showTripleASRSection {
                    Divider()
                    tripleASRSection
                        .frame(minHeight: 200)
                }
            }
        }
    }

    private var tripleASRSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(.secondary)
                Text("Triple ASR")
                    .font(.headline)
                Spacer()
                Button { refreshTripleASR() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                Button { showTripleASRSection = false } label: {
                    Image(systemName: "chevron.down.circle")
                }
                .buttonStyle(.plain)
                .help("Hide triple-ASR section")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            tripleASRPanel
        }
    }

    /// Right-side panel that shows what each ASR model produced for the most
    /// recent capture (live dictation or a golden case with embedded triple-
    /// ASR data). Rows show model name, raw text, word count, and confidence
    /// when available. Models that didn't run (Granite/Moonshine often opt-
    /// in) are surfaced explicitly as "not run".
    private var tripleASRPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(.secondary)
                Text("Triple ASR")
                    .font(.headline)
                Spacer()
                Button {
                    refreshTripleASR()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Reload last_triple_asr.json from disk")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let cap = tripleASR {
                        if let src = cap.source, !src.isEmpty {
                            Text("Source: \(src) · \(Self.shortTime(cap.timestamp))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.top, 8)
                        } else {
                            Text(Self.shortTime(cap.timestamp))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.top, 8)
                        }

                        modelRow(name: "Parakeet v2", text: cap.parakeet, confidence: cap.parakeetConfidence, tint: .blue)
                        modelRow(name: "Granite 4.0",  text: cap.granite,  confidence: cap.graniteConfidence,  tint: .purple)
                        modelRow(name: "Moonshine Tiny", text: cap.moonshine, confidence: cap.moonshineConfidence, tint: .teal)
                        modelRow(name: "Merged (LLM)", text: cap.merged,   confidence: nil, tint: .orange)
                        modelRow(name: "Polished",     text: cap.polished, confidence: nil, tint: .green)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No capture yet.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Text("Dictate with Polish Replay open to populate this panel, or select a golden case that has triple-ASR data attached.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                    }
                    Spacer(minLength: 12)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func modelRow(name: String, text: String?, confidence: Float?, tint: Color) -> some View {
        let clean = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let didRun = (clean != nil) && !(clean!.isEmpty)
        let wordCount = didRun ? clean!.split(whereSeparator: { $0.isWhitespace }).count : 0
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
                Text(name)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if didRun {
                    Text("\(wordCount) word\(wordCount == 1 ? "" : "s")")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    if let c = confidence {
                        Text(String(format: "conf %.2f", c))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("not run")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.gray.opacity(0.15))
                        )
                }
            }
            if didRun {
                Text(clean!)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(tint.opacity(0.07))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(tint.opacity(0.25), lineWidth: 0.5)
                    )
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12)
    }

    private static func shortTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f.string(from: d)
    }

    /// Pick the right source for the panel: if the currently-loaded golden
    /// case has triple-ASR data attached, prefer that; otherwise fall back
    /// to the last live-dictation capture on disk.
    private func refreshTripleASR() {
        if let id = selectedCaseID,
           let c = cases.first(where: { $0.id == id }),
           let snap = c.tripleASR {
            tripleASR = snap
            return
        }
        tripleASR = TripleASRStore.load()
    }

    // MARK: Subviews

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(.secondary)
            Text("Polish Replay")
                .font(.title3.weight(.semibold))
            Spacer()
            Text("\(Qwen3Polisher.availabilityStatus.displayLabel) · 4B: \(Qwen3Polisher.isLargeModelReady ? "ready" : "loading")")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button {
                showTripleASRSection.toggle()
                if showTripleASRSection { refreshTripleASR() }
            } label: {
                Image(systemName: showTripleASRSection ? "waveform.path.ecg.rectangle.fill" : "waveform.path.ecg")
            }
            .buttonStyle(.plain)
            .help("Toggle triple-ASR section")
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var controlsBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button(action: { runPolish() }) {
                    HStack(spacing: 4) {
                        Image(systemName: isRunning ? "hourglass" : "play.fill")
                        Text(isRunning ? "Running…" : "Run")
                    }
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(isRunning || rawText.isEmpty)

                Button(action: { runAll() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Run all")
                    }
                }
                .disabled(isRunning || cases.isEmpty)

                Divider().frame(height: 18)

                Picker("Cleanup", selection: $cleanupLevel) {
                    ForEach(CleanupOption.allCases) { o in
                        Text(o.label).tag(o)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 220)

                Picker("Personality", selection: $personality) {
                    ForEach(PersonalityOption.allCases) { o in
                        Text(o.label).tag(o)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)

                Toggle("Force 4B", isOn: $forceLarge)
                    .toggleStyle(.switch)
                    .controlSize(.small)

                Spacer()

                Button {
                    saveID = ""
                    saveTitle = ""
                    showSaveSheet = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .help("Save current as new case")
                .buttonStyle(.borderless)
            }

            HStack(spacing: 10) {
                statusChip(label: "Route", value: actualRoute)
                statusChip(label: "Elapsed", value: "\(elapsedMs)ms")
                if detectedMultiTopic { statusChip(label: "Multi", value: "yes") }
                if detectedSchema { statusChip(label: "Schema", value: "yes") }
                if let s = similarity {
                    statusChip(label: "Match", value: String(format: "%.0f%%", s * 100), tint: similarityTint(s))
                }
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func statusChip(label: String, value: String, tint: Color? = nil) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(tint ?? .primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.gray.opacity(0.12))
        )
    }

    private func similarityTint(_ s: Double) -> Color {
        if s >= 0.80 { return .green }
        if s >= 0.60 { return .orange }
        return .red
    }

    @ViewBuilder
    private func pane(title: String, editable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            if title == "Raw input" {
                TextEditor(text: $rawText)
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
            } else if title == "Polished output" {
                ScrollView {
                    Text(polishedText.isEmpty ? "—" : polishedText)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .textSelection(.enabled)
                }
            } else {
                ScrollView {
                    diffView
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Per-line diff: lines present in both polished and reference get green,
    /// reference-only lines get red. Lightweight; just intended as a quick
    /// visual scan, not a real merge view.
    private var diffView: some View {
        let referenceLines = referenceText.components(separatedBy: "\n")
        let polishedLines = Set(
            polishedText.components(separatedBy: "\n").map { normalizeLine($0) }
        )
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(referenceLines.enumerated()), id: \.offset) { _, line in
                let key = normalizeLine(line)
                let matched = !key.isEmpty && polishedLines.contains(key)
                Text(line.isEmpty ? " " : line)
                    .foregroundStyle(matched ? Color.green : Color.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func normalizeLine(_ s: String) -> String {
        s.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "  ", with: " ")
    }

    private var batchResultsSheet: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Batch results")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Copy markdown") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(batchOutput, forType: .string)
                }
                Button("Close") { showBatchSheet = false }
            }
            ScrollView {
                Text(batchOutput)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 480)
    }

    private var saveCaseSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save current as new case")
                .font(.title3.weight(.semibold))
            HStack {
                Text("ID")
                    .frame(width: 60, alignment: .leading)
                TextField("e.g. my-case-2026-05-17", text: $saveID)
            }
            HStack {
                Text("Title")
                    .frame(width: 60, alignment: .leading)
                TextField("Human-readable title", text: $saveTitle)
            }
            Text("Saves to ~/Library/Application Support/Voice/GoldenCases/<id>.json. Reference text is taken from the current Reference pane. Raw is taken from Raw input.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { showSaveSheet = false }
                Button("Save") {
                    saveCurrentAsCase()
                }
                .keyboardShortcut(.return)
                .disabled(saveID.isEmpty || saveTitle.isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 480)
    }

    // MARK: - Actions

    private func load(case c: GoldenCase) {
        selectedCaseID = c.id
        rawText = c.raw
        referenceText = c.reference
        polishedText = ""
        elapsedMs = 0
        actualRoute = "—"
        similarity = nil
        if let lvl = c.cleanupLevel, let opt = CleanupOption(rawValue: lvl.lowercased()) {
            cleanupLevel = opt
        }
        if let p = c.personality, let opt = PersonalityOption(rawValue: p.lowercased()) {
            personality = opt
        }
        let det = PolishRouter.detection(for: c.raw)
        detectedMultiTopic = det.multiTopic
        detectedSchema = det.schema
        refreshTripleASR()
    }

    private func runPolish() {
        let raw = rawText
        let cleanup = cleanupLevel.rawValue
        let pers = personality.rawValue
        let force = forceLarge
        isRunning = true
        polishedText = ""
        similarity = nil
        actualRoute = PolishRouter.predictedRoute(for: raw, cleanupLevel: cleanup, forceLarge: force)
        let det = PolishRouter.detection(for: raw)
        detectedMultiTopic = det.multiTopic
        detectedSchema = det.schema

        Task { @MainActor in
            let (out, ms) = await Self.runOnePolish(
                raw: raw,
                cleanupLevel: cleanup,
                personality: pers,
                forceLarge: force
            )
            polishedText = out
            elapsedMs = ms
            similarity = Similarity.score(out, referenceText)
            isRunning = false
        }
    }

    /// Executes one polish run end-to-end. Returns (output, elapsedMs).
    /// Forces 4B by appending "\n\n" which trips the existing routing rule
    /// without refactoring polish(). The trailing whitespace is stripped from
    /// the output for display.
    static func runOnePolish(
        raw: String,
        cleanupLevel: String,
        personality: String,
        forceLarge: Bool
    ) async -> (String, Int) {
        let formatter = TextFormatter()
        let formatted = formatter.format(raw)
        let polishInput = forceLarge ? formatted + "\n\n" : formatted
        let start = Date()
        let result = await Qwen3Polisher.shared.polish(
            polishInput,
            context: .default,
            timeoutMs: 30000,
            suspectWords: nil,
            userVocabulary: nil,
            fieldContext: nil,
            cleanupLevel: cleanupLevel,
            personalityStyle: personality
        )
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed, ms)
    }

    private func runAll() {
        isRunning = true
        caseResults = [:]
        batchOutput = "Running \(cases.count) cases…\n"
        Task { @MainActor in
            var lines: [String] = []
            lines.append("| Case | Route | ms | Similarity | Status |")
            lines.append("|------|-------|-----|------------|--------|")
            var dump = "# polish-replay batch \(Date())\n\n"
            for c in cases {
                let cleanup = c.cleanupLevel ?? "medium"
                let pers = c.personality ?? "neutral"
                let route = PolishRouter.predictedRoute(for: c.raw, cleanupLevel: cleanup, forceLarge: false)
                let (out, ms) = await Self.runOnePolish(
                    raw: c.raw,
                    cleanupLevel: cleanup,
                    personality: pers,
                    forceLarge: false
                )
                let sim = Similarity.score(out, c.reference)
                caseResults[c.id] = sim
                let status: String
                if sim >= 0.80 { status = "ok" }
                else if sim >= 0.60 { status = "warn" }
                else { status = "fail" }
                lines.append("| \(c.id) | \(route) | \(ms) | \(String(format: "%.2f", sim)) | \(status) |")
                dump += "## \(c.id)\nroute=\(route) cleanup=\(cleanup) personality=\(pers) ms=\(ms) sim=\(String(format: "%.3f", sim)) status=\(status)\n\n"
                dump += "RAW:\n\(c.raw)\n\nPOLISHED:\n\(out)\n\nREFERENCE:\n\(c.reference)\n\n---\n\n"
                print("[POLISH-REPLAY] case=\(c.id) route=\(route) ms=\(ms) sim=\(String(format: "%.2f", sim)) status=\(status)")
            }
            batchOutput = lines.joined(separator: "\n")
            print("[POLISH-REPLAY] batch results:\n\(batchOutput)")
            // Dump table + full transcripts to disk so an external test
            // driver can read the actual output without scraping the
            // unified log.
            let table = lines.joined(separator: "\n")
            let final = dump + "\n\(table)\n"
            let dir = GoldenCaseLoader.userDirectory().deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let outURL = dir.appendingPathComponent("polish_replay_last.md")
            try? final.write(to: outURL, atomically: true, encoding: .utf8)
            print("[POLISH-REPLAY] full dump written to \(outURL.path)")
            isRunning = false
            showBatchSheet = true
        }
    }

    private func saveCurrentAsCase() {
        let c = GoldenCase(
            id: saveID,
            title: saveTitle,
            categories: [],
            raw: rawText,
            reference: referenceText,
            notes: nil,
            cleanupLevel: cleanupLevel.rawValue,
            personality: personality.rawValue
        )
        do {
            try GoldenCaseLoader.saveUser(c)
            cases = GoldenCaseLoader.loadAll()
            selectedCaseID = c.id
            showSaveSheet = false
        } catch {
            print("[POLISH-REPLAY] save failed: \(error)")
        }
    }
}

// MARK: - Notification bridge
//
// The live dictation path in VoiceApp posts this after every triple-merge so
// an open Polish Replay window refreshes the panel without polling. Posting
// is best-effort and fire-and-forget — no observers means no-op.

extension Notification.Name {
    static let tripleASRCaptured = Notification.Name("VoiceTripleASRCaptured")
}
