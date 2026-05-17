// ProperNounVocabulary.swift
//
// Builds and persists a user-specific proper-noun vocabulary that gets
// fed into the polish prompt and the EntityFreezer. Solves the "Wispr
// Flow → Whisperflo" class of bug where the LLM doesn't know a term is
// a fixed brand name and helpfully "corrects" it.
//
// Sources of vocabulary (in priority order):
//   1. Manually added terms (UserDefaults, future settings UI)
//   2. Frequently-appearing capitalized n-grams in past dictations
//   3. macOS Contacts first/last names (defer — needs permission)
//   4. A seed list of common brands/products (Wispr Flow, ChatGPT, Claude…)
//
// The auto-learning step runs after each dictation is polished — it
// scans the FINAL text for capitalized words that appeared 2+ times
// across the user's last 50 dictations and weren't already known. This
// way the model "learns" the user's frequent proper nouns without
// requiring manual setup.

import Foundation

public enum ProperNounVocabulary {
    private static let key = "userProperNouns"
    private static let maxTerms = 600

    /// Seed terms — common brands, products, people, places the model
    /// commonly mangles or that have unusual casing. Aggregated from
    /// multi-source research; entries are deduped at runtime.
    private static let seedTerms: [String] = [
        // ── App-specific
        "Wispr Flow", "Voice",

        // ── AI / ML products & companies
        "ChatGPT", "Claude", "OpenAI", "Anthropic", "Gemini", "DeepMind",
        "Google DeepMind", "Meta AI", "Mistral", "Llama", "Mixtral",
        "Qwen", "DeepSeek", "Stable Diffusion", "Midjourney", "DALL-E",
        "Whisper", "Parakeet", "Hugging Face", "GPT-4", "GPT-4o",
        "Claude 3.5 Sonnet", "Sonnet", "Opus", "Haiku",
        "Llama 3", "Phi-3", "Gemma",
        // ── AI models (current generation, mid-2026)
        "Qwen3", "Qwen 3", "Qwen2.5", "Qwen 2.5", "Qwen-3", "Qwen3-235B",
        "Qwen3 Coder", "Qwen3 Instruct", "Qwen3-VL", "Qwen3 Max",
        "GLM", "GLM-4", "GLM-4.5", "GLM-4.6", "GLM-4.7", "GLM-Air",
        "Kimi", "Kimi K2", "Moonshot", "Yi", "Yi-34B",
        "DeepSeek-V3", "DeepSeek-R1", "DeepSeek V3.1", "DeepSeek-Coder",
        "MiniCPM", "MiniCPM-V", "LFM", "LFM-2", "LFM-2.5",
        "Phi-4", "Phi-3.5", "Gemma 2", "Gemma 3",
        "Llama 4", "Llama 3.3", "Llama 3.2", "Llama-3.1",
        "Claude 4", "Claude 4.5", "Claude 4.6", "Claude 4.7",
        "Claude Opus 4", "Claude Sonnet 4", "Claude Haiku 4",
        "GPT-5", "GPT-5 Turbo", "o1", "o3", "o4-mini", "GPT-OSS", "gpt-oss-20b",
        "Grok-3", "Grok-4", "Nova", "Command R+", "Reka",
        // ── Inference providers / hosts
        "Cerebras", "Groq", "Together AI", "Fireworks", "Replicate",
        "Modal", "RunPod", "Lambda Labs", "vast.ai", "OpenRouter",
        "LM Studio", "Jan", "vLLM", "llama.cpp", "Ollama",
        // ── ML infra terms
        "MoE", "Mixture of Experts", "MCP", "Model Context Protocol",
        "RAG", "LoRA", "QLoRA", "GGUF", "GPTQ", "AWQ", "FP8", "BF16",

        // ── Dev tools, IDEs, editors
        "Cursor", "VS Code", "Visual Studio Code", "IntelliJ", "PyCharm",
        "WebStorm", "Xcode", "Vim", "Neovim", "Emacs", "Sublime Text",
        "Atom", "Zed", "Fleet", "Android Studio",

        // ── Productivity / collaboration
        "Linear", "Notion", "Slack", "Discord", "Telegram", "WhatsApp",
        "Microsoft Teams", "Zoom", "Figma", "Sketch", "Framer", "Miro",
        "Asana", "Trello", "ClickUp", "Jira", "Confluence",
        "Obsidian", "Roam", "Logseq", "Bear", "Things 3", "Todoist",
        "Anki", "Reminders",

        // ── Cloud / hosting / infra
        "AWS", "Amazon Web Services", "GCP", "Google Cloud", "Azure",
        "Cloudflare", "Vercel", "Netlify", "Heroku", "DigitalOcean",
        "Fly.io", "Render", "Railway", "Supabase", "Firebase",
        "Akamai", "Fastly", "CloudFront",

        // ── Databases
        "PostgreSQL", "Postgres", "MongoDB", "Redis", "SQLite", "MySQL",
        "DynamoDB", "Snowflake", "BigQuery", "Elasticsearch", "Kafka",
        "Cassandra", "CockroachDB", "PlanetScale", "Neon", "Turso",

        // ── Programming languages
        "Swift", "Rust", "TypeScript", "JavaScript", "Python", "Kotlin",
        "Go", "Java", "C++", "C#", "Objective-C", "Ruby", "PHP", "Scala",
        "Elixir", "Erlang", "Haskell", "OCaml", "Lua", "Dart", "Zig",
        "Groovy", "Perl",

        // ── Frameworks
        "React", "React Native", "Vue", "Vue.js", "Svelte", "SvelteKit",
        "Solid.js", "Angular", "Next.js", "Nuxt.js", "Nuxt", "Remix",
        "Astro", "Qwik", "Express.js", "FastAPI", "Django", "Flask",
        "Rails", "Spring", "Laravel", "Phoenix", "Bun", "Deno",
        "Node.js", "Tailwind", "Tailwind CSS", "Bootstrap", "Chakra",
        "Material UI", "shadcn", "Radix",

        // ── DevOps / tools
        "Docker", "Kubernetes", "Terraform", "Ansible", "Pulumi",
        "GitHub", "GitHub Actions", "GitLab", "Bitbucket", "Vercel",
        "Nginx", "Apache", "HAProxy", "Caddy", "Grafana", "Prometheus",
        "Datadog", "Sentry", "PagerDuty", "Mixpanel", "Amplitude",
        "PostHog", "LaunchDarkly", "Segment",

        // ── JS ecosystem
        "npm", "Yarn", "pnpm", "Bun", "Vite", "Webpack", "Rollup",
        "esbuild", "Turbopack", "Lodash", "Zod", "tRPC", "GraphQL",
        "Apollo", "Prisma", "Drizzle",

        // ── Operating systems / shells
        "iOS", "iPadOS", "watchOS", "tvOS", "visionOS", "macOS",
        "Windows", "Linux", "Ubuntu", "Debian", "Arch", "Arch Linux",
        "Fedora", "CentOS", "Alpine", "NixOS",
        "Bash", "Zsh", "Fish", "PowerShell",

        // ── Browsers
        "Chrome", "Safari", "Firefox", "Edge", "Arc", "Brave",
        "DuckDuckGo", "Vivaldi", "Opera",

        // ── Apple ecosystem
        "iPhone", "iPad", "iPad Pro", "iPad Air", "iPad mini",
        "MacBook", "MacBook Air", "MacBook Pro", "iMac", "Mac Pro",
        "Mac mini", "Mac Studio", "Apple Watch", "AirPods", "AirPods Pro",
        "Vision Pro", "Apple TV", "iCloud", "iMessage", "FaceTime",
        "AirDrop", "Handoff", "Continuity", "M1", "M2", "M3", "M4",

        // ── Streaming / media
        "Spotify", "Netflix", "YouTube", "YouTube Music", "Apple Music",
        "Tidal", "SoundCloud", "Twitch", "Vimeo", "TikTok", "Instagram",
        "Threads", "Mastodon", "Bluesky", "Reddit", "Pinterest",

        // ── Big tech
        "Apple", "Google", "Microsoft", "Meta", "Amazon", "Nvidia",
        "Intel", "AMD", "Tesla", "SpaceX", "Boeing", "Samsung",
        "Sony", "LG", "Xiaomi", "Huawei", "OnePlus",

        // ── Fintech / commerce
        "Stripe", "Square", "PayPal", "Venmo", "Cash App", "Robinhood",
        "Coinbase", "Kraken", "Binance", "Plaid", "Shopify", "Etsy",

        // ── Cryptocurrencies & tickers
        "Bitcoin", "BTC", "Ethereum", "ETH", "Solana", "SOL", "Cardano",
        "ADA", "Polkadot", "DOT", "Avalanche", "AVAX", "Chainlink", "LINK",
        "Polygon", "MATIC", "Dogecoin", "DOGE", "Litecoin", "LTC",

        // ── Currency codes
        "USD", "EUR", "GBP", "JPY", "CAD", "AUD", "CHF", "CNY", "INR",
        "KRW", "SEK", "NOK", "DKK", "HKD", "SGD", "MXN", "BRL", "RUB",

        // ── Music artists with non-obvious spellings
        "The Weeknd", "Beyoncé", "Drake", "Kendrick Lamar", "Taylor Swift",
        "Playboi Carti", "Travis Scott", "Frank Ocean", "Childish Gambino",
        "Tyler the Creator", "SZA", "Doja Cat", "Billie Eilish",
        "Bad Bunny", "Rosalía", "Olivia Rodrigo", "The 1975",
        "Arctic Monkeys", "Radiohead", "Tame Impala",

        // ── Sports figures
        "LeBron James", "Steph Curry", "Stephen Curry", "Kevin Durant",
        "Lionel Messi", "Cristiano Ronaldo", "Kylian Mbappé", "Erling Haaland",
        "Patrick Mahomes", "Tom Brady", "Lewis Hamilton", "Max Verstappen",

        // ── Tech personalities (founders / CEOs)
        "Elon Musk", "Sam Altman", "Dario Amodei", "Demis Hassabis",
        "Sundar Pichai", "Satya Nadella", "Tim Cook", "Jeff Bezos",
        "Mark Zuckerberg", "Jensen Huang", "Lisa Su", "Yann LeCun",
        "Geoffrey Hinton", "Andrej Karpathy", "Andrew Ng",

        // ── Cities (tricky spellings)
        "Reykjavik", "São Paulo", "Phuket", "Melbourne", "Edinburgh",
        "Dubai", "Bangkok", "Copenhagen", "Amsterdam", "Stockholm", "Oslo",
        "Helsinki", "Warsaw", "Prague", "Budapest", "Vienna", "Istanbul",
        "Athens", "Cairo", "Nairobi", "Cape Town", "Johannesburg",
        "Mumbai", "Delhi", "Bangalore", "Hyderabad", "Shanghai", "Beijing",
        "Shenzhen", "Seoul", "Singapore", "Hong Kong", "Tokyo", "Kyoto",
        "Sydney", "Lagos", "Toronto", "Vancouver", "Montreal", "Quebec",
        "San Francisco", "Los Angeles", "New York", "Chicago", "Miami",
        "Austin", "Denver", "Seattle", "Portland", "Mexico City",

        // ── Common acronyms (should stay all caps)
        "API", "URL", "URI", "JSON", "XML", "YAML", "HTML", "CSS", "SQL",
        "REST", "GraphQL", "gRPC", "JWT", "OAuth", "SSO", "SaaS", "PaaS",
        "IaaS", "CRUD", "MVC", "MVP", "MVVM", "ORM", "REPL", "CLI", "GUI",
        "TUI", "AI", "ML", "LLM", "RAG", "NLP", "CV", "GPU", "CPU", "TPU",
        "RAM", "ROM", "SSD", "HDD", "USB", "USB-C", "HDMI", "GPS", "NFC",
        "IoT", "SDK", "IDE", "VPN", "DNS", "SSL", "TLS", "TCP", "UDP",
        "HTTP", "HTTPS", "FTP", "SSH", "IP", "MAC", "LAN", "WAN", "WiFi",
        "Wi-Fi", "Bluetooth", "OLED", "LCD", "LED", "QR", "PDF", "CSV",
        "CEO", "CTO", "CFO", "COO", "VP", "PM", "QA", "UX", "UI",

        // ── Common first names (preserve casing)
        "Maya", "Mia", "Nathan", "Sophia", "Aiden", "Liam", "Olivia",
        "Daniel", "Michael", "John", "Jane", "Sarah", "Alex", "Sam",
        "Emma", "Noah", "Ava", "Ethan", "Isabella", "Mason",
        "Lucas", "Charlotte", "Logan", "Amelia", "Oliver", "Harper",
        "Jacob", "Evelyn", "James", "Abigail", "Benjamin", "Emily",
        "Henry", "Madison", "Sebastian", "Avery", "William", "Ella",
        "Elijah", "Scarlett", "Carter", "Grace", "Owen", "Chloe",
        "Jackson", "Victoria", "Caleb", "Riley", "Ryan", "Aria",
        "Asher", "Lily", "Christopher", "Aubrey", "Joshua", "Zoey",
        "Andrew", "Penelope", "Theodore", "Lila", "David", "Layla",
        "Joseph", "Mila", "Mateo", "Nora", "Jonathan", "Hazel",
        // International names ASR commonly mishandles
        "Aaliyah", "Aarav", "Aiko", "Akira", "Ananya", "Anya",
        "Arjun", "Carlos", "Catalina", "Chloé", "Diego", "Elena",
        "Fatima", "Gabriel", "Hiroshi", "Inés", "Isla", "Javier",
        "Jin", "José", "Juan", "Khalid", "Léa", "Lucia",
        "Mariana", "Mohammed", "Mohamed", "Nikolai", "Priya",
        "Rafael", "Ravi", "Santiago", "Sofia", "Tariq", "Yuki",
        "Yusuf", "Zara", "Zoe",

        // ── Additional big-tech / enterprise brands
        "ServiceNow", "Workday", "Atlassian", "Confluence", "Asana",
        "Monday", "Airtable", "HubSpot", "Salesforce", "SAP",
        "Oracle", "IBM", "Cisco", "Adobe", "Broadcom", "Qualcomm",
        "AMD", "ASML", "Arm", "Snowflake", "Databricks", "Cloudera",
        "Splunk", "New Relic", "Datadog", "Sentry", "PagerDuty",
        "LaunchDarkly", "Segment", "Mixpanel", "Amplitude",
        "Heap", "LogRocket", "Dynatrace", "AppDynamics", "Elastic",

        // ── More streaming / media / social
        "Disney+", "Hulu", "HBO Max", "Apple TV+", "Peacock",
        "Paramount+", "Crunchyroll", "Funimation", "Shudder",
        "Vimeo", "Pinterest", "Quora", "Substack", "Medium",
        "Patreon", "OnlyFans", "Discord Nitro",

        // ── AI / ML companies expanded
        "Stability AI", "Perplexity", "Scale AI", "Together AI",
        "Replicate", "Modal", "RunwayML", "Twelve Labs", "Descript",
        "Synthesia", "Loom", "Krea", "Suno", "ElevenLabs", "Pika",
        "Genesis", "Black Forest Labs", "Cohere", "AI21 Labs",
        "Inflection", "xAI", "Grok", "Pi", "Character AI",

        // ── More design / creative tools
        "Webflow", "Wix", "Squarespace", "Carrd", "Framer Sites",
        "Penpot", "Affinity", "CorelDRAW", "Procreate", "Canva",
        "Photopea", "Krita", "Inkscape", "GIMP",

        // ── Payment / fintech expanded
        "Adyen", "Braintree", "Wise", "Razorpay", "Gumroad",
        "FastSpring", "Paddle", "Recurly", "Chargebee",
        "Mercury", "Brex", "Ramp",

        // ── DevOps tools expanded
        "Jenkins", "CircleCI", "Travis CI", "BuildKite", "Drone",
        "Spinnaker", "ArgoCD", "Pulumi", "Ansible", "Chef", "Puppet",
        "Vagrant", "Packer", "CloudFormation",

        // ── Email / communication expanded
        "ProtonMail", "Tutanota", "Fastmail", "HEY", "Superhuman",
        "Spark", "Outlook", "Thunderbird", "Twilio", "SendGrid",
        "Mailgun", "Postmark", "Mailchimp", "ConvertKit", "Klaviyo",
    ]

    /// Get the current vocabulary (manual + learned + seed).
    public static func current() -> [String] {
        let stored = UserDefaults.standard.array(forKey: key) as? [String] ?? []
        // Merge seed terms in case fresh install / cleared defaults.
        var merged = Array(Set(stored + seedTerms))
        merged.sort { $0.count > $1.count }   // longest first for prefix-match priority
        if merged.count > maxTerms {
            merged = Array(merged.prefix(maxTerms))
        }
        return merged
    }

    /// Add a manually-entered term.
    public static func add(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var stored = UserDefaults.standard.array(forKey: key) as? [String] ?? []
        if !stored.contains(trimmed) {
            stored.append(trimmed)
            UserDefaults.standard.set(stored, forKey: key)
            print("[VOICE-VOCAB] added: \(trimmed)")
        }
    }

    /// Remove a term.
    public static func remove(_ term: String) {
        var stored = UserDefaults.standard.array(forKey: key) as? [String] ?? []
        stored.removeAll { $0 == term }
        UserDefaults.standard.set(stored, forKey: key)
    }

    /// Learn proper nouns from a polished dictation. Called after each
    /// successful polish. Heuristic: capitalized multi-letter words that
    /// aren't at sentence starts, aren't common English words, and
    /// appeared before.
    public static func learnFrom(_ polishedText: String, previousDictations: [String]) {
        let candidates = extractCandidates(from: polishedText)
        guard !candidates.isEmpty else { return }

        // Only promote terms that appeared in at least one prior dictation.
        // This avoids learning random one-off names from a single rant.
        var counter: [String: Int] = [:]
        for prior in previousDictations {
            let priorCandidates = extractCandidates(from: prior)
            for c in priorCandidates {
                counter[c, default: 0] += 1
            }
        }

        var stored = UserDefaults.standard.array(forKey: key) as? [String] ?? []
        var added = 0
        for c in candidates {
            // Need ≥2 prior appearances to qualify as a recurring term.
            guard (counter[c] ?? 0) >= 2 else { continue }
            guard !stored.contains(c) else { continue }
            guard !seedTerms.contains(c) else { continue }
            stored.append(c)
            added += 1
        }
        if added > 0 {
            UserDefaults.standard.set(stored, forKey: key)
            print("[VOICE-VOCAB] learned \(added) terms from history")
        }
    }

    /// Extract candidate proper nouns from text. A candidate is:
    ///   - 3+ letters
    ///   - first letter uppercase, rest mixed
    ///   - NOT a common English word at sentence start
    ///   - NOT all-uppercase (acronyms handled separately)
    private static func extractCandidates(from text: String) -> [String] {
        // Pattern: capitalized word, possibly multi-word (TitleCase chains).
        let pattern = #"\b[A-Z][a-z]{2,}(?:\s+[A-Z][a-z]+)?\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))

        // Filter out words that appear immediately after a sentence boundary
        // (".", "!", "?", or start of string) — they may just be sentence
        // starts, not proper nouns.
        var candidates: [String] = []
        for match in matches {
            let r = match.range
            let word = ns.substring(with: r)
            // Skip if this is sentence-initial.
            if r.location == 0 { continue }
            let prevChar = ns.substring(with: NSRange(location: r.location - 1, length: 1))
            if prevChar == " " {
                if r.location >= 2 {
                    let prev2 = ns.substring(with: NSRange(location: r.location - 2, length: 1))
                    if [".", "!", "?", "\n"].contains(prev2) { continue }
                }
            } else if [".", "!", "?", "\n"].contains(prevChar) {
                continue
            }
            if commonWords.contains(word.lowercased()) { continue }
            candidates.append(word)
        }
        return Array(Set(candidates))
    }

    /// Conservative stoplist — words that are commonly capitalized at
    /// sentence start but aren't proper nouns. Keeps the learning step
    /// from polluting the vocabulary with "The", "However", etc.
    private static let commonWords: Set<String> = [
        "the", "and", "but", "also", "however", "yes", "no", "okay",
        "hey", "well", "actually", "maybe", "probably", "definitely",
        "today", "tomorrow", "yesterday", "now", "then", "this", "that",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july",
        "august", "september", "october", "november", "december",
    ]
}
