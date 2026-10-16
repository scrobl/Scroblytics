import Foundation

/// One engine for every hosted or local model: build the shared prompt and schema, make ONE structured call through an
/// `AskLLMClient`, read the answer leniently, and hand it to `AskInterpreter` — the same trust boundary the on-device
/// path uses. Nothing a model writes reaches the query engine except through that.
struct AskModelEngine: AskEngine {
    let client: AskLLMClient
    let registry: QueryFieldRegistry
    let label: String
    var displayName: String { label }

    static let maxRequestCharacters = 2000

    func translate(_ request: String, context: AskContext, now: Date) async throws -> AskTranslation {
        let started = Date()
        let text = String(request.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxRequestCharacters))
        guard !text.isEmpty else { throw AskError.notUnderstood }
        let reply = try await client.complete(
            system: AskPrompt.system(registry: registry, context: context, now: now),
            user: text, schema: AskPortableSchema.build(registry: registry)
        )
        return try Self.read(reply, request: text, registry: registry, context: context, now: now, engine: label, seconds: Date().timeIntervalSince(started))
    }

    /// The pure half: a model's JSON → a validated interpretation. Separate so tests can hand it any answer, good or bad.
    static func read(_ reply: AskLLMReply, request: String? = nil, registry: QueryFieldRegistry, context: AskContext, now: Date, engine: String, seconds: Double) throws -> AskTranslation {
        let wire: AskModelWire
        do { wire = try JSONDecoder().decode(AskModelWire.self, from: reply.json) } catch {
            throw AskLLMError.badResponse("the answer didn’t match the query shape")
        }
        guard let target = QueryTarget(rawValue: wire.target.lowercased()) else { throw AskError.notUnderstood }
        var query = wire.query
        // A diversity cap the request states in so many words is applied even when the model left it null (and wrote
        // the request into "unsupported" instead); a note that only restates a cap the app supports is removed.
        let stated = request.map { AskPatterns.groupLimit(in: $0) } ?? AskPatterns.Caps()
        // The other way round: a smaller model sets caps nobody asked for ("my most played song" → 1 per artist, per album, per
        // year). Caps the model chose count only when the request has diversity wording at all.
        if let request, !AskPatterns.mentionsDiversity(request) {
            query.perArtist = nil; query.perAlbum = nil; query.perReleaseYear = nil
        }
        query.perArtist = query.perArtist ?? stated.perArtist
        query.perAlbum = query.perAlbum ?? stated.perAlbum
        query.perReleaseYear = query.perReleaseYear ?? stated.perReleaseYear
        let caps = AskPatterns.Caps(perArtist: query.perArtist, perAlbum: query.perAlbum, perReleaseYear: query.perReleaseYear)
        if !caps.isEmpty { query.unsupported = query.unsupported?.filter { !AskPatterns.restatesCap($0, caps: caps) } }
        // A result count the request states outright ("top 50 tracks", "10 most recently played") is applied when the model left
        // the limit out; a model given leave to omit keys omits it too often. Only that closed wording counts, never a guess.
        if let request, query.limit == nil, wire.similar == nil {
            if let stated = AskPatterns.read(request, knownTags: nil).count, stated >= 1 { query.limit = stated }
            else if AskPatterns.asksForOne(request) { query.limit = 1 }
        }
        // A number of results with no stated order means "the top": most played first.
        let ordered = query.limit != nil && (query.sorts ?? []).isEmpty
        var interpretation = AskInterpreter.interpret(
            query, target: target, registry: registry, now: now, count: nil, ordered: ordered, knownTags: context.knownTags
        )
        // "find 25 songs similar to X": the number is the person's, whatever default an omitted key became.
        var similar = wire.similar
        if let request, let intent = similar, let stated = AskPatterns.similarCount(in: request) {
            similar = AskSimilarIntent(seedText: intent.seedText, kind: intent.kind, artistHint: intent.artistHint, limit: stated)
        }
        var resolvedTerms = wire.resolvedTerms.filter { !$0.phrase.isEmpty && !$0.meaning.isEmpty }
        // "songs by <an artist in the library>" with no artist condition in the answer: the model wrote the name somewhere else
        // (or nowhere). The name is the person's own, matched against the library's real artists, and the filter is stated.
        if let request, target != .artist, let known = context.knownArtists,
           !interpretation.spec.groups.contains(where: { $0.contains { $0.field.id == "artist" } }),
           let artist = AskPatterns.namedArtist(in: request, knownArtists: known) {
            let condition = QueryCondition("artist", .textIs, [.text(artist)])
            if interpretation.spec.groups.isEmpty {
                interpretation.spec.groups = [[condition]]
            } else {
                interpretation.spec.groups = interpretation.spec.groups.map { [condition] + $0 }
            }
            interpretation.spec.columns = AskInterpreter.columns(for: interpretation.spec, target: target, registry: registry)
            resolvedTerms.append(AskResolvedTerm(phrase: "by \(artist)", meaning: "the artist is \(artist)"))
        }
        return AskTranslation(
            target: target, interpretation: interpretation, raw: String(data: reply.json, encoding: .utf8) ?? "", intro: "",
            engine: engine, resolvedTerms: resolvedTerms,
            usage: AskUsage(inputTokens: reply.inputTokens, outputTokens: reply.outputTokens, cachedTokens: reply.cachedTokens, seconds: seconds),
            similar: similar
        )
    }
}

/// A model's answer as it actually arrives: nulls for unused keys, numbers sometimes as strings, parameters as a list of
/// pairs (a free-form map isn't expressible in a strict schema). Read leniently, then converted to `AskWire.Query`.
struct AskModelWire: Decodable {
    let target: String
    let query: AskWire.Query
    let resolvedTerms: [AskResolvedTerm]
    let similar: AskSimilarIntent?

    private struct Pair: Decodable { let id: String; let value: String }
    private struct Cond: Decodable {
        let field: String
        let op: String
        let value: Lenient?
        let valueTo: Lenient?
        let text: String?
        let date: String?
        let dateTo: String?
        let tags: [String]?
        let parameters: [Pair]?
        let scope: Scope?
        let comparedAgo: AskWire.Shift?
    }
    private struct Sort: Decodable {
        let field: String
        let direction: String
        let parameters: [Pair]?
        let scope: Scope?
        let comparedAgo: AskWire.Shift?
    }

    /// A period as the schema writes it: unused parts are 0, "none" or "" (never null — see `AskPortableSchema`).
    private struct Scope: Decodable {
        let kind: String
        let days: Lenient?
        let unit: String?
        let from: String?
        let to: String?
        let shiftCount: Lenient?
        let shiftUnit: String?

        var wire: AskWire.Scope {
            let units = Set(QueryScope.Unit.allCases.map(\.rawValue))
            func whole(_ n: Lenient?) -> Int? { n.flatMap { $0.number.isFinite && abs($0.number) < 1e6 && $0.number != 0 ? Int($0.number) : nil } }
            return AskWire.Scope(
                kind: kind, days: whole(days), unit: unit.flatMap { units.contains($0) ? $0 : nil },
                from: from.flatMap { $0.isEmpty ? nil : $0 }, to: to.flatMap { $0.isEmpty ? nil : $0 },
                shiftCount: whole(shiftCount), shiftUnit: shiftUnit.flatMap { units.contains($0) ? $0 : nil }
            )
        }
    }
    private struct Term: Decodable { let phrase: String; let meaning: String }


    /// A number a model may write as 100, 100.0 or "100".
    private struct Lenient: Decodable {
        let number: Double
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let d = try? c.decode(Double.self) { number = d }
            else if let s = try? c.decode(String.self), let d = Double(s.trimmingCharacters(in: .whitespaces)) { number = d }
            else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a number") }
        }
    }

    /// "Compared with N earlier" where N is 0 or less is a filled-in blank (the schema makes a model write something there),
    /// not a comparison: it means none.
    private static func shift(_ shift: AskWire.Shift?) -> AskWire.Shift? {
        guard let shift, shift.count >= 1, QueryScope.Unit(rawValue: shift.unit) != nil else { return nil }
        return shift
    }

    private enum Keys: String, CodingKey { case target, groups, sorts, limit, perArtist, perAlbum, perReleaseYear, unsupported, resolvedTerms, similarSeed, similarKind, similarArtist, similarLimit }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        target = try c.decode(String.self, forKey: .target)
        let groups = (try? c.decode([[Cond]].self, forKey: .groups)) ?? []
        let sorts = (try? c.decode([Sort].self, forKey: .sorts)) ?? []
        let limit = (try? c.decodeIfPresent(Lenient.self, forKey: .limit)).flatMap { $0 }
        let unsupported = (try? c.decodeIfPresent([String].self, forKey: .unsupported)) ?? []
        // A cap written as 1, 1.0 or "1"; null, 0 or anything else means no cap (an over-large one is clamped by the interpreter).
        func cap(_ key: Keys) -> Int? {
            ((try? c.decodeIfPresent(Lenient.self, forKey: key)) ?? nil).flatMap { $0.number.isFinite && $0.number >= 1 && $0.number < 1_000_000 ? Int($0.number) : nil }
        }
        let seed = ((try? c.decodeIfPresent(String.self, forKey: .similarSeed)) ?? nil)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if seed.isEmpty {
            similar = nil
        } else {
            let kind = ((try? c.decodeIfPresent(String.self, forKey: .similarKind)) ?? nil).flatMap(SimilarSeed.Kind.init(rawValue:))
            let artist = (((try? c.decodeIfPresent(String.self, forKey: .similarArtist)) ?? nil) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let asked = ((try? c.decodeIfPresent(Lenient.self, forKey: .similarLimit)) ?? nil).flatMap { $0.number.isFinite && $0.number >= 1 && $0.number <= 500 ? Int($0.number) : nil }
            similar = AskSimilarIntent(seedText: seed, kind: kind, artistHint: artist.isEmpty ? nil : artist, limit: asked ?? AskSimilarIntent.defaultLimit)
        }
        resolvedTerms = ((try? c.decodeIfPresent([Term].self, forKey: .resolvedTerms)) ?? []).map { AskResolvedTerm(phrase: $0.phrase, meaning: $0.meaning) }

        func parameters(_ pairs: [Pair]?) -> [String: String]? {
            guard let pairs, !pairs.isEmpty else { return nil }
            return Dictionary(pairs.map { ($0.id, $0.value) }, uniquingKeysWith: { _, last in last })
        }
        // A limit the model wrote as 25.0 or "25" is still 25; an absurd one is left for the interpreter to refuse.
        let limitValue = limit.flatMap { $0.number.isFinite && $0.number >= 1 && $0.number < 1_000_000 ? Int($0.number) : nil }
        query = AskWire.Query(
            groups: groups.map { group in group.map { cond in
                AskWire.Condition(
                    field: cond.field, op: cond.op, value: cond.value?.number, valueTo: cond.valueTo?.number, text: cond.text, date: cond.date,
                    dateTo: cond.dateTo, tags: (cond.tags?.isEmpty == false) ? cond.tags : nil, parameters: parameters(cond.parameters), scope: cond.scope?.wire, comparedAgo: Self.shift(cond.comparedAgo))
            } },
            sorts: sorts.map { AskWire.Sort(field: $0.field, direction: $0.direction, parameters: parameters($0.parameters), scope: $0.scope?.wire, comparedAgo: Self.shift($0.comparedAgo)) },
            limit: limitValue, unsupported: unsupported,
            perArtist: cap(.perArtist), perAlbum: cap(.perAlbum), perReleaseYear: cap(.perReleaseYear)
        )
    }
}
