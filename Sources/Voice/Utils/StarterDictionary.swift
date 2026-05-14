// VOICE — Starter + User Vocabulary
// ============================================================
// Two-tier dictionary surfaced to the ASR pipeline and the Qwen3
// polish prompt:
//
//   1. StarterDictionary.terms — ~150 hand-picked tech/AI/company/
//      acronym terms the typical VOICE user dictates. Static.
//   2. UserDictionary.terms() — user-added entries persisted to
//      UserDefaults under "voice.userDictionary". Mutable.
//
// `combined()` merges them with the user list taking precedence on
// case-insensitive duplicates (so a user override of "Github" → "GitHub"
// wins over the canonical spelling we hardcoded).
//
// On the FluidAudio side: `SlidingWindowAsrManager.configureVocabularyBoosting`
// accepts a `CustomVocabularyContext` built from these terms. The batch
// `AsrManager` path used by TranscriptionService.transcribeFile does NOT
// currently expose a public vocabulary-boost API — so for batch we only
// inject the terms into the Qwen3 polish prompt. Live-partials path
// (which DOES use SlidingWindowAsrManager) would be a natural place to
// add CTC-level biasing, but it's not wired here yet.
// ============================================================

import Foundation
import FluidAudio

/// Hand-picked terms users of a developer/maker-oriented dictation app
/// dictate constantly — Parakeet often mis-spells these (e.g. "GitHub"
/// → "get hub", "Claude" → "clawed"). Surfaced verbatim into the
/// Qwen3 polish prompt and into FluidAudio's vocabulary biasing for
/// the streaming path.
enum StarterDictionary {
    // NOTE: Order matters for vocabulary biasing — earlier entries are
    // more frequently dictated and get marginally more weight under the
    // BKTree spotter when ties occur. High-confusion homophones first
    // (ChatGPT → "Chachi Pt", Claude → "clawed", GitHub → "get hub").
    static let terms: [String] = [
        // AI assistants + models (top homophone offenders)
        "ChatGPT", "Claude", "Sonnet", "Haiku", "Opus", "Anthropic", "OpenAI",
        "GPT", "GPT-4", "GPT-5", "Gemini", "DeepSeek", "Mistral", "Llama",
        "Qwen", "Whisper", "Parakeet", "FluidAudio",

        // Dev tools / IDEs / CLIs
        "GitHub", "GitLab", "Bitbucket", "VSCode", "Xcode", "Cursor",
        "Windsurf", "Zed", "Neovim", "tmux", "ripgrep", "Homebrew", "brew",
        "Docker", "Kubernetes", "Terraform", "Ansible", "npm", "pnpm",
        "yarn", "Bun", "Deno", "Vite", "ESLint", "Prettier", "Webpack",

        // Languages + frameworks
        "TypeScript", "JavaScript", "Python", "Swift", "SwiftUI", "Rust",
        "Golang", "Kotlin", "Tauri", "React", "Vue", "Svelte", "Next.js",
        "Nuxt", "Astro", "Tailwind", "MLX", "CoreML", "PyTorch", "TensorFlow",
        "async", "await", "struct", "enum", "protocol",

        // Databases + infra
        "PostgreSQL", "MySQL", "SQLite", "MongoDB", "Redis", "Supabase",
        "Firebase", "Cloudflare", "Vercel", "Netlify", "Heroku", "AWS",
        "GCP", "Azure", "DigitalOcean", "Tailscale", "WireGuard",

        // Apple platforms + hardware
        "Apple", "macOS", "iOS", "iPadOS", "watchOS", "visionOS",
        "iPhone", "iPad", "MacBook", "Mac", "M1", "M2", "M3", "M4", "M5",
        "Vision Pro", "AirPods", "Safari",

        // Companies / products / browsers
        "Google", "Microsoft", "Amazon", "Meta", "Slack", "Notion",
        "Linear", "Figma", "Loom", "Discord", "Twitter", "X.com",
        "YouTube", "LinkedIn", "Reddit", "Hacker News", "Twitch",
        "TikTok", "Instagram", "Spotify", "Netflix", "Stripe", "Shopify",
        "Chrome", "Firefox", "Edge", "Arc", "Zoom", "iMessage", "WhatsApp",

        // OS / *nix
        "Linux", "Ubuntu", "Debian", "Fedora", "Arch", "WSL", "Bash", "zsh",

        // Protocols + formats + acronyms
        "API", "REST", "GraphQL", "WebSocket", "WebRTC", "WebGL", "WebGPU",
        "HTTP", "HTTPS", "TCP", "UDP", "DNS", "SSH", "TLS", "JWT", "OAuth",
        "CORS", "CSRF", "URL", "URI", "JSON", "YAML", "TOML", "XML",
        "HTML", "CSS", "SCSS", "SQL", "CSV", "PDF", "Markdown",

        // Hardware / dev acronyms
        "GPU", "CPU", "NPU", "ANE", "RAM", "VRAM", "SSD", "NVMe", "USB",
        "USB-C", "HDMI", "DisplayPort", "Thunderbolt",

        // Process / role acronyms
        "IDE", "CLI", "GUI", "TUI", "PR", "QA", "CI", "CD", "MVP", "RFC",
        "SDK", "DX", "UX", "UI", "CEO", "CTO", "CFO", "COO", "VP", "PM",
        "MIT", "MBA", "PhD",
    ]
}

/// UserDefaults-backed user vocabulary. The UI for editing this is not
/// yet built — these accessors are the data layer the future settings
/// pane will read/write through.
enum UserDictionary {
    private static let defaultsKey = "voice.userDictionary"

    /// All user-added terms (de-duplicated, original casing preserved).
    static func terms() -> [String] {
        let stored = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        // Defensive: trim, drop empties, de-dupe case-insensitively.
        var seen = Set<String>()
        var out: [String] = []
        for raw in stored {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            if seen.insert(t.lowercased()).inserted {
                out.append(t)
            }
        }
        return out
    }

    /// Replace the user list. Caller is responsible for sanitization beyond
    /// trim+dedupe (which we do on read).
    static func setTerms(_ terms: [String]) {
        UserDefaults.standard.set(terms, forKey: defaultsKey)
    }

    /// Add one term. Idempotent on case-insensitive match.
    static func add(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var existing = terms()
        let lower = trimmed.lowercased()
        guard !existing.contains(where: { $0.lowercased() == lower }) else { return }
        existing.append(trimmed)
        setTerms(existing)
    }

    /// Remove one term (case-insensitive).
    static func remove(_ term: String) {
        let lower = term.lowercased()
        let filtered = terms().filter { $0.lowercased() != lower }
        setTerms(filtered)
    }
}

/// Merged starter + user terms. User entries take precedence on case-
/// insensitive duplicates so a user's preferred casing overrides ours.
enum CombinedDictionary {
    static func terms() -> [String] {
        let user = UserDictionary.terms()
        let userLower = Set(user.map { $0.lowercased() })
        let starterUnique = StarterDictionary.terms.filter { !userLower.contains($0.lowercased()) }
        // User first so their casing wins downstream consumers that dedupe.
        return user + starterUnique
    }

    /// Build a FluidAudio `CustomVocabularyContext` from the merged list.
    /// Used by the streaming (SlidingWindowAsrManager) path. Each term is
    /// weighted equally — no weights persisted in this v1 data model.
    static func vocabularyContext() -> CustomVocabularyContext {
        let entries = terms().map {
            CustomVocabularyTerm(text: $0, weight: 10.0)
        }
        return CustomVocabularyContext(terms: entries)
    }
}
