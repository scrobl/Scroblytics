import Foundation
import Observation

struct AskQueryRequest: Identifiable, Sendable {
    enum Action: Sendable {
        case run
        case edit
        case save
    }

    let id = UUID()
    let spec: QuerySpec
    let action: Action
    /// Set when another tab's chart opened this query, so Query can offer the way back.
    var cameFrom: DetailPredecessor?
    /// A name to default the Save As sheet to, if the user saves this — e.g. a Tool's own name
    /// ("Most Recent, Most Often (from Tool)"). Never saves anything by itself.
    var suggestedName: String?
}

/// The Ask box's state: what was typed, whether the model is working, and — once it answers — the
/// interpretation waiting for the user's confirmation. Nothing here runs a query; confirming hands the
/// interpreted `QuerySpec` to the same builder model every manually built query goes through.
@MainActor
@Observable
final class AskModel {
    struct Review: Identifiable {
        let id = UUID()
        let request: String
        let target: QueryTarget
        let interpretation: AskInterpretation
        let chips: [AskChip]
        /// Who answered, and how it read vague phrases — shown so the answer can be judged and adjusted.
        var engine = ""
        var resolvedTerms: [AskResolvedTerm] = []
        var usage: AskUsage?
        /// A "similar to X" request, with the library item it names (nil when the library has no such thing).
        var similar: Similar?

        struct Similar {
            let intent: AskSimilarIntent
            let seed: SimilarSeed?
        }
    }

    enum State {
        case idle
        case translating
        case review(Review)
        case failed(String)
    }

    var text = ""
    private(set) var state: State = .idle
    /// Whether the engine chosen in Settings › Ask can answer right now (re-read each time: the choice can change).
    var availability: AskAvailability { AskEngines.availability() }
    private var task: Task<Void, Never>?

    var isBusy: Bool { if case .translating = state { true } else { false } }

    func prewarm(registry: QueryFieldRegistry) {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), AskSettingsStore.load().selected == .onDevice, availability == .available { AskTranslator(registry: registry).prewarm() }
        #endif
    }

    func submit(registry: QueryFieldRegistry, context: AskContext) {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !isBusy else { return }
        let (engine, availability) = AskEngines.resolve(registry: registry)
        guard let engine else {
            if case .unavailable(let why) = availability { state = .failed(why) }
            return
        }
        state = .translating
        task?.cancel()
        task = Task { [weak self] in
            do {
                let translation = try await engine.translate(request, context: context, now: Date())
                var similar: Review.Similar?
                if let intent = translation.similar {
                    let seed: SimilarSeed?
                    if let container = context.container { seed = await AskSimilarResolver.resolve(intent, container: container) } else { seed = nil }
                    similar = Review.Similar(intent: intent, seed: seed)
                }
                guard !Task.isCancelled, let self else { return }
                self.state = .review(Review(
                    request: request, target: translation.target, interpretation: translation.interpretation,
                    chips: AskChips.describe(translation.interpretation.spec, registry: registry),
                    engine: translation.engine, resolvedTerms: translation.resolvedTerms, usage: translation.usage, similar: similar
                ))
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.state = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
        }
    }

    /// Closes the answer card but keeps what was typed, so a sentence dismissed by mistake can be edited.
    func discard() {
        task?.cancel()
        state = .idle
    }

    /// The question was acted on (run, opened in the builder, saved, or handed to Similar Sounds): close the card AND empty the
    /// box, so the next time it's used the example sentence shows instead of the old question.
    func complete() {
        discard()
        text = ""
    }
}
