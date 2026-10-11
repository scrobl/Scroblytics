import Foundation
import Security

/// What an Ask engine hands back, whichever model produced it. The interpretation has already been through
/// `AskInterpreter` — the one trust boundary — so nothing here is a raw model answer to execute.
struct AskTranslation: Sendable {
    let target: QueryTarget
    let interpretation: AskInterpretation
    /// The model's raw JSON, for diagnostics only — never executed.
    let raw: String
    /// What stage 1 of the on-device pipeline decided, for diagnostics ("" for engines with one call).
    let intro: String
    /// Who answered, for the review card ("Claude · claude-sonnet-5-5").
    var engine = ""
    /// Vague phrases the model turned into numbers ("a lot" → 50 plays), shown so the user can adjust them.
    var resolvedTerms: [AskResolvedTerm] = []
    var usage: AskUsage?
    /// Set when the request asks for NEW music similar to something (a Similar Sounds search) rather than a filter.
    var similar: AskSimilarIntent?
}

struct AskResolvedTerm: Sendable, Equatable, Hashable {
    let phrase: String
    let meaning: String
}

struct AskUsage: Sendable, Equatable {
    var inputTokens: Int?
    var outputTokens: Int?
    var cachedTokens: Int?
    var seconds: Double
}

/// Something that turns a sentence into a validated interpretation: the on-device model, or any hosted or local
/// model reached over HTTP. Engines differ only in WHERE the model runs; the schema, the vocabulary and the
/// validation are shared.
protocol AskEngine: Sendable {
    var displayName: String { get }
    func translate(_ request: String, context: AskContext, now: Date) async throws -> AskTranslation
}

/// Which engine answers.
enum AskEngineID: String, CaseIterable, Codable, Sendable, Identifiable {
    case onDevice, anthropic, openAI, google, ollama, openAICompatible

    var id: String { rawValue }

    var label: String {
        switch self {
        case .onDevice: "Apple on-device"
        case .anthropic: "Claude (Anthropic)"
        case .openAI: "OpenAI"
        case .google: "Google Gemini"
        case .ollama: "Ollama (local)"
        case .openAICompatible: "OpenAI-compatible server"
        }
    }

    /// Needs an API key (the compatible server's is optional).
    var usesKey: Bool { self == .anthropic || self == .openAI || self == .google || self == .openAICompatible }
    var keyIsOptional: Bool { self == .openAICompatible }
    var usesBaseURL: Bool { self == .ollama || self == .openAICompatible }
    /// Sends the sentence off the Mac.
    var isCloud: Bool { self == .anthropic || self == .openAI || self == .google }

    var defaultBaseURL: String {
        switch self {
        case .onDevice: ""
        case .anthropic: "https://api.anthropic.com"
        case .openAI: "https://api.openai.com"
        case .google: "https://generativelanguage.googleapis.com"
        case .ollama: "http://localhost:11434"
        case .openAICompatible: "http://localhost:1234"
        }
    }

    /// A starting model name — editable, and "Fetch models" asks the provider what it actually offers, because
    /// model names change faster than this app does.
    var defaultModel: String {
        switch self {
        case .onDevice: ""
        case .anthropic: "claude-sonnet-5-5"
        case .openAI: "gpt-6-luna"
        case .google: "gemini-2.5-flash"
        case .ollama, .openAICompatible: ""
        }
    }

    /// What the evaluation set (58 requests, `AskEval`) showed for this provider's models — measured, not assumed.
    var measuredNote: String? {
        switch self {
        case .anthropic: "Measured on 66 test requests: claude-sonnet-5-5 read 63 correctly (95%); claude-haiku-4-5-20251001 read 59 (89%) and costs less; the on-device model read about 55% (and can’t do “similar to” requests)."
        case .openAI: "Measured on 66 test requests: gpt-6-luna read 63 correctly (95%) and is the cheapest; gpt-6.1-sol read 62 (94%), slower and about 20× the price; gpt-4o read 61 (92%). Each request carries a prompt of about 10,000 tokens, so an account on OpenAI’s lowest rate-limit tier can hit its tokens-per-minute limit after a few questions in a minute."
        default: nil
        }
    }

    var privacyNote: String {
        switch self {
        case .onDevice: "Runs on this Mac. Nothing leaves it."
        case .ollama: "Runs on the server you point at (normally this Mac). Nothing leaves your network unless you point it elsewhere."
        case .openAICompatible: "Sent to the server you point at. If that is a hosted service, it receives what a cloud provider would."
        default: "Your sentence, the list of query fields, up to 60 of your tag names and the date your history begins are sent to \(label). No scrobbles or results are sent."
        }
    }
}

// MARK: - Settings (non-secret)

struct AskProviderConfig: Codable, Equatable, Sendable {
    var model: String
    var baseURL: String
}

struct AskSettings: Codable, Equatable, Sendable {
    var selected = AskEngineID.onDevice
    var providers: [String: AskProviderConfig] = [:]

    func config(for engine: AskEngineID) -> AskProviderConfig {
        let stored = providers[engine.rawValue]
        return AskProviderConfig(
            model: (stored?.model.isEmpty == false) ? stored!.model : engine.defaultModel,
            baseURL: (stored?.baseURL.isEmpty == false) ? stored!.baseURL : engine.defaultBaseURL
        )
    }

    mutating func set(_ config: AskProviderConfig, for engine: AskEngineID) { providers[engine.rawValue] = config }
}

/// Where the choice of engine, model names and server addresses live. Never keys — those are in the Keychain.
enum AskSettingsStore {
    static let key = "ask.settings.v1"

    static func load() -> AskSettings {
        guard let data = UserDefaults.standard.data(forKey: key), let settings = try? JSONDecoder().decode(AskSettings.self, from: data) else { return AskSettings() }
        return settings
    }

    static func save(_ settings: AskSettings) {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: key) }
    }
}

// MARK: - Keys

/// One Keychain item per provider, the same shape as the Last.fm credentials. A key is never written anywhere else:
/// not to the settings above, a log line, a backup, or a URL.
enum AskKeychain {
    private static let service = AppIdentity.keychainService("ask")

    private static func query(_ engine: AskEngineID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: engine.rawValue]
    }

    static func key(for engine: AskEngineID) -> String? {
        var q = query(engine)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return key?.isEmpty == false ? key : nil
    }

    static func hasKey(for engine: AskEngineID) -> Bool { key(for: engine) != nil }

    static func setKey(_ key: String, for engine: AskEngineID) throws {
        let data = Data(key.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let status = SecItemUpdate(query(engine) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(engine)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw AskKeychainError.write(addStatus) }
        } else if status != errSecSuccess {
            throw AskKeychainError.write(status)
        }
    }

    static func removeKey(for engine: AskEngineID) { SecItemDelete(query(engine) as CFDictionary) }
}

enum AskKeychainError: LocalizedError {
    case write(OSStatus)
    var errorDescription: String? {
        switch self {
        case .write(let status): "The key couldn’t be saved to the Keychain (error \(status))."
        }
    }
}

// MARK: - Choosing an engine

enum AskEngines {
    /// The engine the user picked, or why there isn't one.
    static func resolve(registry: QueryFieldRegistry, settings: AskSettings = AskSettingsStore.load()) -> (engine: AskEngine?, availability: AskAvailability) {
        switch settings.selected {
        case .onDevice:
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                let availability = AskTranslator.availability
                return (availability == .available ? AskTranslator(registry: registry) : nil, availability)
            }
            #endif
            return (nil, .unavailable("The on-device model needs macOS 26 or later. Choose another engine in Settings › Ask."))
        default:
            let config = settings.config(for: settings.selected)
            // Offline mode blocks the cloud engines; a server on this Mac (Ollama, a local server) keeps working.
            if ConnectivityGate.isOffline, settings.selected.isCloud {
                return (nil, .unavailable("Offline mode is on, so \(settings.selected.label) can’t be reached. Switch to Apple on-device or a local server in Settings › Ask, or go online."))
            }
            if settings.selected.usesKey, !settings.selected.keyIsOptional, !AskKeychain.hasKey(for: settings.selected) {
                return (nil, .unavailable("Add your \(settings.selected.label) API key in Settings › Ask."))
            }
            if config.model.isEmpty {
                return (nil, .unavailable("Choose a model for \(settings.selected.label) in Settings › Ask."))
            }
            let client = AskLLMClients.make(settings.selected, config: config, key: AskKeychain.key(for: settings.selected))
            return (AskModelEngine(client: client, registry: registry, label: "\(settings.selected.label) · \(config.model)"), .available)
        }
    }

    /// Whether Ask can be offered at all right now.
    static func availability(settings: AskSettings = AskSettingsStore.load()) -> AskAvailability {
        resolve(registry: .standard, settings: settings).availability
    }
}
