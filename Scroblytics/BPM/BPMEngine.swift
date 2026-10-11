import Foundation
import SwiftData

/// Where a track's tempo came from.
enum BPMSource: String, Sendable, CaseIterable {
    case getSongBPM = "getsongbpm"
    case deezer
    case manual

    var label: String {
        switch self {
        case .getSongBPM: "GetSongBPM"
        case .deezer: "Deezer"
        case .manual: "Entered by you"
        }
    }
}

/// The preset tempo ranges offered in Query. Each lower bound belongs to its own bucket.
enum TempoBucket: String, CaseIterable, Sendable {
    case slow = "Slow (under 90 BPM)"
    case moderate = "Moderate (90–120 BPM)"
    case upbeat = "Upbeat (120–140 BPM)"
    case fast = "Fast (140–160 BPM)"
    case veryFast = "Very fast (160+ BPM)"

    static func bucket(for bpm: Double) -> TempoBucket {
        switch bpm {
        case ..<90: .slow
        case ..<120: .moderate
        case ..<140: .upbeat
        case ..<160: .fast
        default: .veryFast
        }
    }
}

/// Track tempo (BPM) resolution. The same shape as `DurationEngine`: a precedence chain (your correction, then the
/// cached lookup, then a cached miss, then unresolved), resolved lazily for whatever a screen shows and cached.
/// Lookups try GetSongBPM first (when a key is saved), then Deezer, one track at a time to stay inside
/// GetSongBPM's hourly allowance. A lookup that fails for a temporary reason is never cached, and a cached miss
/// is looked up again after `missRetryDays` since both sources keep adding tracks.
@MainActor
enum BPMEngine {
    struct Progress: Sendable {
        let remaining: Int
        let isComplete: Bool
    }

    static let progressNotification = Notification.Name("BPMEngineProgress")

    /// A tempo with where it came from and anything else the same lookup returned.
    struct Resolved: Sendable, Equatable {
        let bpm: Double
        let source: BPMSource
        var timeSignature: String?
        var musicalKey: String?
    }

    enum Resolution: Sendable, Equatable {
        case value(Resolved)
        /// Neither source has a tempo for this track, and there is no correction.
        case noMatch
        /// Not looked up yet.
        case pending

        var resolved: Resolved? { if case .value(let resolved) = self { resolved } else { nil } }
    }

    /// Read-only copy of everything tempo resolution reads, so the precedence rule runs off the main actor too.
    struct Snapshot: Sendable {
        var cached: [String: Resolved] = [:]
        var cachedMisses: Set<String> = []
        var overrides: [String: Double] = [:]

        nonisolated static let empty = Snapshot()

        nonisolated func resolution(forKey key: String) -> Resolution {
            if let bpm = overrides[key] {
                // A correction keeps the detected key and time signature, which it doesn't contradict.
                var resolved = Resolved(bpm: bpm, source: .manual)
                resolved.timeSignature = cached[key]?.timeSignature
                resolved.musicalKey = cached[key]?.musicalKey
                return .value(resolved)
            }
            if let resolved = cached[key] { return .value(resolved) }
            if cachedMisses.contains(key) { return .noMatch }
            return .pending
        }
    }

    nonisolated static let missRetryDays = 90

    nonisolated static func cacheKey(artist: String, track: String) -> String {
        TextNormalization.lovedKey(artist: artist, track: track)
    }

    nonisolated static func loadSnapshot(context: ModelContext, now: Date = Date()) -> Snapshot {
        var snapshot = Snapshot()
        let staleBefore = now.addingTimeInterval(-Double(missRetryDays) * 86400)
        for entry in (try? context.fetch(FetchDescriptor<TrackBPMCacheEntry>())) ?? [] {
            if let bpm = entry.bpm {
                snapshot.cached[entry.cacheKey] = Resolved(
                    bpm: bpm, source: entry.source.flatMap(BPMSource.init(rawValue:)) ?? .getSongBPM,
                    timeSignature: entry.timeSignature, musicalKey: entry.musicalKey
                )
            } else if entry.cachedAt >= staleBefore {
                snapshot.cachedMisses.insert(entry.cacheKey)
            }
        }
        for track in (try? context.fetch(FetchDescriptor<Track>())) ?? [] {
            if let bpm = track.bpmOverride { snapshot.overrides[track.identityKey] = bpm }
        }
        return snapshot
    }

    /// One track's state from two small keyed reads — for a detail page, which shouldn't load the whole cache.
    nonisolated static func resolution(context: ModelContext, key: String, now: Date = Date()) -> Resolution {
        var snapshot = Snapshot()
        var track = FetchDescriptor<Track>(predicate: #Predicate { $0.identityKey == key })
        track.fetchLimit = 1
        if let bpm = (try? context.fetch(track).first)?.bpmOverride { snapshot.overrides[key] = bpm }
        var entry = FetchDescriptor<TrackBPMCacheEntry>(predicate: #Predicate { $0.cacheKey == key })
        entry.fetchLimit = 1
        if let cached = try? context.fetch(entry).first {
            if let bpm = cached.bpm {
                snapshot.cached[key] = Resolved(
                    bpm: bpm, source: cached.source.flatMap(BPMSource.init(rawValue:)) ?? .getSongBPM,
                    timeSignature: cached.timeSignature, musicalKey: cached.musicalKey
                )
            } else if cached.cachedAt >= now.addingTimeInterval(-Double(missRetryDays) * 86400) {
                snapshot.cachedMisses.insert(key)
            }
        }
        return snapshot.resolution(forKey: key)
    }

    // MARK: - Formatting and parsing

    /// "128", or "127.9" — a trailing ".0" is dropped.
    nonisolated static func format(_ bpm: Double) -> String {
        let rounded = (bpm * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }

    /// A user-entered tempo: a positive number up to 999, kept to 2 decimal places.
    nonisolated static func parse(_ input: String) -> Double? {
        let text = input.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(text), value.isFinite, value > 0, value <= 999 else { return nil }
        return (value * 100).rounded() / 100
    }

    // MARK: - Resolution

    private struct PendingTrack: Sendable {
        let artist: String
        let track: String
    }

    private struct FetchResult: Sendable {
        let key: String
        let found: Resolved?
        let succeeded: Bool
        /// Stopped because Offline mode is on: not a failure, and the key stays queued.
        var paused = false
    }

    /// Pause after a lookup that spent a GetSongBPM request. Its allowance (3,000 an hour) is for the whole shared
    /// key, not per Mac, so each Mac stays near 500 an hour. A Deezer-only lookup needs far less.
    private static let afterGetSongBPMNanoseconds: UInt64 = 7_000_000_000
    private static let afterDeezerOnlyNanoseconds: UInt64 = 1_250_000_000
    private static var usedGetSongBPM = false
    private static let minAnnounceInterval: TimeInterval = 4
    private static var lastAnnounced = Date.distantPast
    private static let maxFailedRounds = 3
    private static var pending: [String: PendingTrack] = [:]
    /// Queue order: what a screen asked for jumps to the front; background-seeded tracks wait in play-count order.
    private static var pendingOrder: [String] = []
    private static var failedRounds: [String: Int] = [:]
    private static var warmerTask: Task<Void, Never>?
    /// GetSongBPM refused the saved key; it is skipped for the rest of the session so every track doesn't retry it.
    private static var getSongBPMRejectedKey: String?

    /// Resolves the tempo of every distinct (artist, track) in `scrobbles`, returning what is known now keyed by
    /// `cacheKey`. Unresolved tracks are queued and arrive through `progressNotification`.
    static func resolveBPMLookup(context: ModelContext, scrobbles: [ScrobbleSnapshot]) -> [String: Resolved] {
        var targets: [String: PendingTrack] = [:]
        for s in scrobbles where !s.trackName.isEmpty && !s.artistName.isEmpty {
            targets[cacheKey(artist: s.artistName, track: s.trackName)] = PendingTrack(artist: s.artistName, track: s.trackName)
        }
        let snapshot = loadSnapshot(context: context)
        var lookup: [String: Resolved] = [:]
        for (key, target) in targets {
            switch snapshot.resolution(forKey: key) {
            case .value(let resolved): lookup[key] = resolved
            case .noMatch: break
            case .pending: enqueue(key, target, priority: true)
            }
        }
        if !pending.isEmpty, warmerTask == nil, !ConnectivityGate.isOffline {
            postProgress(isComplete: false)
            startWarmer(context: context)
        }
        return lookup
    }

    private static func enqueue(_ key: String, _ target: PendingTrack, priority: Bool) {
        if pending[key] == nil {
            pending[key] = target
            if priority { pendingOrder.insert(key, at: 0) } else { pendingOrder.append(key) }
        } else if priority, let index = pendingOrder.firstIndex(of: key), index > 0 {
            pendingOrder.remove(at: index)
            pendingOrder.insert(key, at: 0)
        }
    }

    private static func finish(_ key: String) {
        pending.removeValue(forKey: key)
        pendingOrder.removeAll { $0 == key }
        failedRounds.removeValue(forKey: key)
    }

    /// Whether the user lets Scroblytics look tempos up on its own (Settings › Tempo). On by default.
    static let backgroundLookupsKey = "tempo.backgroundLookups"
    static var backgroundLookupsEnabled: Bool {
        UserDefaults.standard.object(forKey: backgroundLookupsKey) as? Bool ?? true
    }
    private static let backgroundSeedLimit = 1_500

    /// Queues the most-played tracks that have no tempo, no correction and no recent "no value", behind anything a
    /// screen asks for. Safe to call at launch and after every sync: tracks already queued or resolved are skipped.
    /// The lookups happen slowly in the background (see the pacing above) and show on the status strip.
    @discardableResult
    static func seedMostPlayedUnresolved(context: ModelContext) async -> Int {
        guard backgroundLookupsEnabled, !ConnectivityGate.isOffline else { return 0 }
        let container = context.container
        let candidates = (try? await offMain { try await BPMSeedReader(modelContainer: container).mostPlayedUnresolved(limit: backgroundSeedLimit) }) ?? []
        var queued = 0
        for candidate in candidates {
            let key = cacheKey(artist: candidate.artist, track: candidate.track)
            guard pending[key] == nil else { continue }
            enqueue(key, PendingTrack(artist: candidate.artist, track: candidate.track), priority: false)
            queued += 1
        }
        if !pending.isEmpty, warmerTask == nil, !ConnectivityGate.isOffline {
            postProgress(isComplete: false)
            startWarmer(context: context)
        }
        return queued
    }

    private static func startWarmer(context: ModelContext) {
        warmerTask = Task { @MainActor in
            var resolvedSinceSave = 0
            while let key = pendingOrder.first, let target = pending[key], !Task.isCancelled, !ConnectivityGate.isOffline {
                let result = await fetchWithRetry(key: key, target: target)
                if result.paused { break }
                if result.succeeded {
                    store(result, context: context)
                    finish(key)
                    resolvedSinceSave += 1
                } else {
                    // A track that keeps failing goes to the back, and is dropped for now after a few rounds (it isn't
                    // cached, so a screen or the next launch asks again later).
                    failedRounds[key, default: 0] += 1
                    if (failedRounds[key] ?? 0) >= maxFailedRounds {
                        finish(key)
                    } else {
                        pendingOrder.removeAll { $0 == key }
                        pendingOrder.append(key)
                    }
                }
                // Each result is saved and announced as it arrives (at most every few seconds when lookups are quick), so
                // a screen fills in as the run goes rather than after a batch.
                if resolvedSinceSave > 0, pending.isEmpty || Date().timeIntervalSince(lastAnnounced) >= minAnnounceInterval {
                    try? context.save()
                    resolvedSinceSave = 0
                    lastAnnounced = Date()
                    if !pending.isEmpty { postProgress(isComplete: false) }
                }
                if !pending.isEmpty { try? await Task.sleep(nanoseconds: usedGetSongBPM ? afterGetSongBPMNanoseconds : afterDeezerOnlyNanoseconds) }
            }
            if resolvedSinceSave > 0 { try? context.save() }
            warmerTask = nil
            postProgress(isComplete: pending.isEmpty || ConnectivityGate.isOffline)
            if !pending.isEmpty, !ConnectivityGate.isOffline, !Task.isCancelled { startWarmer(context: context) }
        }
    }

    /// Replaces any older row for the key (a miss being looked up again) so the table keeps one row per track.
    private static func store(_ result: FetchResult, context: ModelContext) {
        let key = result.key
        var descriptor = FetchDescriptor<TrackBPMCacheEntry>(predicate: #Predicate { $0.cacheKey == key })
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first { context.delete(existing) }
        context.insert(TrackBPMCacheEntry(
            cacheKey: key, bpm: result.found?.bpm, source: result.found?.source.rawValue,
            timeSignature: result.found?.timeSignature, musicalKey: result.found?.musicalKey, cachedAt: Date()
        ))
    }

    private static func fetchWithRetry(key: String, target: PendingTrack) async -> FetchResult {
        usedGetSongBPM = false
        var delay: UInt64 = 500_000_000
        for attempt in 0...3 {
            do {
                let found = try await lookup(target)
                return FetchResult(key: key, found: found, succeeded: true)
            } catch {
                if error is OfflineError { return FetchResult(key: key, found: nil, succeeded: false, paused: true) }
                if attempt == 3 { return FetchResult(key: key, found: nil, succeeded: false) }
                try? await Task.sleep(nanoseconds: delay)
                delay *= 2
            }
        }
        return FetchResult(key: key, found: nil, succeeded: false)
    }

    /// GetSongBPM first, then Deezer. A problem that is only GetSongBPM's (a rate limit, a refused key) falls through
    /// to Deezer rather than blocking the lookup — but then a Deezer miss isn't trusted: it throws, so the track is
    /// retried instead of being cached as having no tempo.
    private static func lookup(_ target: PendingTrack) async throws -> Resolved? {
        var getSongBPMFailure: Error?
        if let key = GetSongBPMKeychain.activeKey(), key != getSongBPMRejectedKey {
            usedGetSongBPM = true
            do {
                if let features = try await GetSongBPMClient(apiKey: key).fetchFeatures(artist: target.artist, track: target.track) {
                    return Resolved(bpm: features.bpm, source: .getSongBPM, timeSignature: features.timeSignature, musicalKey: features.musicalKey)
                }
            } catch let error as GetSongBPMError {
                if case .invalidKey = error { getSongBPMRejectedKey = key } else { getSongBPMFailure = error }
            } catch {
                if error is OfflineError { throw error }
                getSongBPMFailure = error
            }
        }
        if let bpm = try await DeezerAPIClient().fetchTrackBPM(artist: target.artist, track: target.track) {
            return Resolved(bpm: bpm, source: .deezer)
        }
        if let getSongBPMFailure { throw getSongBPMFailure }
        return nil
    }

    private static func postProgress(isComplete: Bool) {
        NotificationCenter.default.post(name: progressNotification, object: Progress(remaining: pending.count, isComplete: isComplete))
    }

    /// Forgets a rejected key so a newly saved one is tried.
    static func keyChanged() { getSongBPMRejectedKey = nil }
}

#if DEBUG
/// `SCROBLYTICS_BPM_CHECK=1`: the tempo logic against canned replies and hand-built plays, with the answers worked out
/// by hand. Sends no request and touches no real data.
enum BPMChecks {
    static func runHeadlessIfRequested() {
        guard ProcessInfo.processInfo.environment["SCROBLYTICS_BPM_CHECK"] != nil else { return }
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            print("\(ok ? "PASS" : "FAIL")  \(name)\(ok || detail().isEmpty ? "" : " — " + detail())")
            if !ok { failures += 1 }
        }
        func parse(_ json: String) -> Result<[GetSongBPMClient.Song], Error> {
            Result { try GetSongBPMClient.parse(Data(json.utf8)) }
        }

        // GetSongBPM replies.
        let hit = #"{"search":[{"id":"x","title":"Song A","tempo":"172","time_sig":"4\/4","key_of":"Cm","artist":{"name":"Artist A"}}]}"#
        if case .success(let songs) = parse(hit), let song = songs.first {
            check("a hit is read", songs.count == 1 && song.tempo == 172 && song.timeSignature == "4/4" && song.key == "Cm" && song.artist == "Artist A")
        } else { check("a hit is read", false) }
        if case .success(let songs) = parse(#"{"search":{"error":"no result"}}"#) { check("a miss reported inside search is an empty result", songs.isEmpty) }
        else { check("a miss reported inside search is an empty result", false) }
        if case .failure(let error) = parse(#"{"error":"Invalid API Key, or inactive."}"#), case GetSongBPMError.invalidKey = error {
            check("a refused key is reported as one", true)
        } else { check("a refused key is reported as one", false) }
        if case .failure = parse(#"{"error":"Bad query."}"#) { check("a real API error is a failure, not a miss", true) } else { check("a real API error is a failure, not a miss", false) }
        if case .failure = parse(#"{"search":{"error":"rate limit exceeded"}}"#) { check("a failure reported inside search is a failure, not a miss", true) } else { check("a failure reported inside search is a failure, not a miss", false) }
        if case .failure = parse("not json") { check("an unreadable reply is a failure", true) } else { check("an unreadable reply is a failure", false) }

        // Which result is accepted.
        func song(_ title: String, _ artist: String) -> GetSongBPMClient.Song { .init(title: title, artist: artist, tempo: 100, timeSignature: nil, key: nil) }
        check("same artist and title match", GetSongBPMClient.isSameSong(song("Song A", "Artist A"), artist: "artist a", track: "SONG A"))
        check("a different artist's song of the same title is rejected", !GetSongBPMClient.isSameSong(song("Song A", "Artist B"), artist: "Artist A", track: "Song A"))
        check("a different title is rejected", !GetSongBPMClient.isSameSong(song("Song B", "Artist A"), artist: "Artist A", track: "Song A"))
        check("a version tag on either side still matches", GetSongBPMClient.isSameSong(song("Song A", "Artist A"), artist: "Artist A", track: "Song A (Remastered 2011)"))
        check("a collaboration credit matches its contributor", GetSongBPMClient.isSameSong(song("Song A", "Artist A"), artist: "Artist A & Artist B", track: "Song A"))

        // Ranges, formatting, entry.
        func bucket(_ bpm: Double) -> TempoBucket { TempoBucket.bucket(for: bpm) }
        check("tempo ranges break at 90, 120, 140 and 160, each lower bound in its own range",
              bucket(89.9) == .slow && bucket(90) == .moderate && bucket(119.99) == .moderate && bucket(120) == .upbeat
                && bucket(139.99) == .upbeat && bucket(140) == .fast && bucket(159.99) == .fast && bucket(160) == .veryFast)
        check("a whole tempo shows without a decimal, others to one place", BPMEngine.format(128) == "128" && BPMEngine.format(127.86) == "127.9" && BPMEngine.format(127.04) == "127")
        check("entry accepts a decimal comma and rounds to two places", BPMEngine.parse("127,5") == 127.5 && BPMEngine.parse(" 128.456 ") == 128.46)
        check("entry rejects zero, negatives, huge values and words", BPMEngine.parse("0") == nil && BPMEngine.parse("-5") == nil && BPMEngine.parse("1000") == nil && BPMEngine.parse("fast") == nil)

        // Precedence: correction > cached > miss > pending, and a correction keeps the detected key.
        var snapshot = BPMEngine.Snapshot()
        snapshot.cached["a"] = .init(bpm: 100, source: .getSongBPM, timeSignature: "4/4", musicalKey: "Cm")
        snapshot.overrides["a"] = 200
        snapshot.cachedMisses.insert("b")
        snapshot.cached["c"] = .init(bpm: 90, source: .deezer)
        snapshot.cachedMisses.insert("c")
        check("a correction wins over the cached tempo and keeps its time signature and key",
              snapshot.resolution(forKey: "a") == .value(.init(bpm: 200, source: .manual, timeSignature: "4/4", musicalKey: "Cm")))
        check("a cached miss is a miss", snapshot.resolution(forKey: "b") == .noMatch)
        check("a found tempo beats a stale miss row", snapshot.resolution(forKey: "c") == .value(.init(bpm: 90, source: .deezer)))
        check("an unknown track is pending, matching neither", snapshot.resolution(forKey: "z") == .pending)

        // The query fields over hand-built plays.
        let plays = ["Song A", "Song B", "Song C", "Song D"].map { ScrobbleSnapshot(artistName: "Artist A", albumName: "Album", trackName: $0, imageURL: nil, playedAt: Date(timeIntervalSince1970: 1_700_000_000)) }
        var query = BPMEngine.Snapshot()
        let key = { (track: String) in BPMEngine.cacheKey(artist: "Artist A", track: track) }
        query.cached[key("Song A")] = .init(bpm: 128, source: .getSongBPM, timeSignature: "4/4", musicalKey: "Cm")
        query.cached[key("Song B")] = .init(bpm: 70, source: .deezer)
        query.cachedMisses.insert(key("Song C"))
        var cells: [String: [String: QueryCell]] = [:]
        for field in ["bpm", "tempoBucket", "bpmSource", "timeSignature", "musicalKey"] {
            var spec = QuerySpec(target: .track)
            spec.columns = [QueryFieldRef(field)]
            guard let validated = try? spec.validate(against: .standard) else { check("\(field) is a valid column", false); continue }
            let run = QueryRun(target: .track, asOf: Date(), scrobbles: plays, allTimeScrobbles: plays, snapshots: QuerySnapshots(bpm: query))
            let result = QueryEngine.evaluate(validated, run: run)
            let column = validated.columns[0].cacheKey
            cells[field] = Dictionary(uniqueKeysWithValues: result.rows.map { ($0.entity.name, $0.cells[column] ?? .missing) })
        }
        func cell(_ field: String, _ track: String) -> QueryCell? { cells[field]?[track] }
        check("BPM shows the tempo, missing for a miss, pending for an unlooked-up track",
              cell("bpm", "Song A") == .value(.number(128)) && cell("bpm", "Song C") == .missing && cell("bpm", "Song D") == .pending)
        check("Tempo range puts 128 in Upbeat and 70 in Slow", cell("tempoBucket", "Song A") == .value(.text(TempoBucket.upbeat.rawValue)) && cell("tempoBucket", "Song B") == .value(.text(TempoBucket.slow.rawValue)))
        check("Tempo source names who supplied it", cell("bpmSource", "Song A") == .value(.text("GetSongBPM")) && cell("bpmSource", "Song B") == .value(.text("Deezer")))
        check("Time signature and key exist only where GetSongBPM supplied them",
              cell("timeSignature", "Song A") == .value(.text("4/4")) && cell("musicalKey", "Song A") == .value(.text("Cm"))
                && cell("timeSignature", "Song B") == .missing && cell("musicalKey", "Song B") == .missing)

        print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
        // SCROBLYTICS_BPM_LIVE="Artist|Track": also asks Deezer for that one track's tempo (sends only those two names).
        if let live = ProcessInfo.processInfo.environment["SCROBLYTICS_BPM_LIVE"] {
            let parts = live.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { exit(2) }
            Task {
                do {
                    let bpm = try await DeezerAPIClient().fetchTrackBPM(artist: parts[0], track: parts[1])
                    print("LIVE Deezer \(parts[0]) — \(parts[1]): \(bpm.map { String($0) } ?? "no tempo")")
                    if let key = GetSongBPMKeychain.activeKey() {
                        let found = try await GetSongBPMClient(apiKey: key).fetchFeatures(artist: parts[0], track: parts[1])
                        print("LIVE GetSongBPM \(parts[0]) — \(parts[1]): \(found.map { "\($0.bpm) \($0.timeSignature ?? "-") \($0.musicalKey ?? "-")" } ?? "no tempo")")
                    } else { print("LIVE GetSongBPM: no key") }
                } catch { print("LIVE Deezer failed: \(error)") }
                exit(failures == 0 ? 0 : 1)
            }
            return
        }
        exit(failures == 0 ? 0 : 1)
    }
}
#endif

#if DEBUG
extension BPMChecks {
    /// `SCROBLYTICS_BPM_SEED_DUMP=/path/out.tsv` (with `SCROBLYTICS_STORE_PATH` at a COPY of the store): writes the
    /// tracks the background pass would queue, in order, with their play counts. Sends no request.
    static func runSeedDumpIfRequested(container: ModelContainer) {
        guard let path = ProcessInfo.processInfo.environment["SCROBLYTICS_BPM_SEED_DUMP"] else { return }
        Task {
            let rows = (try? await BPMSeedReader(modelContainer: container).mostPlayedUnresolved(limit: 1_500, withPlays: true)) ?? []
            let lines = ["artist\ttrack\tplays"] + rows.map { "\($0.artist)\t\($0.track)\t\($0.plays)" }
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            exit(0)
        }
    }
}
#endif

/// Reads, off the main actor, the most-played tracks that still need a tempo.
@ModelActor
actor BPMSeedReader {
    struct Candidate: Sendable {
        let artist: String
        let track: String
        var plays = 0
    }

    func mostPlayedUnresolved(limit: Int, withPlays: Bool = false) throws -> [Candidate] {
        var descriptor = FetchDescriptor<Scrobble>()
        descriptor.propertiesToFetch = [\.artistName, \.trackName]
        var counts: [String: (artist: String, track: String, plays: Int)] = [:]
        for s in try modelContext.fetch(descriptor) where !s.trackName.isEmpty && !s.artistName.isEmpty {
            let key = BPMEngine.cacheKey(artist: s.artistName, track: s.trackName)
            counts[key, default: (s.artistName, s.trackName, 0)].plays += 1
        }
        let snapshot = BPMEngine.loadSnapshot(context: modelContext)
        return counts
            .filter { snapshot.resolution(forKey: $0.key) == .pending }
            .sorted { $0.value.plays != $1.value.plays ? $0.value.plays > $1.value.plays : $0.key < $1.key }
            .prefix(limit)
            .map { Candidate(artist: $0.value.artist, track: $0.value.track, plays: withPlays ? $0.value.plays : 0) }
    }
}
