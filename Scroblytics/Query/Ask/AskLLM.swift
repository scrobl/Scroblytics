import Foundation

// MARK: - Errors and replies

/// Why a model call failed, in terms the user can act on. A failure is never retried silently.
enum AskLLMError: LocalizedError, Sendable {
    case missingKey
    case authentication(String)
    case rateLimited(String)
    case unreachable(String)
    case rejected(String)
    case server(Int, String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingKey: "No API key is saved for this provider. Add one in Settings › Ask."
        case .authentication(let who): "\(who) rejected the API key. Check it in Settings › Ask."
        case .rateLimited(let who): "\(who) is rate-limiting requests right now. Try again in a moment."
        case .unreachable(let who): "Couldn’t reach \(who). Check your connection (or that the server is running), or use “Edit filters instead”."
        case .rejected(let message): "The model service rejected the request: \(message)"
        case .server(let code, let message): "The model service had a problem (\(code)). \(message)"
        case .badResponse(let message): "The model’s answer couldn’t be used: \(message)"
        }
    }
}

struct AskLLMReply: Sendable {
    /// The model's answer, a JSON object.
    let json: Data
    var inputTokens: Int?
    var outputTokens: Int?
    var cachedTokens: Int?
}

/// A portable JSON Schema (as JSON bytes, so it is `Sendable`), generated from the registry once per call.
struct AskJSONSchema: Sendable {
    let data: Data

    func object() -> [String: Any] {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }
}

/// One model service. The request and response shapes are pure functions (`request`/`parse`) so they can be checked
/// against a mock server without a key or a network.
protocol AskLLMClient: Sendable {
    var providerName: String { get }
    func complete(system: String, user: String, schema: AskJSONSchema) async throws -> AskLLMReply
    func listModels() async throws -> [String]
}

enum AskLLMClients {
    static func make(_ engine: AskEngineID, config: AskProviderConfig, key: String?) -> AskLLMClient {
        switch engine {
        case .anthropic: AnthropicClient(baseURL: config.baseURL, model: config.model, key: key)
        case .openAI: OpenAIClient(baseURL: config.baseURL, model: config.model, key: key, providerName: "OpenAI", fallsBack: false)
        case .openAICompatible: OpenAIClient(baseURL: config.baseURL, model: config.model, key: key, providerName: "the server", fallsBack: true)
        case .google: GeminiClient(baseURL: config.baseURL, model: config.model, key: key)
        case .ollama: OllamaClient(baseURL: config.baseURL, model: config.model)
        case .onDevice: OllamaClient(baseURL: config.baseURL, model: config.model) // never used: on-device has no HTTP client
        }
    }
}

// MARK: - HTTP

enum AskHTTP {
    /// Calls are bounded: a hung server is an error in a minute, not a spinner forever.
    static let timeout: TimeInterval = 90

    static func send(_ request: URLRequest, provider: String) async throws -> Data {
        var request = request
        request.timeoutInterval = timeout
        // Cloud providers are blocked while offline; a server on this Mac (Ollama, a local server) is not.
        try ConnectivityGate.check(host: request.url?.host)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
            ConnectivityHub.reportSuccess()
        } catch {
            ConnectivityHub.report(error, host: request.url?.host, source: "Ask")
            throw AskLLMError.unreachable(provider)
        }
        guard let http = response as? HTTPURLResponse else { throw AskLLMError.badResponse("not an HTTP response") }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw AskLLMError.authentication(provider)
        case 429: throw AskLLMError.rateLimited(provider)
        case 400..<500: throw AskLLMError.rejected(errorMessage(in: data) ?? "HTTP \(http.statusCode)")
        default: throw AskLLMError.server(http.statusCode, errorMessage(in: data) ?? "")
        }
    }

    /// The provider's own explanation, when the body has one — never anything from the request (which holds the key).
    static func errorMessage(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let dict = object as? [String: Any] {
            if let error = dict["error"] as? [String: Any], let message = error["message"] as? String { return message }
            if let error = dict["error"] as? String { return error }
            if let message = dict["message"] as? String { return message }
        }
        return nil
    }

    static func url(_ base: String, _ path: String) throws -> URL {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed + path), url.scheme != nil else { throw AskLLMError.rejected("“\(base)” isn’t a valid address.") }
        return url
    }

    static func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// A model asked for JSON sometimes wraps it in a code fence or a sentence; take the outermost object.
    static func extractObject(from text: String) -> Data? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            s = s.drop(while: { $0 != "\n" }).dropFirst().description
            if let end = s.range(of: "```", options: .backwards) { s = String(s[..<end.lowerBound]) }
        }
        guard let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}"), start < end else { return nil }
        let candidate = String(s[start...end])
        guard let data = candidate.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { return nil }
        return data
    }
}

// MARK: - Anthropic

/// Messages API with structured outputs: `output_config.format` of type `json_schema` makes the reply a JSON object that
/// fits our schema. (The newest models — Sonnet 5.5, Opus 5.5 and later — reject a FORCED tool call, the older way to get
/// the same guarantee; structured outputs works on all of them, back to Haiku 4.5.)
struct AnthropicClient: AskLLMClient {
    let baseURL: String
    let model: String
    let key: String?
    var providerName: String { "Anthropic" }

    func request(system: String, user: String, schema: AskJSONSchema) throws -> URLRequest {
        guard let key else { throw AskLLMError.missingKey }
        var request = URLRequest(url: try AskHTTP.url(baseURL, "/v1/messages"))
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            // The long, unchanging vocabulary is cached, so repeat questions cost a fraction of the first.
            "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
            "output_config": ["format": ["type": "json_schema", "schema": schema.object()]],
            "messages": [["role": "user", "content": user]],
        ]
        request.httpBody = try AskHTTP.json(body)
        return request
    }

    func parse(_ data: Data) throws -> AskLLMReply {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let content = root["content"] as? [[String: Any]] else {
            throw AskLLMError.badResponse("no content in the response")
        }
        switch root["stop_reason"] as? String {
        case "refusal": throw AskLLMError.badResponse("the model declined to answer")
        case "max_tokens": throw AskLLMError.badResponse("the answer was cut off")
        default: break
        }
        guard let text = content.compactMap({ ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }).first, let json = AskHTTP.extractObject(from: text) else {
            throw AskLLMError.badResponse("the answer wasn’t a JSON object")
        }
        let usage = root["usage"] as? [String: Any]
        return AskLLMReply(json: json, inputTokens: usage?["input_tokens"] as? Int, outputTokens: usage?["output_tokens"] as? Int, cachedTokens: usage?["cache_read_input_tokens"] as? Int)
    }

    func complete(system: String, user: String, schema: AskJSONSchema) async throws -> AskLLMReply {
        try parse(try await AskHTTP.send(try request(system: system, user: user, schema: schema), provider: providerName))
    }

    func listModels() async throws -> [String] {
        guard let key else { throw AskLLMError.missingKey }
        var request = URLRequest(url: try AskHTTP.url(baseURL, "/v1/models?limit=100"))
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let data = try await AskHTTP.send(request, provider: providerName)
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ((root?["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
    }
}

// MARK: - OpenAI and OpenAI-compatible

/// Chat Completions with `response_format: json_schema` (strict). For a compatible server that doesn't support that,
/// steps down to `json_object` and then to plain text (the prompt always spells the JSON out), so a local model
/// that ignores structured output still answers.
struct OpenAIClient: AskLLMClient {
    let baseURL: String
    let model: String
    let key: String?
    let providerName: String
    let fallsBack: Bool

    enum Format { case jsonSchema, jsonObject, plain }

    func endpoint() throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return try AskHTTP.url(trimmed, trimmed.hasSuffix("/v1") ? "/chat/completions" : "/v1/chat/completions")
    }

    func request(system: String, user: String, schema: AskJSONSchema, format: Format) throws -> URLRequest {
        var request = URLRequest(url: try endpoint())
        request.httpMethod = "POST"
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ]
        switch format {
        case .jsonSchema: body["response_format"] = ["type": "json_schema", "json_schema": ["name": "ask_query", "strict": true, "schema": schema.object()]]
        case .jsonObject: body["response_format"] = ["type": "json_object"]
        case .plain: break
        }
        request.httpBody = try AskHTTP.json(body)
        return request
    }

    func parse(_ data: Data) throws -> AskLLMReply {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (root["choices"] as? [[String: Any]])?.first, let message = choice["message"] as? [String: Any] else {
            throw AskLLMError.badResponse("no choices in the response")
        }
        if let refusal = message["refusal"] as? String, !refusal.isEmpty { throw AskLLMError.badResponse("the model declined: \(refusal)") }
        guard let text = message["content"] as? String, let json = AskHTTP.extractObject(from: text) else {
            throw AskLLMError.badResponse("the answer wasn’t a JSON object")
        }
        let usage = root["usage"] as? [String: Any]
        let details = usage?["prompt_tokens_details"] as? [String: Any]
        return AskLLMReply(json: json, inputTokens: usage?["prompt_tokens"] as? Int, outputTokens: usage?["completion_tokens"] as? Int, cachedTokens: details?["cached_tokens"] as? Int)
    }

    func complete(system: String, user: String, schema: AskJSONSchema) async throws -> AskLLMReply {
        if !fallsBack && key == nil { throw AskLLMError.missingKey }
        var lastError: Error = AskLLMError.badResponse("no answer")
        for format in fallsBack ? [Format.jsonSchema, .jsonObject, .plain] : [.jsonSchema] {
            do {
                return try parse(try await AskHTTP.send(try request(system: system, user: user, schema: schema, format: format), provider: providerName))
            } catch AskLLMError.rejected(let message) where fallsBack && format != .plain {
                lastError = AskLLMError.rejected(message)   // the server doesn't take this response_format: try the next
            }
        }
        throw lastError
    }

    func listModels() async throws -> [String] {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var request = URLRequest(url: try AskHTTP.url(trimmed, trimmed.hasSuffix("/v1") ? "/models" : "/v1/models"))
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let data = try await AskHTTP.send(request, provider: providerName)
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ((root?["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }.sorted()
    }
}

// MARK: - Google Gemini

/// `generateContent` with `responseMimeType: application/json` and a `responseSchema`. The key travels in a header,
/// not the URL, so it can't end up in a log of requested addresses.
struct GeminiClient: AskLLMClient {
    let baseURL: String
    let model: String
    let key: String?
    var providerName: String { "Google" }

    func request(system: String, user: String, schema: AskJSONSchema) throws -> URLRequest {
        guard let key else { throw AskLLMError.missingKey }
        var request = URLRequest(url: try AskHTTP.url(baseURL, "/v1beta/models/\(model):generateContent"))
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": user]]]],
            "generationConfig": ["responseMimeType": "application/json", "responseSchema": AskSchemaAdapter.gemini(schema.object()), "temperature": 0],
        ]
        request.httpBody = try AskHTTP.json(body)
        return request
    }

    func parse(_ data: Data) throws -> AskLLMReply {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidate = (root["candidates"] as? [[String: Any]])?.first,
              let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]],
              let text = parts.compactMap({ $0["text"] as? String }).first, let json = AskHTTP.extractObject(from: text) else {
            throw AskLLMError.badResponse("the answer wasn’t a JSON object")
        }
        let usage = root["usageMetadata"] as? [String: Any]
        return AskLLMReply(json: json, inputTokens: usage?["promptTokenCount"] as? Int, outputTokens: usage?["candidatesTokenCount"] as? Int, cachedTokens: usage?["cachedContentTokenCount"] as? Int)
    }

    func complete(system: String, user: String, schema: AskJSONSchema) async throws -> AskLLMReply {
        try parse(try await AskHTTP.send(try request(system: system, user: user, schema: schema), provider: providerName))
    }

    func listModels() async throws -> [String] {
        guard let key else { throw AskLLMError.missingKey }
        var request = URLRequest(url: try AskHTTP.url(baseURL, "/v1beta/models?pageSize=100"))
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        let data = try await AskHTTP.send(request, provider: providerName)
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ((root?["models"] as? [[String: Any]]) ?? [])
            .filter { (($0["supportedGenerationMethods"] as? [String]) ?? []).contains("generateContent") }
            .compactMap { ($0["name"] as? String)?.replacingOccurrences(of: "models/", with: "") }
    }
}

// MARK: - Ollama

/// Ollama's native chat endpoint, with the schema as `format` (structured outputs). `num_ctx` is raised because
/// Ollama's default context (a few thousand tokens) would silently truncate a prompt this long.
struct OllamaClient: AskLLMClient {
    let baseURL: String
    let model: String
    var providerName: String { "Ollama" }

    static let contextTokens = 16384

    /// Appended to the shared prompt: the schema Ollama gets doesn't require every key (see `AskSchemaAdapter.ollama`).
    static let omitNote = "\n\nWrite only the keys the request needs; leave out every other key (no zeros, empty strings or placeholder dates)."

    func request(system: String, user: String, schema: AskJSONSchema) throws -> URLRequest {
        var request = URLRequest(url: try AskHTTP.url(baseURL, "/api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model, "stream": false,
            "messages": [["role": "system", "content": system + Self.omitNote], ["role": "user", "content": user]],
            "format": AskSchemaAdapter.ollama(schema.object()),
            "options": ["temperature": 0, "num_ctx": Self.contextTokens],
        ]
        request.httpBody = try AskHTTP.json(body)
        return request
    }

    func parse(_ data: Data) throws -> AskLLMReply {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let message = root["message"] as? [String: Any],
              let text = message["content"] as? String, let json = AskHTTP.extractObject(from: text) else {
            throw AskLLMError.badResponse("the answer wasn’t a JSON object")
        }
        return AskLLMReply(json: json, inputTokens: root["prompt_eval_count"] as? Int, outputTokens: root["eval_count"] as? Int, cachedTokens: nil)
    }

    func complete(system: String, user: String, schema: AskJSONSchema) async throws -> AskLLMReply {
        try parse(try await AskHTTP.send(try request(system: system, user: user, schema: schema), provider: providerName))
    }

    func listModels() async throws -> [String] {
        let data = try await AskHTTP.send(URLRequest(url: try AskHTTP.url(baseURL, "/api/tags")), provider: providerName)
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ((root?["models"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }.sorted()
    }
}

// MARK: - The schema

/// The shape a model answers in, generated from the registry. One portable subset — objects, arrays, strings, numbers,
/// booleans, enums, and "or null" for anything optional, with every key listed as required (what OpenAI's strict mode
/// demands, harmless elsewhere) — adapted per provider where a provider differs. It is deliberately looser than the
/// on-device schema: whatever a model writes is re-checked by `AskInterpreter`, so a looser schema costs accuracy at
/// worst, never safety.
enum AskPortableSchema {
    static func build(registry: QueryFieldRegistry) -> AskJSONSchema {
        let fieldIDs = Array(Set(QueryTarget.allCases.flatMap { registry.modelAskFields(for: $0).map(\.id) })).sorted()
        let operators = QueryOperator.allCases.map(\.rawValue)
        let units = QueryScope.Unit.allCases.map(\.rawValue)

        func nullable(_ schema: [String: Any]) -> [String: Any] {
            var copy = schema
            if let type = schema["type"] as? String { copy["type"] = [type, "null"] }
            return copy
        }
        func object(_ properties: [String: [String: Any]], description: String? = nil) -> [String: Any] {
            var o: [String: Any] = ["type": "object", "properties": properties, "required": properties.keys.sorted(), "additionalProperties": false]
            if let description { o["description"] = description }
            return o
        }
        let number: [String: Any] = ["type": "number"]
        let integer: [String: Any] = ["type": "integer"]
        let string: [String: Any] = ["type": "string"]

        // Anthropic allows at most 16 "or null" parameters in a schema, so a period's fields are never null: 0, "none" or ""
        // mean "not used" (read back as absent by `AskModelWire`).
        let scope = object([
            "kind": ["type": "string", "enum": QueryScope.Kind.allCases.map(\.rawValue)],
            "days": ["type": "integer", "description": "trailing only: how many days; 0 otherwise"],
            "unit": ["type": "string", "enum": units + ["none"], "description": "calendar only; none otherwise"],
            "from": ["type": "string", "description": "absolute only: yyyy-MM-dd; empty otherwise"],
            "to": ["type": "string", "description": "absolute only: yyyy-MM-dd; empty otherwise"],
            "shiftCount": ["type": "integer", "description": "how many shiftUnits to move the whole period back; 0 for none"],
            "shiftUnit": ["type": "string", "enum": units + ["none"]],
        ], description: "A period. trailing needs days; calendar needs unit; absolute needs from/to as yyyy-MM-dd.")
        let shift = object(["count": integer, "unit": ["type": "string", "enum": units]], description: "How long before the recent period to compare with.")
        let parameter = object(["id": string, "value": string])

        let condition = object([
            "field": ["type": "string", "enum": fieldIDs], "op": ["type": "string", "enum": operators],
            "value": nullable(number), "valueTo": nullable(number), "text": nullable(string),
            "date": nullable(string), "dateTo": nullable(string),
            "tags": ["type": "array", "items": string, "description": "tag names for a tag operator; empty otherwise"],
            "parameters": ["type": "array", "items": parameter, "description": "field settings, only where the field lists some; empty otherwise"],
            "scope": ["anyOf": [scope, ["type": "null"]]],
            "comparedAgo": ["anyOf": [shift, ["type": "null"]]],
        ], description: "One condition on one field. Fill only the operand keys the operator needs; the rest are null (or empty for lists).")
        let sort = object([
            "field": ["type": "string", "enum": fieldIDs], "direction": ["type": "string", "enum": ["ascending", "descending"]],
            "parameters": ["type": "array", "items": parameter],
            "scope": ["anyOf": [scope, ["type": "null"]]],
            "comparedAgo": ["anyOf": [shift, ["type": "null"]]],
        ])
        let term = object(["phrase": string, "meaning": string])
        let root = object([
            "target": ["type": "string", "enum": QueryTarget.allCases.map(\.rawValue)],
            "groups": ["type": "array", "items": ["type": "array", "items": condition],
                       "description": "Alternatives (OR); each is a list of conditions that must all hold (AND)."],
            "sorts": ["type": "array", "items": sort],
            "limit": nullable(integer),
            "perArtist": nullable(integer),
            "perAlbum": nullable(integer),
            "perReleaseYear": nullable(integer),
            // The plays to count, only those made at certain times or in certain weather: flat keys, empty lists / null when none.
            "playWeekdays": ["type": "array", "items": ["type": "string", "enum": QueryPlayFilter.dayNames], "description": "only plays made on these days of the week; empty for any day"],
            "playMonths": ["type": "array", "items": integer, "description": "only plays made in these calendar months (1 = January … 12 = December), in any year; empty for any month"],
            "playFromHour": nullable(integer),
            "playToHour": nullable(integer),
            "playWeather": ["type": "array", "items": ["type": "string", "enum": WeatherCondition.allCases.map(\.rawValue)], "description": "only plays made in this weather; empty for any"],
            "playTemperature": ["type": "array", "items": ["type": "string", "enum": TemperatureBand.allCases.map(\.rawValue)], "description": "only plays made when it was this warm for the person's place; empty for any"],
            "playCity": ["type": "array", "items": string, "description": "only plays made in these cities, as the person wrote them (\"Munich\"); empty for anywhere"],
            "unsupported": ["type": "array", "items": string, "description": "Parts of the request no field can express, in plain words."],
            "resolvedTerms": ["type": "array", "items": term, "description": "Vague phrases turned into numbers, e.g. a lot → at least 50 plays."],
            // New music similar to something (Similar Sounds): flat keys, not a nested object, to keep the schema small
            // (Anthropic refuses a structured-output schema whose compiled grammar is too large).
            "similarSeed": ["type": "string", "description": "ONLY for a request for NEW music similar to something the person already has: the artist, album or song name as given. Empty string otherwise."],
            "similarKind": ["type": "string", "enum": ["track", "artist", "album", "unknown", "none"]],
            "similarArtist": ["type": "string", "description": "an artist named to tell the similar seed apart; empty if none"],
            "similarLimit": ["type": "integer", "description": "how many similar tracks were asked for; 0 if not said"],
        ])
        return AskJSONSchema(data: (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])) ?? Data())
    }
}

/// Per-provider changes to the portable schema.
enum AskSchemaAdapter {
    /// Gemini's `responseSchema` is an OpenAPI-style subset: upper-case type names, `nullable` instead of type unions or
    /// `anyOf` with null, and no `additionalProperties`.
    static func gemini(_ node: [String: Any]) -> [String: Any] {
        convert(node, upperCaseTypes: true, nullKeyword: "nullable", keepAdditional: false)
    }

    /// Ollama turns the schema into a grammar; plain `anyOf` with null is the form its structured outputs document.
    static func ollama(_ node: [String: Any]) -> [String: Any] {
        relaxRequired(convert(node, upperCaseTypes: false, nullKeyword: "anyOf", keepAdditional: true))
    }

    /// A local model told to write every key fills the ones it has no use for with zeros and made-up dates ("compare with
    /// 0 days earlier", a date range on a name), and spends most of its time writing them. The schema Ollama gets leaves a
    /// key out when it isn't needed: only what the query can't exist without is required. Cloud providers keep the strict
    /// every-key schema (some require it). The reader (`AskModelWire`) already treats a missing key as none.
    private static func relaxRequired(_ node: [String: Any]) -> [String: Any] {
        var dict = node
        if let properties = dict["properties"] as? [String: Any] {
            let keys = Set(properties.keys)
            if keys.contains("groups") { dict["required"] = ["target", "groups"].filter(keys.contains) }
            else if keys.contains("field"), keys.contains("op") { dict["required"] = ["field", "op"] }
            else if keys.contains("field"), keys.contains("direction") { dict["required"] = ["field", "direction"] }
            else if keys.contains("kind") { dict["required"] = ["kind"] }
            dict["properties"] = properties.mapValues { value in (value as? [String: Any]).map(relaxRequired) ?? value }
        }
        if let items = dict["items"] as? [String: Any] { dict["items"] = relaxRequired(items) }
        if let anyOf = dict["anyOf"] as? [[String: Any]] { dict["anyOf"] = anyOf.map(relaxRequired) }
        return dict
    }

    private static func convert(_ node: Any, upperCaseTypes: Bool, nullKeyword: String, keepAdditional: Bool) -> [String: Any] {
        guard var dict = node as? [String: Any] else { return [:] }
        func recurse(_ any: Any) -> [String: Any] { convert(any, upperCaseTypes: upperCaseTypes, nullKeyword: nullKeyword, keepAdditional: keepAdditional) }

        // anyOf [X, null] → X (+ nullable) for Gemini.
        if let anyOf = dict["anyOf"] as? [[String: Any]], anyOf.count == 2, let real = anyOf.first(where: { ($0["type"] as? String) != "null" }),
           anyOf.contains(where: { ($0["type"] as? String) == "null" }), nullKeyword == "nullable" {
            var converted = recurse(real)
            converted["nullable"] = true
            if let d = dict["description"] { converted["description"] = d }
            return converted
        }
        if let types = dict["type"] as? [String] {
            let real = types.first { $0 != "null" } ?? "string"
            let isNullable = types.contains("null")
            dict["type"] = real
            if isNullable {
                if nullKeyword == "nullable" {
                    dict["nullable"] = true
                    if var values = dict["enum"] as? [Any] { values.removeAll { $0 is NSNull }; dict["enum"] = values }
                } else {
                    var inner = dict
                    inner.removeValue(forKey: "description")
                    if var values = inner["enum"] as? [Any] { values.removeAll { $0 is NSNull }; inner["enum"] = values }
                    return ["anyOf": [recurse(inner), ["type": "null"]]]
                }
            }
        }
        if !keepAdditional { dict.removeValue(forKey: "additionalProperties") }
        if let type = dict["type"] as? String, upperCaseTypes { dict["type"] = type.uppercased() }
        if let properties = dict["properties"] as? [String: Any] { dict["properties"] = properties.mapValues { recurse($0) } }
        if let items = dict["items"] { dict["items"] = recurse(items) }
        if let anyOf = dict["anyOf"] as? [[String: Any]] { dict["anyOf"] = anyOf.map { recurse($0) } }
        if upperCaseTypes, dict["required"] != nil { /* keep */ }
        return dict
    }
}
