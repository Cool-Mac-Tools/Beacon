import Foundation

/// Bring-your-own-key AI configuration. The API key lives in the macOS Keychain
/// (never UserDefaults, never the repo); provider/model/enabled-sources are
/// plain preferences. This is the "AI mode" upsell surface — entirely opt-in and
/// separate from local search.
final class AISettings: ObservableObject {
    static let shared = AISettings()

    enum Provider: String, CaseIterable, Identifiable {
        case openai
        case anthropic
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .openai: return "OpenAI"
            case .anthropic: return "Claude (Anthropic)"
            }
        }
        /// Sensible default model per provider. Users can override.
        var defaultModel: String {
            switch self {
            case .openai: return "gpt-5-mini"
            case .anthropic: return "claude-opus-4-8"
            }
        }
        var models: [String] {
            switch self {
            case .openai: return ["gpt-5-mini", "gpt-5"]
            case .anthropic: return ["claude-opus-4-8", "claude-haiku-4-5"]
            }
        }
        /// Short capability/cost note shown next to each model in settings.
        func blurb(for model: String) -> String {
            switch model {
            case "gpt-5-mini": return "Fast & affordable · best for everyday searches"
            case "gpt-5": return "Most capable · deeper reasoning, higher cost"
            case "claude-opus-4-8": return "Most capable · deep reasoning, higher cost"
            case "claude-haiku-4-5": return "Fast & affordable · best for everyday searches"
            default: return ""
            }
        }
    }

    private let defaults = UserDefaults.standard
    private let providerKey = "beacon.ai.provider"
    private let modelKey = "beacon.ai.model"
    private let sourcesKey = "beacon.ai.enabledSources"
    private let disclosedKey = "beacon.ai.privacyDisclosed"
    /// The API key is stored in UserDefaults (base64) rather than the Keychain:
    /// ad-hoc-signed dev builds can't reliably read Keychain items across
    /// rebuilds, and this is a BYOK key the user owns. Simple and it persists.
    private let apiKeyDefault = "beacon.ai.apiKey.b64"

    @Published var provider: Provider {
        didSet {
            defaults.set(provider.rawValue, forKey: providerKey)
            // Keep the model valid for the chosen provider.
            if !provider.models.contains(model) { model = provider.defaultModel }
        }
    }
    @Published var model: String { didSet { defaults.set(model, forKey: modelKey) } }
    /// True once the user has seen and accepted the AI privacy disclosure.
    @Published var privacyDisclosed: Bool {
        didSet { defaults.set(privacyDisclosed, forKey: disclosedKey) }
    }

    private init() {
        let raw = defaults.string(forKey: providerKey) ?? Provider.openai.rawValue
        let p = Provider(rawValue: raw) ?? .openai
        self.provider = p
        self.model = defaults.string(forKey: modelKey) ?? p.defaultModel
        self.privacyDisclosed = defaults.bool(forKey: disclosedKey)
    }

    // MARK: - API key

    var hasKey: Bool { !(apiKey ?? "").isEmpty }

    var apiKey: String? {
        get {
            guard let b64 = defaults.string(forKey: apiKeyDefault),
                  let data = Data(base64Encoded: b64),
                  let key = String(data: data, encoding: .utf8) else { return nil }
            return key
        }
        set {
            if let newValue, !newValue.isEmpty {
                defaults.set(Data(newValue.utf8).base64EncodedString(), forKey: apiKeyDefault)
            } else {
                defaults.removeObject(forKey: apiKeyDefault)
            }
            objectWillChange.send()
        }
    }

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
