import Foundation

/// Bring-your-own-key AI configuration. Keys live in UserDefaults (base64) —
/// ad-hoc-signed dev builds can't reliably read the Keychain across rebuilds,
/// and these are BYOK keys the user owns. Each provider keeps its OWN key and
/// model, so switching the active provider never loses another's setup. This is
/// the "AI mode" surface — entirely opt-in and separate from local search.
final class AISettings: ObservableObject {
    static let shared = AISettings()

    enum Provider: String, CaseIterable, Identifiable {
        case openai
        case anthropic
        case google
        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .openai: return "OpenAI"
            case .anthropic: return "Claude"
            case .google: return "Gemini"
            }
        }

        /// Tab label — short brand name.
        var shortName: String {
            switch self {
            case .openai: return "OpenAI"
            case .anthropic: return "Anthropic"
            case .google: return "Google"
            }
        }

        /// Full lineup per provider, ordered cheapest/fastest → most capable.
        /// We surface everything and let the user choose; `defaultModel` is the
        /// sensible everyday pick.
        var models: [String] {
            switch self {
            case .openai:
                return ["gpt-5-nano", "gpt-5-mini", "gpt-5"]
            case .anthropic:
                return ["claude-haiku-4-5", "claude-sonnet-4-6", "claude-sonnet-5",
                        "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8"]
            case .google:
                return ["gemini-2.5-flash-lite", "gemini-2.5-flash", "gemini-2.5-pro"]
            }
        }

        /// The everyday default — fast & affordable, not the cheapest-possible.
        var defaultModel: String {
            switch self {
            case .openai: return "gpt-5-mini"
            case .anthropic: return "claude-haiku-4-5"
            case .google: return "gemini-2.5-flash"
            }
        }

        /// Short capability/cost note shown next to each model.
        func blurb(for model: String) -> String {
            switch model {
            // Cheapest / fastest
            case "gpt-5-nano", "gemini-2.5-flash-lite":
                return "Fastest & cheapest · quick lookups"
            // Fast & affordable everyday
            case "gpt-5-mini", "claude-haiku-4-5", "gemini-2.5-flash":
                return "Fast & affordable · best for everyday searches"
            // Balanced
            case "claude-sonnet-4-6":
                return "Balanced · strong reasoning, mid cost"
            case "claude-sonnet-5":
                return "Balanced · latest Sonnet, great tool use"
            // High capability
            case "claude-opus-4-6", "claude-opus-4-7":
                return "Very capable · deeper reasoning, higher cost"
            // Most capable
            case "gpt-5", "claude-opus-4-8", "gemini-2.5-pro":
                return "Most capable · deepest reasoning, top cost"
            default:
                return ""
            }
        }

        /// Where the user creates a key — surfaced as the onboarding link.
        var keyURL: URL {
            switch self {
            case .openai: return URL(string: "https://platform.openai.com/api-keys")!
            case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")!
            case .google: return URL(string: "https://aistudio.google.com/apikey")!
            }
        }

        /// Placeholder that hints at the key's shape.
        var keyPlaceholder: String {
            switch self {
            case .openai: return "sk-…"
            case .anthropic: return "sk-ant-…"
            case .google: return "AIza…"
            }
        }
    }

    private let defaults = UserDefaults.standard
    private let providerKey = "beacon.ai.provider"
    private let sourcesKey = "beacon.ai.enabledSources"
    private let disclosedKey = "beacon.ai.privacyDisclosed"
    private func modelKey(_ p: Provider) -> String { "beacon.ai.model.\(p.rawValue)" }
    private func keyKey(_ p: Provider) -> String { "beacon.ai.key.\(p.rawValue).b64" }
    // Pre-multi-provider builds stored a single OpenAI key/model here.
    private let legacyKeyDefault = "beacon.ai.apiKey.b64"
    private let legacyModelKey = "beacon.ai.model"

    /// The provider used for queries. Selecting a tab in Manage sets this.
    @Published var provider: Provider {
        didSet { defaults.set(provider.rawValue, forKey: providerKey) }
    }
    /// True once the user has seen and accepted the AI privacy disclosure.
    @Published var privacyDisclosed: Bool {
        didSet { defaults.set(privacyDisclosed, forKey: disclosedKey) }
    }

    private init() {
        let raw = defaults.string(forKey: providerKey) ?? Provider.openai.rawValue
        self.provider = Provider(rawValue: raw) ?? .openai
        self.privacyDisclosed = defaults.bool(forKey: disclosedKey)
        migrateLegacyIfNeeded()
    }

    /// Carry a single-provider (OpenAI-only) build's key/model into the
    /// per-provider slots so nobody has to re-enter their key after updating.
    private func migrateLegacyIfNeeded() {
        if let b64 = defaults.string(forKey: legacyKeyDefault),
           defaults.string(forKey: keyKey(.openai)) == nil {
            defaults.set(b64, forKey: keyKey(.openai))
            defaults.removeObject(forKey: legacyKeyDefault)
        }
        if let m = defaults.string(forKey: legacyModelKey),
           defaults.string(forKey: modelKey(.openai)) == nil {
            defaults.set(m, forKey: modelKey(.openai))
            defaults.removeObject(forKey: legacyModelKey)
        }
    }

    // MARK: - Model (per provider)

    func model(for p: Provider) -> String {
        let saved = defaults.string(forKey: modelKey(p))
        if let saved, p.models.contains(saved) { return saved }
        return p.defaultModel
    }

    func setModel(_ m: String, for p: Provider) {
        objectWillChange.send()
        defaults.set(m, forKey: modelKey(p))
    }

    /// The active provider's model — what the conductor runs with.
    var model: String { model(for: provider) }

    // MARK: - API key (per provider)

    func apiKey(for p: Provider) -> String? {
        guard let b64 = defaults.string(forKey: keyKey(p)),
              let data = Data(base64Encoded: b64),
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else { return nil }
        return key
    }

    func hasKey(for p: Provider) -> Bool { apiKey(for: p) != nil }

    func setKey(_ key: String?, for p: Provider) {
        objectWillChange.send()
        if let key, !key.isEmpty {
            defaults.set(Data(key.utf8).base64EncodedString(), forKey: keyKey(p))
        } else {
            defaults.removeObject(forKey: keyKey(p))
        }
    }

    /// The active provider's key — what the conductor authenticates with.
    var apiKey: String? { apiKey(for: provider) }
    var hasKey: Bool { hasKey(for: provider) }

    // MARK: - Enabled sources

    /// Which sources the AI is allowed to search. Messages and Mail are off by
    /// default — the most sensitive, opt-in explicitly.
    @Published var enabledSources: Set<AISource> = [] {
        didSet { defaults.set(enabledSources.map(\.rawValue), forKey: sourcesKey) }
    }

    /// Load persisted source selection, or fall back to a privacy-forward default.
    func loadEnabledSources() {
        // An empty persisted set means "AI can't search anything" — treat it as
        // unset and fall back to the privacy-forward defaults instead.
        if let raw = defaults.array(forKey: sourcesKey) as? [String], !raw.isEmpty {
            enabledSources = Set(raw.compactMap(AISource.init(rawValue:)))
        } else {
            enabledSources = AISource.defaultEnabled
        }
    }
}

/// A source the AI agent may search. Mirrors Beacon's connectors.
enum AISource: String, CaseIterable, Identifiable {
    case files, folders, messages, mail, notes, calendar, history, clipboard, apps
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .files: return "Files"
        case .folders: return "Folders"
        case .messages: return "Messages"
        case .mail: return "Mail"
        case .notes: return "Notes"
        case .calendar: return "Calendar"
        case .history: return "Browser History"
        case .clipboard: return "Clipboard"
        case .apps: return "Apps"
        }
    }

    /// Privacy-forward default: everything except the two most sensitive
    /// personal-message sources, which the user opts into explicitly.
    static var defaultEnabled: Set<AISource> {
        Set(allCases).subtracting([.messages, .mail])
    }
}
