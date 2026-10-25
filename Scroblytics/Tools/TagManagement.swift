import Foundation
import SwiftData
import SwiftUI

// MARK: - Source tracks and the scrobble index

/// A track as a tag source supplies it: an Apple Music playlist row or a Query result row.
struct TagSourceTrack: Sendable, Hashable {
    let artist: String
    let track: String
    let album: String?
    /// Seconds, when the source knows it (Music does).
    let duration: Double?
}

/// A track as the scrobble history knows it — the identity Last.fm tags (artist + exact title), with where it's
/// been played.
struct ScrobbledTrack: Sendable {
    let artist: String
    let track: String
    var plays: Int
    /// Raw album name → plays.
    var albums: [String: Int]

    var key: String { TextNormalization.lovedKey(artist: artist, track: track) }
}

/// Every distinct scrobbled track, indexed three ways: by exact Last.fm identity, by the Apple Music match key (which
/// folds edition suffixes and credit variants), and by a near-match index for spelling differences.
struct ScrobbleTrackIndex: Sendable {
    let tracks: [String: ScrobbledTrack]
    private let byMatchKey: [String: [String]]
    private let near: LovedStatusAuditEngine.NearIndex
    private let nearKeys: [String]

    nonisolated init(scrobbles: [ScrobbleSnapshot]) {
        var tracks: [String: ScrobbledTrack] = [:]
        for s in scrobbles where !s.trackName.isEmpty && !s.artistName.isEmpty {
            let key = TextNormalization.lovedKey(artist: s.artistName, track: s.trackName)
            if tracks[key] == nil { tracks[key] = ScrobbledTrack(artist: s.artistName, track: s.trackName, plays: 0, albums: [:]) }
            tracks[key]!.plays += 1
            if !s.albumName.isEmpty { tracks[key]!.albums[s.albumName, default: 0] += 1 }
        }
        self.tracks = tracks
        let ordered = tracks.keys.sorted()
        nearKeys = ordered
        near = LovedStatusAuditEngine.NearIndex(ordered.map { .init(artist: tracks[$0]!.artist, track: tracks[$0]!.track) })
        var byMatchKey: [String: [String]] = [:]
        for key in ordered {
            let t = tracks[key]!
            byMatchKey[AppleMusicMatcher.durationMatchKey(artist: t.artist, track: t.track), default: []].append(key)
        }
        // Most-played spelling first, so a variant match tags the one actually in use.
        for (k, keys) in byMatchKey { byMatchKey[k] = keys.sorted { tracks[$0]!.plays > tracks[$1]!.plays } }
        self.byMatchKey = byMatchKey
    }

    enum Match: Sendable {
        /// The exact Last.fm identity.
        case exact(ScrobbledTrack)
        /// Same artist and title after folding edition suffixes / credits ("Song (Remastered)" → "Song").
        case variant(ScrobbledTrack)
        /// A close-but-not-certain spelling — never tagged without the user's say-so.
        case uncertain(ScrobbledTrack)
        case notScrobbled
    }

    nonisolated func match(artist: String, track: String) -> Match {
        if let exact = tracks[TextNormalization.lovedKey(artist: artist, track: track)] { return .exact(exact) }
        if let key = byMatchKey[AppleMusicMatcher.durationMatchKey(artist: artist, track: track)]?.first, let t = tracks[key] { return .variant(t) }
        if let candidate = near.nearest(artist: artist, track: track),
           let t = tracks[TextNormalization.lovedKey(artist: candidate.artist, track: candidate.track)] { return .uncertain(t) }
        return .notScrobbled
    }
}

// MARK: - Other versions (the album-scope check)

/// Where else a tag on this track would land. Last.fm tags an (artist, title) identity, so every album carrying that
/// exact title gets it — live cuts and other editions included.
struct TagVersionConflict: Sendable {
    struct Other: Sendable, Hashable {
        let album: String
        /// Plays of the track under that album in the scrobble history.
        let plays: Int
        /// Seconds, from the Music library when it has this version.
        let duration: Double?
        /// `duration` minus this version's, when both are known.
        let delta: Double?
    }

    enum Kind: Sendable {
        /// Another version differs by 30 s or more — probably a different recording (live, extended, acoustic).
        case differentRecording
        /// Every other version is within 30 s — typically a reissue or remaster of the same recording.
        case sameRecording
        /// Couldn't compare lengths (no Music read, or a version Music doesn't have).
        case unknownDuration
    }

    let kind: Kind
    let others: [Other]
    var affectedPlays: Int { others.reduce(0) { $0 + $1.plays } }
}

extension AlbumScopeWarningEngine {
    /// The ONE place this is decided for bulk tagging: other albums (from scrobbles and, when given, the Music library)
    /// whose same-titled track the tag would also reach, excluding the albums the source itself contains.
    nonisolated static func versionConflict(
        target: ScrobbledTrack, sourceAlbums: Set<String>, thisDuration: Double?, libraryVersions: [AppleMusicTrack]
    ) -> TagVersionConflict? {
        func norm(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let excluded = Set(sourceAlbums.map(norm))
        var byAlbum: [String: (name: String, plays: Int, duration: Double?)] = [:]
        for (album, plays) in target.albums where !excluded.contains(norm(album)) {
            byAlbum[norm(album)] = (album, plays, nil)
        }
        for version in libraryVersions where !version.album.isEmpty && !excluded.contains(norm(version.album)) {
            var entry = byAlbum[norm(version.album)] ?? (version.album, 0, nil)
            if entry.duration == nil, version.duration > 0 { entry.duration = version.duration }
            byAlbum[norm(version.album)] = entry
        }
        guard !byAlbum.isEmpty else { return nil }
        let others = byAlbum.values.map { entry in
            TagVersionConflict.Other(
                album: entry.name, plays: entry.plays, duration: entry.duration,
                delta: (entry.duration != nil && thisDuration != nil) ? entry.duration! - thisDuration! : nil
            )
        }.sorted { $0.plays != $1.plays ? $0.plays > $1.plays : $0.album < $1.album }
        let threshold = Double(sharpenThresholdSeconds)
        let kind: TagVersionConflict.Kind
        if others.contains(where: { ($0.delta.map { abs($0) } ?? 0) >= threshold }) { kind = .differentRecording }
        else if others.allSatisfy({ $0.delta != nil }) { kind = .sameRecording }
        else { kind = .unknownDuration }
        return TagVersionConflict(kind: kind, others: others)
    }
}

// MARK: - The plan

enum TagMode: String, Codable, CaseIterable, Sendable {
    /// Add the tags to every matched track that lacks them.
    case add
    /// Remove the tags from every matched track that has them.
    case remove
    /// Add as `add` does, and also offer to remove the tags from tracks that have left the source.
    case mirror
}

struct TagPlanItem: Identifiable, Sendable {
    enum Action: Sendable { case add, remove, alreadyDone }

    let target: ScrobbledTrack
    let action: Action
    /// The tags this item would add (action .add) or remove (.remove).
    let tags: [String]
    /// The source's own spelling/album, when it differs from the scrobbled identity (a variant match).
    let sourceTrack: TagSourceTrack?
    let viaVariant: Bool
    let conflict: TagVersionConflict?
    var id: String { "\(action)|\(target.key)" }
}

struct TagPlan: Sendable {
    var adds: [TagPlanItem] = []
    var removals: [TagPlanItem] = []
    var alreadyDone: [TagPlanItem] = []
    var notScrobbled: [TagSourceTrack] = []
    var uncertain: [(source: TagSourceTrack, candidate: ScrobbledTrack)] = []
    var sourceCount = 0
    /// Distinct tracks the source resolved to.
    var resolvedCount = 0
    /// Whether the personal-tag cache has ever been synced in full — until then "already tagged" proves nothing.
    var personalTagsKnown = true
}

enum TagPlanEngine {
    /// Turns a source's tracks into what would change. Pure: no network, no writes.
    nonisolated static func plan(
        source: [TagSourceTrack], tags rawTags: [String], mode: TagMode,
        index: ScrobbleTrackIndex, personal: [String: [String]], personalTagsKnown: Bool,
        library: [AppleMusicTrack]?
    ) -> TagPlan {
        let tags = LastfmTagNormalization.normalizeList(rawTags)
        var plan = TagPlan()
        plan.sourceCount = source.count
        plan.personalTagsKnown = personalTagsKnown
        guard !tags.isEmpty else { return plan }

        // Library versions by Last.fm identity (exact artist + title), for the other-version check.
        var libraryByKey: [String: [AppleMusicTrack]] = [:]
        if let library {
            for t in library { libraryByKey[TextNormalization.lovedKey(artist: t.artist, track: t.name), default: []].append(t) }
        }

        struct Resolved { var target: ScrobbledTrack; var sources: [TagSourceTrack]; var viaVariant: Bool }
        var resolved: [String: Resolved] = [:]
        var order: [String] = []
        var uncertainKeys = Set<String>()
        for s in source {
            let match = index.match(artist: s.artist, track: s.track)
            switch match {
            case .exact(let t), .variant(let t):
                var isVariant = false
                if case .variant = match { isVariant = true }
                if resolved[t.key] == nil { resolved[t.key] = Resolved(target: t, sources: [], viaVariant: isVariant); order.append(t.key) }
                resolved[t.key]!.sources.append(s)
            case .uncertain(let t):
                plan.uncertain.append((s, t))
                uncertainKeys.insert(t.key)
            case .notScrobbled:
                plan.notScrobbled.append(s)
            }
        }
        plan.resolvedCount = resolved.count

        func ownTags(_ t: ScrobbledTrack) -> Set<String> {
            Set(personal[EntityTagKey.make(kind: .track, artist: t.artist, name: t.track)] ?? [])
        }
        func conflict(for r: Resolved) -> TagVersionConflict? {
            AlbumScopeWarningEngine.versionConflict(
                target: r.target,
                sourceAlbums: Set(r.sources.compactMap(\.album)),
                thisDuration: r.sources.compactMap(\.duration).first,
                libraryVersions: libraryByKey[r.target.key] ?? []
            )
        }

        for key in order {
            let r = resolved[key]!
            let has = ownTags(r.target)
            let first = r.sources.first
            switch mode {
            case .add, .mirror:
                let missing = tags.filter { !has.contains($0) }
                if missing.isEmpty {
                    plan.alreadyDone.append(TagPlanItem(target: r.target, action: .alreadyDone, tags: tags, sourceTrack: first, viaVariant: r.viaVariant, conflict: nil))
                } else {
                    plan.adds.append(TagPlanItem(target: r.target, action: .add, tags: missing, sourceTrack: first, viaVariant: r.viaVariant, conflict: conflict(for: r)))
                }
            case .remove:
                let present = tags.filter { has.contains($0) }
                if present.isEmpty {
                    plan.alreadyDone.append(TagPlanItem(target: r.target, action: .alreadyDone, tags: tags, sourceTrack: first, viaVariant: r.viaVariant, conflict: nil))
                } else {
                    plan.removals.append(TagPlanItem(target: r.target, action: .remove, tags: present, sourceTrack: first, viaVariant: r.viaVariant, conflict: conflict(for: r)))
                }
            }
        }

        if mode == .mirror {
            // Tracks the cache says carry one of the tags that the source no longer contains. Uncertain matches count
            // as still in the source — a spelling difference is not a reason to strip a tag.
            let inSource = Set(resolved.keys).union(uncertainKeys)
            for (cacheKey, cached) in personal {
                let parts = cacheKey.components(separatedBy: "\u{241F}")
                guard parts.count == 3, parts[0] == TopChartsEntity.track.rawValue else { continue }
                let key = TextNormalization.lovedKey(artist: parts[1], track: parts[2])
                guard !inSource.contains(key) else { continue }
                let present = tags.filter { cached.contains($0) }
                guard !present.isEmpty else { continue }
                let target = index.tracks[key] ?? ScrobbledTrack(artist: parts[1], track: parts[2], plays: 0, albums: [:])
                plan.removals.append(TagPlanItem(target: target, action: .remove, tags: present, sourceTrack: nil, viaVariant: false, conflict: nil))
            }
            plan.removals.sort { ($0.target.artist.lowercased(), $0.target.track.lowercased()) < ($1.target.artist.lowercased(), $1.target.track.lowercased()) }
        }
        return plan
    }
}

// MARK: - Query as a source

enum TagQuerySourceError: LocalizedError {
    case notTracks(String)
    case unreadable

    var errorDescription: String? {
        switch self {
        case .notTracks(let target): "This saved set lists \(target), not tracks. Tags here apply to tracks."
        case .unreadable: "This saved set couldn’t be read."
        }
    }
}

/// Runs a saved Query condition set and returns the tracks it matches — the same engine and snapshots the Query tool
/// uses, so the tool previews exactly the rows Query would list.
@MainActor
enum TagQuerySource {
    static func tracks(for set: SavedConditionSet, container: ModelContainer, popularity: PopularityStore?) async throws -> [TagSourceTrack] {
        guard let spec = try? QuerySpec.decoder().decode(QuerySpec.self, from: set.specJSON) else { throw TagQuerySourceError.unreadable }
        guard spec.target == .track else { throw TagQuerySourceError.notTracks(spec.target.pluralLabel.lowercased()) }
        let validated = try spec.validate(against: .standard)
        let scrobbles = try await offMain {
            try await ScrobbleHistoryCache.shared.canonicalSnapshots(container: container)
        }
        let loaded = await QuerySnapshotReader.loadAll(container: container)
        let snapshots = QuerySnapshots(
            popularity: popularity?.snapshot ?? .empty, durations: loaded.durations, releaseDates: loaded.releaseDates,
            turnover: loaded.turnover, lovedKeys: loaded.lovedKeys, flaggedKeys: loaded.flaggedKeys,
            entityTags: loaded.entityTags, libraryPresence: loaded.libraryPresence, weather: loaded.weather, images: loaded.images
        )
        let result = await Task.detached(priority: .userInitiated) { () -> QueryResult in
            let asOf = validated.spec.asOf ?? Date()
            let run = QueryRun(target: .track, asOf: asOf, scrobbles: validated.spec.countedPlays(scrobbles, weather: snapshots.weather), allTimeScrobbles: scrobbles, snapshots: snapshots)
            return QueryEngine.evaluate(validated, run: run)
        }.value
        return result.rows.compactMap { row in
            guard row.entity.target == .track, !row.entity.artist.isEmpty else { return nil }
            return TagSourceTrack(artist: row.entity.artist, track: row.entity.name, album: result.entityInfo[row.id]?.album, duration: nil)
        }
    }
}

/// Personal tags and whether they've been synced, read off the main actor.
@ModelActor
actor TagPersonalReader {
    func snapshot() -> (personal: [String: [String]], synced: Bool) {
        var personal: [String: [String]] = [:]
        for row in (try? modelContext.fetch(FetchDescriptor<UserEntityTagCacheEntry>())) ?? [] { personal[row.cacheKey] = row.tags }
        var synced = false
        if let username = LastfmCredentialsStore.load()?.username {
            synced = EntityTagsEngine.personalTagsSyncedAt(context: modelContext, username: username) != nil
        }
        return (personal, synced)
    }
}

// MARK: - Runtime

extension View {
    /// Everything the tools keep alive at app level, as ONE modifier: the gap-badge store, and the tag writer (which
    /// must outlive the Tag Management page). `ContentView`'s modifier chain is at the compiler's limit.
    func toolRuntime(
        gapBadges: LibraryGapBadgeStore, tagWriter: TagWriteRunner, work: BackgroundWorkStore, container: ModelContainer,
        askRouter: AskSimilarRouter, askSuggestions: AskSuggestionStore, nowPlaying: NowPlayingStore, onAskSimilar: @escaping () -> Void,
        onAccountConnected: @escaping () -> Void, onStopRequested: @escaping () -> Void, onOpenTool: @escaping (ToolDescriptor.Kind) -> Void
    ) -> some View {
        libraryGapBadges(gapBadges, container: container)
            .connectivityPrompt()
            .environment(nowPlaying)
            .environment(tagWriter)
            .environment(askRouter)
            .environment(askSuggestions)
            .task { askSuggestions.markStale(container: container) }
            .onReceive(NotificationCenter.default.publisher(for: .scrobbleSyncDidComplete)) { _ in
                askSuggestions.markStale(container: container)
            }
            .onChange(of: askRouter.pending?.id) { if askRouter.pending != nil { onAskSimilar() } }
            .onReceive(NotificationCenter.default.publisher(for: .lastfmAccountConnected)) { _ in onAccountConnected() }
            .onReceive(NotificationCenter.default.publisher(for: .syncRequested)) { _ in onAccountConnected() }
            .onReceive(NotificationCenter.default.publisher(for: .syncStopRequested)) { _ in onStopRequested() }
            .onReceive(NotificationCenter.default.publisher(for: .openToolRequested)) { note in
                if let kind = note.object as? ToolDescriptor.Kind { onOpenTool(kind) }
            }
            .onAppear { tagWriter.work = work }
    }
}

// MARK: - Writing

struct TagWriteOp: Sendable, Hashable {
    let artist: String
    let track: String
    let add: [String]
    let remove: [String]
}

/// Applies tag changes to Last.fm one track at a time, through the existing `LastfmWriteClient` (so the same
/// authorization, 10-tags-per-call cap and normalization as the single-track flow), and keeps the local personal-tag
/// cache in step so the next preview already knows. App-level and observable: a long run continues while you look at
/// other pages, reports to the background-work strip, and can be cancelled. Rate-limited, and idempotent — running
/// the same preview again only finds what's left.
@MainActor
@Observable
final class TagWriteRunner {
    struct Failure: Identifiable, Sendable {
        let id = UUID()
        let artist: String
        let track: String
        let message: String
    }

    struct Summary: Sendable {
        var applied = 0
        var failures: [Failure] = []
        var cancelled = false
        var stoppedEarly: String?
        var total = 0
    }

    enum State {
        case idle
        case running(done: Int, total: Int)
        case finished(Summary)
    }

    private(set) var state: State = .idle
    private var task: Task<Void, Never>?
    /// The background-work strip this run reports to; set once by `toolRuntime`.
    var work: BackgroundWorkStore?

    var isRunning: Bool { if case .running = state { true } else { false } }

    /// Seconds between Last.fm calls — about 3 a second, comfortably inside the API's limits.
    nonisolated static let callInterval: TimeInterval = 0.33
    nonisolated static let rateLimitBackoff: TimeInterval = 5

    func cancel() { task?.cancel() }

    func dismissResult() { if case .finished = state { state = .idle } }

    func start(ops: [TagWriteOp], context: ModelContext, onFinished: @escaping @MainActor (Summary) -> Void = { _ in }) {
        guard !isRunning, !ops.isEmpty else { return }
        guard let credentials = LastfmCredentialsStore.load(), let secret = credentials.apiSecret, let sessionKey = credentials.sessionKey else {
            var summary = Summary()
            summary.stoppedEarly = "Connect Track Actions in Settings first."
            state = .finished(summary)
            return
        }
        state = .running(done: 0, total: ops.count)
        let work = self.work
        work?.report(.tagWrites, remaining: ops.count, total: ops.count)
        task = Task { [weak self] in
            var summary = Summary()
            summary.total = ops.count
            for (index, op) in ops.enumerated() {
                if Task.isCancelled { summary.cancelled = true; break }
                do {
                    try await Self.perform(op, credentials: credentials, secret: secret, sessionKey: sessionKey)
                    Self.patchCache(op, context: context, username: credentials.username)
                    summary.applied += 1
                } catch let error as LastfmAPIError where Self.isAuthFailure(error) {
                    summary.stoppedEarly = describeSyncError(error)
                    break
                } catch {
                    summary.failures.append(Failure(artist: op.artist, track: op.track, message: describeSyncError(error)))
                }
                self?.state = .running(done: index + 1, total: ops.count)
                work?.report(.tagWrites, remaining: max(0, ops.count - index - 1), total: ops.count, failed: summary.failures.count)
            }
            work?.finish(.tagWrites, failed: summary.failures.count)
            self?.state = .finished(summary)
            onFinished(summary)
        }
    }

    // MARK: Per-op work

    private static func isAuthFailure(_ error: LastfmAPIError) -> Bool {
        if case .api(let code, _) = error { return [4, 9, 10, 26].contains(code) }
        return false
    }

    private static func perform(_ op: TagWriteOp, credentials: LastfmCredentials, secret: String, sessionKey: String) async throws {
        for tag in op.remove {
            do {
                try await withRetry {
                    try await LastfmWriteClient.removeTag(
                        apiKey: credentials.apiKey, secret: secret, sessionKey: sessionKey, entity: .track,
                        artist: op.artist, album: nil, track: op.track, tag: tag
                    )
                }
            } catch LastfmAPIError.api(let code, _) where code == 6 {
                // The tag isn't there to remove — which is the state we wanted.
            }
        }
        let normalized = LastfmTagNormalization.normalizeList(op.add)
        var start = 0
        while start < normalized.count {
            let chunk = Array(normalized[start..<min(start + LastfmTagNormalization.maxTagsPerCall, normalized.count)])
            try await withRetry {
                try await LastfmWriteClient.addTags(
                    apiKey: credentials.apiKey, secret: secret, sessionKey: sessionKey, entity: .track,
                    artist: op.artist, album: nil, track: op.track, tags: chunk
                )
            }
            start += chunk.count
        }
    }

    /// One Last.fm call, paced, with a bounded retry for the transient cases (rate limit, network).
    private static func withRetry(_ call: () async throws -> Void) async throws {
        var attempt = 0
        while true {
            try await Task.sleep(nanoseconds: UInt64(callInterval * 1_000_000_000))
            do {
                try await call()
                return
            } catch let error as LastfmAPIError {
                attempt += 1
                var transient = false
                switch error {
                case .api(let code, _): transient = code == 29 || code == 11 || code == 16
                case .network, .http: transient = true
                default: break
                }
                guard transient, attempt <= 3 else { throw error }
                try await Task.sleep(nanoseconds: UInt64(rateLimitBackoff * Double(attempt) * 1_000_000_000))
            }
        }
    }

    private static func patchCache(_ op: TagWriteOp, context: ModelContext, username: String) {
        for tag in op.remove {
            EntityTagsEngine.patchUserTags(context: context, kind: .track, artist: op.artist, name: op.track, removing: tag)
        }
        if !op.add.isEmpty {
            EntityTagsEngine.patchUserTags(context: context, kind: .track, artist: op.artist, name: op.track, adding: LastfmTagNormalization.normalizeList(op.add))
            PersonalTagVocabulary.merge(op.add, for: username)
        }
    }
}

#if DEBUG
/// Verification hook, read-only: `SCROBLYTICS_TAGPLAN_DUMP=/path` with `SCROBLYTICS_TAGPLAN_PLAYLIST=<name>` and
/// `SCROBLYTICS_TAGPLAN_TAGS=a,b` (and optionally `SCROBLYTICS_TAGPLAN_MODE=add|remove|mirror`) reads that Music
/// playlist and library, builds the plan against the store's scrobbles and cached personal tags, and writes the counts
/// and every row. Never writes tags.
enum TagPlanDebugEval {
    @MainActor
    static func runHeadlessIfRequested(container: ModelContainer) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["SCROBLYTICS_TAGPLAN_DUMP"] else { return }
        Task { @MainActor in
            var out: [String] = []
            defer { try? out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8); exit(0) }
            do {
                let started = Date()
                if env["SCROBLYTICS_TAGPLAN_BACKUP"] != nil {
                    // Rules in a native backup: written, decoded, restored; an older archive leaves them alone.
                    let context = container.mainContext
                    let a = TagPlaylistRule(playlistPersistentID: "6A6C22258A78A7E2", playlistName: "Running - All", tags: ["running"], mirrorRemovals: true, lastAppliedAt: Date(timeIntervalSince1970: 1_790_000_000))
                    let b = TagPlaylistRule(playlistPersistentID: "8683A47E6F522D7D", playlistName: "Running - Shortlist", tags: ["running", "shortlist"])
                    context.insert(a); context.insert(b); try context.save()
                    let document = try NativeBackupEngine.makeDocument(context: context)
                    let (archive, summary) = try NativeBackupEngine.inspect(document: document)
                    out.append("BACKUP archive tagRules=\(archive.tagRules?.map { "\($0.playlistName) \($0.tags) mirror=\($0.mirrorRemovals)" } ?? []) summary=\(summary.description)")
                    for rule in try context.fetch(FetchDescriptor<TagPlaylistRule>()) { context.delete(rule) }
                    try context.save()
                    out.append("BACKUP cleared: \(try context.fetch(FetchDescriptor<TagPlaylistRule>()).isEmpty)")
                    try NativeBackupEngine.restoreTagRules(archive.tagRules, context: context)
                    let restored = try context.fetch(FetchDescriptor<TagPlaylistRule>()).sorted { $0.playlistName < $1.playlistName }
                    out.append("BACKUP restored: \(restored.map { "\($0.playlistName) \($0.tags) mirror=\($0.mirrorRemovals) applied=\($0.lastAppliedAt != nil) id-kept=\([a.id, b.id].contains($0.id))" })")
                    try NativeBackupEngine.restoreTagRules(nil, context: context)
                    out.append("BACKUP old archive (nil) keeps rules: \(try context.fetch(FetchDescriptor<TagPlaylistRule>()).count == 2)")
                    if var json = try JSONSerialization.jsonObject(with: document.data) as? [String: Any] {
                        json.removeValue(forKey: "tagRules")
                        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                        let old = try decoder.decode(NativeBackupFormat.Archive.self, from: try JSONSerialization.data(withJSONObject: json))
                        out.append("BACKUP archive without the field decodes: tagRules=\(String(describing: old.tagRules))")
                    }
                    try NativeBackupEngine.restoreTagRules([], context: context)
                    out.append("BACKUP archive with none clears: \(try context.fetch(FetchDescriptor<TagPlaylistRule>()).isEmpty)")
                    return
                }
                if env["SCROBLYTICS_TAGPLAN_QUERY"] != nil {
                    // Query as a source: loved AND at least 20 plays, through the real saved-set path.
                    var spec = QuerySpec(target: .track)
                    spec.groups = [[QueryCondition("loved", .isTrue), QueryCondition("plays", .greaterThanOrEqual, [.number(20)])]]
                    let set = SavedConditionSet(name: "debug", specJSON: try QuerySpec.encoder().encode(spec))
                    let started = Date()
                    let rows = try await TagQuerySource.tracks(for: set, container: container, popularity: nil)
                    out.append("QUERYSOURCE rows=\(rows.count) in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
                    for r in rows { out.append("QT\t\(r.artist)\t\(r.track)\t\(r.album ?? "")") }
                    if let albumSet = try container.mainContext.fetch(FetchDescriptor<SavedConditionSet>()).first(where: { (try? QuerySpec.decoder().decode(QuerySpec.self, from: $0.specJSON).target) == .album }) {
                        do { _ = try await TagQuerySource.tracks(for: albumSet, container: container, popularity: nil); out.append("ALBUMSET unexpectedly worked") }
                        catch { out.append("ALBUMSET error: \(error.localizedDescription)") }
                    }
                    return
                }
                let playlists = try await AppleMusicPlaylistReader.listPlaylists()
                out.append("PLAYLISTS \(playlists.count) listed; smart=\(playlists.filter(\.isSmart).count)")
                guard let name = env["SCROBLYTICS_TAGPLAN_PLAYLIST"], let playlist = playlists.first(where: { $0.name == name }) else {
                    out.append("ERROR playlist not found")
                    for p in playlists.prefix(400) { out.append("PL\t\(p.id)\t\(p.name)\t\(p.isSmart)") }
                    return
                }
                let tracks = try await AppleMusicPlaylistReader.readPlaylist(id: playlist.id)
                let library = try await AppleMusicPlaylistReader.readLibrary()
                if env["SCROBLYTICS_TAGPLAN_DUMPTRACKS"] != nil {
                    for t in tracks { out.append("PT\t\(t.name)\t\(t.artist)\t\(t.album)\t\(t.duration)") }
                }
                out.append("READ playlist=\(playlist.name) id=\(playlist.id) smart=\(playlist.isSmart) tracks=\(tracks.count) library=\(library.count) in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
                let scrobbles = try await offMain {
                    try await ScrobbleHistoryCache.shared.canonicalSnapshots(container: container)
                }
                let t1 = Date()
                let index = ScrobbleTrackIndex(scrobbles: scrobbles)
                out.append("INDEX distinct scrobbled tracks=\(index.tracks.count) built in \(String(format: "%.2f", Date().timeIntervalSince(t1)))s")
                let snapshot = EntityTagsEngine.loadSnapshot(context: container.mainContext)
                let tags = (env["SCROBLYTICS_TAGPLAN_TAGS"] ?? "").split(separator: ",").map(String.init)
                let mode = TagMode(rawValue: env["SCROBLYTICS_TAGPLAN_MODE"] ?? "add") ?? .add
                let source = tracks.map { TagSourceTrack(artist: $0.artist, track: $0.name, album: $0.album, duration: $0.duration) }
                let t2 = Date()
                let plan = TagPlanEngine.plan(
                    source: source, tags: tags, mode: mode, index: index, personal: snapshot.personal,
                    personalTagsKnown: snapshot.personalSynced, library: library
                )
                out.append("PLAN mode=\(mode.rawValue) tags=\(tags) source=\(plan.sourceCount) resolved=\(plan.resolvedCount) adds=\(plan.adds.count) removals=\(plan.removals.count) already=\(plan.alreadyDone.count) notScrobbled=\(plan.notScrobbled.count) uncertain=\(plan.uncertain.count) personalSynced=\(plan.personalTagsKnown) in \(String(format: "%.2f", Date().timeIntervalSince(t2)))s")
                let items = plan.adds + plan.removals + plan.alreadyDone
                let conflicts = items.compactMap { item in item.conflict.map { (item, $0) } }
                out.append("CONFLICTS total=\(conflicts.count) different=\(conflicts.filter { $0.1.kind == .differentRecording }.count) same=\(conflicts.filter { $0.1.kind == .sameRecording }.count) unknown=\(conflicts.filter { $0.1.kind == .unknownDuration }.count)")
                for (item, c) in conflicts {
                    let others = c.others.map { "\($0.album) [\($0.plays) plays, \($0.duration.map { String(Int($0)) } ?? "?")s, delta \($0.delta.map { String(Int($0)) } ?? "?")]" }.joined(separator: "; ")
                    out.append("CONFLICT\t\(c.kind)\t\(item.target.artist)\t\(item.target.track)\tthis=\(item.sourceTrack?.album ?? "")\t\(others)")
                }
                for item in plan.adds { out.append("ADD\t\(item.target.artist)\t\(item.target.track)\t\(item.tags.joined(separator: ","))\tvariant=\(item.viaVariant)") }
                for item in plan.removals { out.append("REMOVE\t\(item.target.artist)\t\(item.target.track)\t\(item.tags.joined(separator: ","))") }
                for item in plan.alreadyDone { out.append("ALREADY\t\(item.target.artist)\t\(item.target.track)") }
                for s in plan.notScrobbled { out.append("NOTSCROBBLED\t\(s.artist)\t\(s.track)\t\(s.album ?? "")") }
                for u in plan.uncertain { out.append("UNCERTAIN\t\(u.source.artist)\t\(u.source.track)\t->\t\(u.candidate.artist)\t\(u.candidate.track)") }
            } catch {
                out.append("ERROR: \(error)")
            }
        }
    }
}
#endif
