import Foundation
import SwiftData

#if DEBUG
/// Verification hook: with `SCROBLYTICS_ASK_EVAL=/path/requests.json` (a JSON array of sentences) set, translates each
/// one with the real model inside the real app process and writes `<path>.out.json` with what the model said, how
/// it was interpreted, and how long it took, then quits. `SCROBLYTICS_ASK_PROVIDER=privateCloud` picks Private
/// Cloud Compute (which only works from the signed app, not from a command-line tool).
enum AskDebugEval {
    /// The engine named by `SCROBLYTICS_ASK_PROVIDER` (and `…_MODEL`, `…_BASEURL`, `…_KEY`), or nil when none is given.
    @MainActor
    static func engine(fromEnvironment env: [String: String], registry: QueryFieldRegistry) -> AskEngine? {
        guard let name = env["SCROBLYTICS_ASK_PROVIDER"], !name.isEmpty else { return nil }
        if let id = AskEngineID(rawValue: name), id != .onDevice {
            let model = env["SCROBLYTICS_ASK_MODEL"].flatMap { $0.isEmpty ? nil : $0 } ?? id.defaultModel
            let address = env["SCROBLYTICS_ASK_BASEURL"].flatMap { $0.isEmpty ? nil : $0 } ?? id.defaultBaseURL
            let key = env["SCROBLYTICS_ASK_KEY"].flatMap { $0.isEmpty ? nil : $0 } ?? AskKeychain.key(for: id)
            return AskModelEngine(client: AskLLMClients.make(id, config: AskProviderConfig(model: model, baseURL: address), key: key), registry: registry, label: "\(id.label) · \(model)")
        }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return AskTranslator(registry: registry) }
        #endif
        return nil
    }

    /// `SCROBLYTICS_ASK_SUGGEST_PICKS=/path/out.txt` with `SCROBLYTICS_ASK_PICK_ENGINE=onDevice|anthropic|…`: simulates 14 openings of Ask
    /// and prints what each picked, then checks the rules: only vouched-for templates, never a repeat of the last 8, a new kind each time.
    @MainActor
    static func runSuggestPicksIfRequested(container: ModelContainer) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["SCROBLYTICS_ASK_SUGGEST_PICKS"] else { return }
        Task { @MainActor in
            let engine = AskEngineID(rawValue: env["SCROBLYTICS_ASK_PICK_ENGINE"] ?? "") ?? .onDevice
            let key = "ask.suggestions.recent"
            let original = UserDefaults.standard.stringArray(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
            let store = AskSuggestionStore()
            var lines: [String] = []
            // Before any refresh there are no facts: only generic suggestions can appear.
            await store.chooseForOpening(engine: engine)
            lines.append("NO-FACTS pick: \(store.current?.sentence ?? "(default)") personal=\(store.current?.personal.description ?? "-")")
            await store.refresh(container: container)
            var seen: [String] = []
            var lastCategory: AskSuggestion.Category?
            var violations: [String] = []
            for opening in 1...14 {
                await store.chooseForOpening(engine: engine)
                guard let pick = store.current else { lines.append("\(opening): (default sentence)"); continue }
                lines.append("\(opening): [\(pick.category.rawValue)\(pick.personal ? ", personal" : "")] \(pick.sentence)  <\(pick.templateID)>")
                if !AskSuggestionVerification.allows(pick.templateID, engine: engine) { violations.append("\(opening): not vouched for on \(engine.rawValue)") }
                if seen.suffix(8).contains(pick.id) { violations.append("\(opening): repeated a recent pick") }
                if pick.category == lastCategory { lines.append("   (same kind as the previous opening)") }
                seen.append(pick.id)
                lastCategory = pick.category
            }
            let personalCount = seen.count
            lines.append("DISTINCT picks \(Set(seen).count) of \(personalCount); violations: \(violations.isEmpty ? "none" : violations.joined(separator: "; "))")
            if let original { UserDefaults.standard.set(original, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            exit(0)
        }
    }

    /// `SCROBLYTICS_ASK_SUGGEST_CHECK=/path/out.json`: fills every suggestion template from the real library, runs each on the data
    /// (rows found) and — with `SCROBLYTICS_ASK_PROVIDER` — through that engine, scoring the engine's reading against the template's
    /// expected one. The per-template tally is what `AskSuggestionVerification` is set from.
    @MainActor
    static func runSuggestCheckIfRequested(container: ModelContainer) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["SCROBLYTICS_ASK_SUGGEST_CHECK"] else { return }
        Task { @MainActor in
            let registry = QueryFieldRegistry.standard
            let store = AskSuggestionStore()
            await store.refresh(container: container)
            // `SCROBLYTICS_ASK_SUGGEST_ONLY=templateA,templateB` limits the run to those templates (a full run is slow).
            let only = env["SCROBLYTICS_ASK_SUGGEST_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
            let candidates = store.allCandidates().filter { only?.contains($0.suggestion.templateID) ?? true }
            let engine = engine(fromEnvironment: env, registry: registry)
            let vocabulary = EntityTagsEngine.loadSnapshot(context: container.mainContext).vocabulary.map(\.tag)
            let context = AskContext(tags: Array(vocabulary.prefix(AskContext.tagLimit)), knownTags: Set(vocabulary), knownArtists: nil, earliest: nil, container: container)
            let now = Date()
            var rows: [[String: Any]] = []
            var tally: [String: (passed: Int, total: Int)] = [:]
            for (suggestion, count) in candidates {
                var entry: [String: Any] = ["id": suggestion.id, "template": suggestion.templateID, "sentence": suggestion.sentence, "rows": count, "personal": suggestion.personal]
                if count >= AskSuggestion.minimumRows, let engine {
                    let item: AskEval.Case
                    if let similar = suggestion.similar {
                        item = AskEval.Case(request: suggestion.sentence, target: suggestion.target, accepted: [], expectsUnsupported: false, category: "suggestion", note: nil,
                                            expectsSimilar: AskEval.SimilarExpectation(seed: similar.seedText, limit: similar.limit, kinds: similar.kind.map { [$0] } ?? []))
                    } else if !suggestion.fieldSets.isEmpty {
                        item = AskEval.Case(request: suggestion.sentence, target: suggestion.target, accepted: [], expectsUnsupported: false, category: "suggestion", note: nil, acceptedFieldSets: suggestion.fieldSets)
                    } else {
                        item = AskEval.Case(request: suggestion.sentence, target: suggestion.target,
                                            accepted: suggestion.readings.map { AskEval.Reading($0.groups, sorts: $0.sorts ?? [], limit: $0.limit, perArtist: $0.perArtist, perAlbum: $0.perAlbum, perReleaseYear: $0.perReleaseYear) },
                                            expectsUnsupported: false, category: "suggestion", note: nil)
                    }
                    var attempt = 0
                    var translated: AskTranslation?
                    while translated == nil, attempt < 8 {
                        do { translated = try await engine.translate(suggestion.sentence, context: context, now: now) }
                        catch AskLLMError.rateLimited { attempt += 1; try? await Task.sleep(nanoseconds: 25_000_000_000) }
                        catch { entry["error"] = "\(error)"; break }
                    }
                    if let t = translated {
                        let verdict = AskEval.score(item, interpretation: t.interpretation, target: t.target, registry: registry, now: now, similar: t.similar)
                        entry["passed"] = verdict.passed
                        entry["actual"] = verdict.actual
                        entry["expected"] = verdict.accepted
                        var tallyEntry = tally[suggestion.templateID] ?? (0, 0)
                        tallyEntry.total += 1
                        if verdict.passed { tallyEntry.passed += 1 }
                        tally[suggestion.templateID] = tallyEntry
                    }
                }
                rows.append(entry)
            }
            let summary: [String: Any] = [
                "provider": env["SCROBLYTICS_ASK_PROVIDER"] ?? "(none — rows only)", "model": env["SCROBLYTICS_ASK_MODEL"] ?? "",
                "perTemplate": tally.mapValues { "\($0.passed)/\($0.total)" }, "suggestions": rows,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: path)) }
            exit(0)
        }
    }

    /// `SCROBLYTICS_ASK_CONTRACT=http://127.0.0.1:PORT` + `SCROBLYTICS_ASK_CONTRACT_OUT=/path`: runs every provider client
    /// through a set of scenarios against a MOCK server (a script that validates what it receives — headers, body shape,
    /// where the key travels — and replies with canned answers), and writes what each scenario produced. No key, no network.
    @MainActor
    static func runContractIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["SCROBLYTICS_ASK_CONTRACT"], let outPath = env["SCROBLYTICS_ASK_CONTRACT_OUT"] else { return }
        Task { @MainActor in
            let registry = QueryFieldRegistry.standard
            var lines: [String] = []
            func run(_ label: String, _ engine: AskEngineID, model: String, key: String?, baseURL: String? = nil, sentence: String = "artists I've played more than 100 times") async {
                let config = AskProviderConfig(model: model, baseURL: baseURL ?? base)
                let askEngine = AskModelEngine(client: AskLLMClients.make(engine, config: config, key: key), registry: registry, label: label)
                do {
                    let t = try await askEngine.translate(sentence, context: .none, now: Date())
                    let chips = AskChips.describe(t.interpretation.spec, registry: registry).map(\.text).joined(separator: " | ")
                    lines.append("\(label): OK target=\(t.target.rawValue) chips=[\(chips)] dropped=\(t.interpretation.dropped.count) terms=\(t.resolvedTerms.count) tokens=\(t.usage?.inputTokens ?? -1)/\(t.usage?.outputTokens ?? -1)/cached \(t.usage?.cachedTokens ?? -1)")
                } catch let error as AskLLMError {
                    lines.append("\(label): LLMERROR \(error)")
                } catch let error as AskError {
                    lines.append("\(label): ASKERROR \(error)")
                } catch {
                    lines.append("\(label): OTHER \(error)")
                }
            }
            for engine in [AskEngineID.anthropic, .openAI, .openAICompatible, .google, .ollama] {
                let key: String? = engine == .ollama ? nil : "sk-contract-test-key"
                await run("\(engine)/ok", engine, model: "ok", key: key)
                await run("\(engine)/fenced", engine, model: "fenced", key: key)
                await run("\(engine)/badjson", engine, model: "badjson", key: key)
                await run("\(engine)/hostile", engine, model: "hostile", key: key)
                await run("\(engine)/badtarget", engine, model: "badtarget", key: key)
                await run("\(engine)/ratelimit", engine, model: "ratelimit", key: key)
                await run("\(engine)/server500", engine, model: "server500", key: key)
                await run("\(engine)/unknownmodel", engine, model: "unknownmodel", key: key)
                if engine != .ollama { await run("\(engine)/badkey", engine, model: "ok", key: "bad") }
                if engine != .ollama { await run("\(engine)/nokey", engine, model: "ok", key: nil) }
                await run("\(engine)/unreachable", engine, model: "ok", key: key, baseURL: "http://127.0.0.1:1")
            }
            await run("openAICompatible/noschema", .openAICompatible, model: "noschema", key: nil)
            await run("openAI/noschema(no fallback)", .openAI, model: "noschema", key: "sk-contract-test-key")
            for engine in [AskEngineID.anthropic, .openAI, .openAICompatible, .google, .ollama] {
                let config = AskProviderConfig(model: "ok", baseURL: base)
                do {
                    let models = try await AskLLMClients.make(engine, config: config, key: engine == .ollama ? nil : "sk-contract-test-key").listModels()
                    lines.append("\(engine)/models: \(models)")
                } catch { lines.append("\(engine)/models: ERROR \(error)") }
            }
            // Engine selection and key storage, end to end through the same functions Settings and Ask use.
            var settings = AskSettings()
            settings.selected = .anthropic
            lines.append("RESOLVE anthropic without a key: \(AskEngines.resolve(registry: registry, settings: settings).availability)")
            settings.selected = .openAICompatible
            settings.set(AskProviderConfig(model: "ok", baseURL: base), for: .openAICompatible)
            let resolved = AskEngines.resolve(registry: registry, settings: settings)
            lines.append("RESOLVE compatible (no key needed): \(resolved.availability) engine=\(resolved.engine?.displayName ?? "nil")")
            if let engine = resolved.engine, let t = try? await engine.translate("artists I've played more than 100 times", context: .none, now: Date()) {
                lines.append("RESOLVE translate via resolved engine: \(AskChips.describe(t.interpretation.spec, registry: registry).map(\.text)) engine=\(t.engine)")
            }
            settings.selected = .openAI
            lines.append("RESOLVE openAI without a key: \(AskEngines.resolve(registry: registry, settings: settings).availability)")
            let probe = AskEngineID.openAI
            let hadKey = AskKeychain.key(for: probe)
            try? AskKeychain.setKey("  sk-roundtrip-123  ", for: probe)
            let stored = AskKeychain.key(for: probe)
            let settingsJSON = String(data: (try? JSONEncoder().encode(settings)) ?? Data(), encoding: .utf8) ?? ""
            lines.append("KEYCHAIN stored(trimmed)=\(stored == "sk-roundtrip-123") settingsJSONContainsKey=\(settingsJSON.contains("sk-roundtrip"))")
            lines.append("RESOLVE openAI with a key: \(AskEngines.resolve(registry: registry, settings: settings).availability)")
            AskKeychain.removeKey(for: probe)
            lines.append("KEYCHAIN removed=\(!AskKeychain.hasKey(for: probe))")
            if let hadKey { try? AskKeychain.setKey(hadKey, for: probe) }
            lines.append("EXAMPLES stale=\(AskExamples.staleExamples(registry: registry).map(\.request)) shown-to-models=\(AskExamples.renderedForModels(registry: registry).components(separatedBy: "Request: ").count - 1)")
            if let dump = env["SCROBLYTICS_ASK_PROMPT_DUMP"] {
                let context = AskContext(tags: ["indie", "folk", "running"], knownTags: ["indie", "folk", "running"], knownArtists: nil, earliest: Date(timeIntervalSince1970: 1_300_000_000))
                try? AskPrompt.system(registry: registry, context: context, now: Date()).write(toFile: dump, atomically: true, encoding: .utf8)
            }
            let schema = AskPortableSchema.build(registry: registry)
            lines.append("SCHEMA bytes=\(schema.data.count)")
            lines.append("PROMPT tokens≈\(AskPrompt.system(registry: registry, context: .none, now: Date()).count / 4)")
            try? lines.joined(separator: "\n").write(toFile: outPath, atomically: true, encoding: .utf8)
            exit(0)
        }
    }

    /// `SCROBLYTICS_ASK_EVALSET=/path/out.json` runs every case of `AskEval.cases` through the chosen engine and writes
    /// the score and each case's verdict. Engine: `SCROBLYTICS_ASK_PROVIDER` (see `AskEvalEngines`); default on-device.
    @MainActor
    static func runEvalSetIfRequested(container: ModelContainer) {
        runContractIfRequested()
        runSuggestCheckIfRequested(container: container)
        runSuggestPicksIfRequested(container: container)
        if let listPath = ProcessInfo.processInfo.environment["SCROBLYTICS_ASK_LISTMODELS"] {
            // The model names a provider offers this key (key from the Keychain item Settings › Ask saved).
            Task { @MainActor in
                let env = ProcessInfo.processInfo.environment
                var out = ""
                if let id = AskEngineID(rawValue: env["SCROBLYTICS_ASK_PROVIDER"] ?? ""), id != .onDevice {
                    let config = AskProviderConfig(model: "", baseURL: id.defaultBaseURL)
                    do { out = try await AskLLMClients.make(id, config: config, key: AskKeychain.key(for: id)).listModels().joined(separator: "\n") } catch { out = "ERROR \(error)" }
                }
                try? out.write(toFile: listPath, atomically: true, encoding: .utf8)
                exit(0)
            }
            return
        }
        if let resolvePath = ProcessInfo.processInfo.environment["SCROBLYTICS_ASK_SIMILAR_RESOLVE"] {
            // Finds the library item for a few seeds (no model): "Sweetness Follows" should be R.E.M.'s song.
            Task { @MainActor in
                var lines: [String] = []
                let intents = [
                    AskSimilarIntent(seedText: "Sweetness Follows", kind: .track, artistHint: nil, limit: 25),
                    AskSimilarIntent(seedText: "Sweetness Follows", kind: nil, artistHint: nil, limit: 25),
                    AskSimilarIntent(seedText: "Big Thief", kind: .artist, artistHint: nil, limit: 30),
                    AskSimilarIntent(seedText: "Wowee Zowee", kind: .album, artistHint: "Pavement", limit: 30),
                    AskSimilarIntent(seedText: "Hounds of Love", kind: nil, artistHint: "Kate Bush", limit: 40),
                    AskSimilarIntent(seedText: "A Song That Does Not Exist", kind: nil, artistHint: nil, limit: 10),
                ]
                for intent in intents {
                    let seed = await AskSimilarResolver.resolve(intent, container: container)
                    lines.append("\(intent.seedText) [\(intent.kind?.rawValue ?? "?")] hint=\(intent.artistHint ?? "-") -> \(seed.map { "\($0.kind.rawValue): \($0.label)" } ?? "NOT FOUND")")
                }
                try? lines.joined(separator: "\n").write(toFile: resolvePath, atomically: true, encoding: .utf8)
                exit(0)
            }
            return
        }
        if let checkPath = ProcessInfo.processInfo.environment["SCROBLYTICS_ASK_EVALCHECK"] {
            // No model: print what each case's accepted readings interpret to, and any that don't validate.
            let registry = QueryFieldRegistry.standard
            var lines: [String] = []
            for item in AskEval.cases {
                let (signatures, errors) = AskEval.expectedSignatures(for: item, registry: registry, now: Date())
                lines.append("\(item.request)")
                for s in signatures { lines.append("    \(s)") }
                for e in errors { lines.append("    AUTHORING ERROR: \(e)") }
            }
            try? lines.joined(separator: "\n").write(toFile: checkPath, atomically: true, encoding: .utf8)
            exit(0)
        }
        guard let path = ProcessInfo.processInfo.environment["SCROBLYTICS_ASK_EVALSET"] else { return }
        Task { @MainActor in
            #if canImport(FoundationModels)
            guard #available(macOS 26.0, *) else { exit(2) }
            let registry = QueryFieldRegistry.standard
            let env = ProcessInfo.processInfo.environment
            let providerName = env["SCROBLYTICS_ASK_PROVIDER"] ?? "onDevice"
            // A model engine is built straight from the environment (a key is never read from, or written to, the Keychain
            // or any file by this hook); anything else is one of the Apple engines.
            let engine: AskEngine
            if let id = AskEngineID(rawValue: providerName), id != .onDevice {
                // An empty variable (what the script passes when you give no model or address) means "use the default".
                let model = env["SCROBLYTICS_ASK_MODEL"].flatMap { $0.isEmpty ? nil : $0 } ?? id.defaultModel
                let address = env["SCROBLYTICS_ASK_BASEURL"].flatMap { $0.isEmpty ? nil : $0 } ?? id.defaultBaseURL
                let config = AskProviderConfig(model: model, baseURL: address)
                // The key comes from the environment if one is given, otherwise from the Keychain item the Settings › Ask pane saved —
                // read inside this process, never printed or written anywhere.
                let key = env["SCROBLYTICS_ASK_KEY"].flatMap { $0.isEmpty ? nil : $0 } ?? AskKeychain.key(for: id)
                engine = AskModelEngine(client: AskLLMClients.make(id, config: config, key: key), registry: registry, label: "\(id.label) · \(config.model)")
            } else {
                engine = AskTranslator(provider: AskTranslator.Provider(rawValue: providerName) ?? .onDevice, registry: registry)
            }
            let provider = (name: providerName, model: env["SCROBLYTICS_ASK_MODEL"] ?? "")
            let vocabulary = EntityTagsEngine.loadSnapshot(context: container.mainContext).vocabulary.map(\.tag)
            let artistNames = (try? container.mainContext.fetch(FetchDescriptor<Artist>()))?.map(\.name) ?? []
            var oldest = FetchDescriptor<Scrobble>(sortBy: [SortDescriptor(\.playedAt)])
            oldest.fetchLimit = 1
            let context = AskContext(tags: Array(vocabulary.prefix(AskContext.tagLimit)), knownTags: Set(vocabulary), knownArtists: Set(artistNames), earliest: try? container.mainContext.fetch(oldest).first?.playedAt)
            let now = Date()
            var inputTokens = 0, outputTokens = 0, cachedTokens = 0
            var results: [[String: Any]] = []
            var passed = 0
            var unseenPassed = 0, unseenTotal = 0
            var byCategory: [String: (passed: Int, total: Int)] = [:]
            // SCROBLYTICS_ASK_EVALSET_LIMIT=n runs just the first n cases (a smoke test that costs n requests).
            let limit = Int(env["SCROBLYTICS_ASK_EVALSET_LIMIT"] ?? "") ?? AskEval.cases.count
            for item in AskEval.cases.prefix(limit) {
                let started = Date()
                var entry: [String: Any] = ["request": item.request, "category": item.category]
                do {
                    // A provider that limits tokens per minute (the prompt is ~10k tokens) makes a long run wait its turn: retry after a
                    // pause instead of recording a rate limit as a wrong answer.
                    var attempt = 0
                    var translated: AskTranslation?
                    while translated == nil {
                        do { translated = try await engine.translate(item.request, context: context, now: now) }
                        catch AskLLMError.rateLimited where attempt < 8 {
                            attempt += 1
                            try? await Task.sleep(nanoseconds: 25_000_000_000)
                        }
                    }
                    let t = translated!
                    if let usage = t.usage { inputTokens += usage.inputTokens ?? 0; outputTokens += usage.outputTokens ?? 0; cachedTokens += usage.cachedTokens ?? 0 }
                    entry["raw"] = t.raw
                    let verdict = AskEval.score(item, interpretation: t.interpretation, target: t.target, registry: registry, now: now, similar: t.similar)
                    entry["passed"] = verdict.passed
                    entry["reason"] = verdict.reason
                    entry["actual"] = verdict.actual
                    entry["accepted"] = verdict.accepted
                    if !verdict.authoringErrors.isEmpty { entry["authoringErrors"] = verdict.authoringErrors }
                    entry["chips"] = AskChips.describe(t.interpretation.spec, registry: registry).map(\.text)
                    entry["unsupported"] = t.interpretation.unsupported
                    entry["dropped"] = t.interpretation.dropped.map { "\($0.what): \($0.reason)" }
                    if verdict.passed { passed += 1 }
                    entry["seenInPrompt"] = AskEval.isShownInPrompts(item.request)
                } catch {
                    entry["passed"] = false
                    entry["reason"] = "error: \(error)"
                }
                entry["seconds"] = Date().timeIntervalSince(started)
                if !AskEval.isShownInPrompts(item.request) {
                    unseenTotal += 1
                    if entry["passed"] as? Bool == true { unseenPassed += 1 }
                }
                var tally = byCategory[item.category] ?? (0, 0)
                tally.total += 1
                if entry["passed"] as? Bool == true { tally.passed += 1 }
                byCategory[item.category] = tally
                results.append(entry)
                let summary: [String: Any] = [
                    "provider": provider.name, "model": provider.model, "tokens": ["input": inputTokens, "output": outputTokens, "cached": cachedTokens], "score": "\(passed)/\(results.count) of \(AskEval.cases.count)", "unseenScore": "\(unseenPassed)/\(unseenTotal) (requests not shown in any prompt)",
                    "byCategory": byCategory.mapValues { "\($0.passed)/\($0.total)" }, "results": results,
                ]
                if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: path))
                }
            }
            exit(0)
            #endif
        }
    }

    @MainActor
    static func runHeadlessIfRequested(container: ModelContainer) {
        runEvalSetIfRequested(container: container)
        guard let path = ProcessInfo.processInfo.environment["SCROBLYTICS_ASK_EVAL"] else { return }
        Task { @MainActor in
            #if canImport(FoundationModels)
            guard #available(macOS 26.0, *) else { exit(2) }
            let provider = AskTranslator.Provider(rawValue: ProcessInfo.processInfo.environment["SCROBLYTICS_ASK_PROVIDER"] ?? "") ?? .onDevice
            let registry = QueryFieldRegistry.standard
            let freeEnv = ProcessInfo.processInfo.environment
            let freeProviderName = freeEnv["SCROBLYTICS_ASK_PROVIDER"] ?? "onDevice"
            let translator: AskEngine
            if let id = AskEngineID(rawValue: freeProviderName), id != .onDevice {
                let model = freeEnv["SCROBLYTICS_ASK_MODEL"].flatMap { $0.isEmpty ? nil : $0 } ?? id.defaultModel
                let address = freeEnv["SCROBLYTICS_ASK_BASEURL"].flatMap { $0.isEmpty ? nil : $0 } ?? id.defaultBaseURL
                let key = freeEnv["SCROBLYTICS_ASK_KEY"].flatMap { $0.isEmpty ? nil : $0 } ?? AskKeychain.key(for: id)
                translator = AskModelEngine(client: AskLLMClients.make(id, config: AskProviderConfig(model: model, baseURL: address), key: key), registry: registry, label: "\(id.label) · \(model)")
            } else {
                translator = AskTranslator(provider: provider, registry: registry)
            }
            // The same grounding the query tab gives the model: the library's most common tags and where its history begins.
            let vocabulary = EntityTagsEngine.loadSnapshot(context: container.mainContext).vocabulary.map(\.tag)
            let tags = Array(vocabulary.prefix(AskContext.tagLimit))
            var oldest = FetchDescriptor<Scrobble>(sortBy: [SortDescriptor(\.playedAt)])
            oldest.fetchLimit = 1
            let artistNames = (try? container.mainContext.fetch(FetchDescriptor<Artist>()))?.map(\.name) ?? []
            let context = AskContext(tags: tags, knownTags: Set(vocabulary), knownArtists: Set(artistNames), earliest: try? container.mainContext.fetch(oldest).first?.playedAt)
            var out: [[String: Any]] = []
            do {
                let requests = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
                for request in requests {
                    let started = Date()
                    var entry: [String: Any] = ["request": request, "provider": freeProviderName]
                    do {
                        let t = try await translator.translate(request, context: context, now: Date())
                        entry["target"] = t.target.rawValue
                        entry["raw"] = t.raw
                        entry["intro"] = t.intro
                        entry["chips"] = AskChips.describe(t.interpretation.spec, registry: registry).map(\.text)
                        entry["dropped"] = t.interpretation.dropped.map { "\($0.what): \($0.reason)" }
                        entry["unsupported"] = t.interpretation.unsupported
                        entry["spec"] = (try? String(data: t.interpretation.spec.encoded(), encoding: .utf8)) ?? ""
                    } catch { entry["error"] = "\(error)" }
                    entry["seconds"] = Date().timeIntervalSince(started)
                    out.append(entry)
                }
            } catch { out.append(["error": "\(error)"]) }
            let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
            try? data?.write(to: URL(fileURLWithPath: path + ".out.json"))
            exit(0)
            #endif
        }
    }
}
#endif
