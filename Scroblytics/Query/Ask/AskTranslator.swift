import Foundation

/// Whether Ask can be offered, with an honest reason when it can't.
enum AskAvailability: Equatable, Sendable {
    case available
    case unavailable(String)

    static func current() -> AskAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return AskTranslator.availability }
        #endif
        return .unavailable("Ask needs macOS 26 or later.")
    }
}

enum AskError: LocalizedError {
    case unavailable(String)
    case notUnderstood
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let why): why
        case .notUnderstood: "I couldn’t turn that into a query. Try describing what you want to find, for example “artists I’ve played more than 100 times”."
        case .failed(let why): why
        }
    }
}

#if canImport(FoundationModels)
import FoundationModels

/// Sends a sentence to the language model and returns a validated interpretation. Two guided-generation
/// calls: which kind of thing is being asked for (a tiny prompt), then the query itself — with only THAT
/// kind's fields in the prompt, since the on-device model's context is 8,192 tokens. The model only ever
/// chooses from schemas generated out of `QueryFieldRegistry` (`AskSchema`) and its answer only reaches the
/// engine through `AskInterpreter`.
@available(macOS 26.0, *)
struct AskTranslator: Sendable, AskEngine {
    var displayName: String { provider == .onDevice ? "Apple on-device" : "Apple Private Cloud Compute" }
    /// Which model answers. The on-device model is the default; Private Cloud Compute (macOS 27) is here so the
    /// two can be compared on the same requests.
    enum Provider: String, Sendable { case onDevice, privateCloud }

    var provider: Provider = .onDevice
    let registry: QueryFieldRegistry

    /// Greedy decoding: the same sentence gives the same query (and the answer is the model's most likely one,
    /// not a random sample). The token cap stops a runaway answer at a few seconds instead of letting it fill the
    /// whole context window — the schema's bounds already make a real query far shorter than this.
    private static func options(maximumTokens: Int) -> GenerationOptions {
        GenerationOptions(sampling: .greedy, maximumResponseTokens: maximumTokens)
    }

    static var availability: AskAvailability {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available: return .available
        case .unavailable(.deviceNotEligible): return .unavailable("This Mac doesn’t support Apple Intelligence, which Ask uses.")
        case .unavailable(.appleIntelligenceNotEnabled): return .unavailable("Turn on Apple Intelligence in System Settings to use Ask.")
        case .unavailable(.modelNotReady): return .unavailable("Apple Intelligence is still getting ready — try Ask again in a little while.")
        case .unavailable: return .unavailable("Apple Intelligence isn’t available right now.")
        }
    }

    private func session(_ instructions: String) throws -> LanguageModelSession {
        switch provider {
        case .onDevice:
            return LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
        case .privateCloud:
            guard #available(macOS 27.0, *) else { throw AskError.unavailable("Private Cloud Compute needs macOS 27.") }
            return LanguageModelSession(model: PrivateCloudComputeLanguageModel(), instructions: instructions)
        }
    }

    /// Warms the model so the first real request is quicker (call when the user starts typing).
    func prewarm() {
        try? session(AskVocabulary.targetInstructions()).prewarm()
    }

    typealias Translation = AskTranslation

    func translate(_ request: String, context: AskContext = .none, now: Date = Date()) async throws -> AskTranslation {
        do {
            // Two small questions asked separately (and concurrently): what the request is about, and whether it wants an
            // order or a number of results.
            let introSession = try session(AskVocabulary.targetInstructions())
            let shapeSession = try session(AskVocabulary.shapeInstructions())
            async let introAnswer = introSession.respond(to: request, schema: AskSchema.intro(), includeSchemaInPrompt: false, options: Self.options(maximumTokens: 60))
            async let shapeAnswer = shapeSession.respond(to: request, schema: AskSchema.shape(), includeSchemaInPrompt: false, options: Self.options(maximumTokens: 30))
            let (introContent, shapeContent) = try await (introAnswer.content, shapeAnswer.content)
            let part = try JSONDecoder().decode(AskWire.IntroPart.self, from: Data(introContent.jsonString.utf8))
            let shape = try JSONDecoder().decode(AskWire.Shape.self, from: Data(shapeContent.jsonString.utf8))
            let intro = AskWire.Intro(target: part.target, scoped: part.scoped, absence: part.absence, tagged: part.tagged, ordered: shape.ordered, count: shape.count)
            // What fixed phrasings say ("top 25", "this year", "tagged X", "not loved") is read by code and wins over the model.
            let hints = AskPatterns.read(request, knownTags: context.knownTags, knownArtists: context.knownArtists)
            guard let target = hints.target ?? QueryTarget(rawValue: intro.target) else { throw AskError.notUnderstood }
            let ordered = hints.ordered ?? intro.ordered
            let count = hints.count ?? AskPatterns.confirmed(count: intro.count, in: request)
            let querySession = try session(AskVocabulary.queryInstructions(target: target, ordered: ordered, scoped: intro.scoped, absence: intro.absence, tagged: intro.tagged, registry: registry, now: now, context: context))
            let answer = try await querySession.respond(
                to: request, schema: AskSchema.query(target: target, ordered: ordered, scoped: intro.scoped, absence: intro.absence, registry: registry),
                includeSchemaInPrompt: false, options: Self.options(maximumTokens: 700))
            let json = answer.content.jsonString
            let wire = try JSONDecoder().decode(AskWire.Query.self, from: Data(json.utf8))
            let modelReading = AskInterpreter.interpret(wire, target: target, registry: registry, now: now, count: ordered ? count : nil, ordered: ordered, knownTags: context.knownTags)
            let interpretation = AskGuard.apply(AskPatterns.apply(hints, to: modelReading, target: target, registry: registry, request: request), request: request, registry: registry)
            return AskTranslation(target: target, interpretation: interpretation, raw: json, intro: introContent.jsonString + " " + shapeContent.jsonString, engine: displayName)
        } catch let error as AskError {
            throw error
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal: throw AskError.failed("The model declined that request. Try rewording it.")
            case .exceededContextWindowSize: throw AskError.failed("That request was too long or too complex for the model. Try a shorter, simpler one.")
            case .unsupportedLanguageOrLocale: throw AskError.failed("Ask doesn’t support that language yet.")
            default: throw AskError.failed("The model couldn’t answer that: \(error.localizedDescription)")
            }
        } catch {
            throw AskError.failed("The model’s answer couldn’t be used: \(error.localizedDescription)")
        }
    }
}
#endif
