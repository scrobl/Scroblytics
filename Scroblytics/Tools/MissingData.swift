import Foundation
import SwiftData

extension QueryTarget {
    /// Matches `TopChartsEntity.displayName`'s exact wording.
    var pluralLabel: String {
        switch self {
        case .artist: "Artists"
        case .album: "Albums"
        case .track: "Tracks"
        }
    }
}

/// A field this tool can check for gaps — a thin picker-metadata layer over the Field Registry's own
/// columns (`QueryReleaseDateFields.swift`/`QueryDurationFields.swift`/`QueryImageFields.swift`), never a
/// second computation of what "missing" means. Each background-resolved field is one entry here.
struct MissingDataField: Identifiable, Sendable {
    let id: String
    let label: String
    /// Valid entity types, in display order. The entity-type picker is constrained to exactly this list.
    let targets: [QueryTarget]
    /// The Field Registry column this reads.
    let queryFieldID: String
    /// nil when the field has no background-resolution queue to trigger — true today only for Images,
    /// whose `missingImage` column is a plain synchronous boolean with no pending state at all.
    let resolverKind: QueryResolverKind?
    /// The strict "field has no value" condition for the Advanced hand-off. Necessarily narrower than
    /// this tool's own list (which also surfaces still-`.pending` rows) — `QuerySpec` has no way to
    /// express "missing or pending," only `.isMissing` (confirmed absent). The UI says so plainly.
    let missingCondition: @Sendable () -> QueryCondition
    /// How to read this field's own `QueryCell` as a bucket — nil means "not missing, drop this row".
    /// NOT a generic `.missing`/`.pending` check: `missingImage` is a plain boolean flag (always wrapped
    /// as `.value(.bool(...))`, never the QueryCell's own `.missing`/`.pending` cases, which only apply
    /// to background-resolved value fields like Release Date/Duration) — a field declares its own
    /// reading here specifically so this distinction can never be silently dropped again.
    let bucket: @Sendable (QueryCell) -> MissingDataBucket?
    /// Further Query columns whose cells explain a row, and how to say so in one line (nil = no second line). Cells are keyed
    /// by field id.
    var detailFieldIDs: [String] = []
    var detailText: (@Sendable ([String: QueryCell]) -> String?)? = nil
    /// For a field whose flagged rows aren't "missing" something: the coverage line's ending ("may be merged by mistake") and
    /// the empty-state sentence. nil = the usual "missing <field>" wording.
    var wording: (coverage: String, empty: String)? = nil
    /// True when a row can be marked reviewed and left out of the list ("Keep merged").
    var canKeepMerged = false

    private static func resolvedValueField(
        id: String, label: String, targets: [QueryTarget], queryFieldID: String, resolverKind: QueryResolverKind
    ) -> MissingDataField {
        MissingDataField(
            id: id, label: label, targets: targets, queryFieldID: queryFieldID, resolverKind: resolverKind,
            missingCondition: { QueryCondition(QueryFieldRef(queryFieldID), .isMissing, []) },
            bucket: { cell in
                switch cell {
                case .missing: .missing
                case .pending: .pending
                case .value: nil
                }
            }
        )
    }

    static let all: [MissingDataField] = [
        resolvedValueField(id: "releaseDate", label: "Release Date", targets: [.album, .track], queryFieldID: "releaseDate", resolverKind: .releaseDate),
        MissingDataField(
            id: "images", label: "Images", targets: [.artist, .album, .track], queryFieldID: "missingImage", resolverKind: nil,
            missingCondition: { QueryCondition(QueryFieldRef("missingImage"), .isTrue, []) },
            bucket: { cell in if case .value(.bool(true)) = cell { .missing } else { nil } }
        ),
        resolvedValueField(id: "duration", label: "Duration", targets: [.track], queryFieldID: "duration", resolverKind: .duration),
        resolvedValueField(id: "bpm", label: "Tempo (BPM)", targets: [.track], queryFieldID: "bpm", resolverKind: .bpm),
        MissingDataField(
            id: "albumMatch", label: "Album Match", targets: [.album], queryFieldID: "needsMatchReview", resolverKind: .albumTracklists,
            missingCondition: { QueryCondition(QueryFieldRef("needsMatchReview"), .isTrue, []) },
            bucket: { cell in
                switch cell {
                // The field's own `.missing` means "no album group could be found at all" — an edge case
                // there's no "Fix album match…" to open for, not a genuine gap. Drop, don't flag.
                case .missing: nil
                case .pending: .pending
                case .value(.bool(true)): .missing
                case .value(.bool(false)), .value: nil
                }
            }
        ),
        MissingDataField(
            id: "mergedEditions", label: "Merged Editions", targets: [.album], queryFieldID: "mergedEditionReview", resolverKind: .albumTracklists,
            missingCondition: { QueryCondition(QueryFieldRef("mergedEditionReview"), .isTrue, []) },
            bucket: { cell in
                switch cell {
                case .missing: nil
                case .pending: .pending
                case .value(.bool(true)): .missing
                case .value(.bool(false)), .value: nil
                }
            },
            detailFieldIDs: ["albumOffListTracks", "albumEditionNames"],
            detailText: { cells in
                guard case .value(.number(let off))? = cells["albumOffListTracks"] else { return nil }
                var text = off == 1 ? "1 played track isn’t on the album’s tracklist" : "\(Int(off)) played tracks aren’t on the album’s tracklist"
                if case .value(.number(let names))? = cells["albumEditionNames"], names > 1 {
                    text += " · counted with \(Int(names) - 1) other edition name\(names > 2 ? "s" : "")"
                }
                return text
            },
            wording: (coverage: "may be merged by mistake", empty: "No album name looks merged by mistake."),
            canKeepMerged: true
        ),
    ]
}

enum MissingDataBucket: Sendable {
    /// Resolved, confirmed absent (or, for Images, the boolean is true) — re-resolving won't change this
    /// without new source data.
    case missing
    /// Not yet resolved at all — genuinely actionable via "Resolve now". Images never produces this.
    case pending
}

struct MissingDataRow: Identifiable, Sendable {
    let id: QueryEntityID
    let target: QueryTarget
    let artist: String
    let name: String
    let bucket: MissingDataBucket
    /// From the same `QueryResult.entityInfo` grouping pass the fields themselves read — no separate
    /// artwork-resolution pass needed, unlike the earlier Tools this session built.
    let imageURL: String?
    let album: String?
    let plays: Int
    let lastPlayed: Date?
    /// A second line explaining why the row is listed (only fields that define one).
    var detail: String? = nil
}

enum MissingDataSort: String, CaseIterable, Identifiable, Codable, Sendable {
    case alphabetical, plays, lastPlayed
    var id: String { rawValue }
    var label: String {
        switch self {
        case .alphabetical: "A–Z"
        case .plays: "Play count"
        case .lastPlayed: "Last played"
        }
    }
}

struct MissingDataResult: Sendable {
    let field: MissingDataField
    let target: QueryTarget
    /// The FULL bucketed set, never sliced — the coverage callout and counts read this directly, a row
    /// limit is applied only to what's rendered, downstream in the view.
    let rows: [MissingDataRow]
    let universeCount: Int
    var missingCount: Int { rows.reduce(0) { $0 + ($1.bucket == .missing ? 1 : 0) } }
    var pendingCount: Int { rows.reduce(0) { $0 + ($1.bucket == .pending ? 1 : 0) } }
}

enum MissingDataEngine {
    /// Fetches EVERY entity of `target` (no filtering group — `QueryEngine.evaluate` treats empty
    /// `groups` as "everything matches", giving `universeCount` as the exact denominator) with the
    /// field's column plus `plays`/`lastPlayed` (for sorting), then buckets each row in Swift: `.value` →
    /// not missing, dropped; `.missing`/`.pending` → shown. This is deliberately NOT built by filtering
    /// with `.isMissing`, which excludes `.pending` — most real gaps in a library are things never yet
    /// checked, not confirmed-absent, and this tool's whole point is surfacing both.
    static func compute(
        field: MissingDataField, target: QueryTarget,
        scrobbles: [ScrobbleSnapshot], snapshots: QuerySnapshots, now: Date = Date()
    ) -> MissingDataResult? {
        var spec = QuerySpec(target: target)
        spec.asOf = now
        spec.columns = [QueryFieldRef(field.queryFieldID), QueryFieldRef("plays"), QueryFieldRef("lastPlayed")] + field.detailFieldIDs.map { QueryFieldRef($0) }
        guard let validated = try? spec.validate(against: .standard) else { return nil }
        let run = QueryRun(target: target, asOf: now, scrobbles: scrobbles, allTimeScrobbles: scrobbles, snapshots: snapshots)
        let result = QueryEngine.evaluate(validated, run: run)
        guard let fieldKey = result.columns.first(where: { $0.field.id == field.queryFieldID })?.cacheKey,
              let playsKey = result.columns.first(where: { $0.field.id == "plays" })?.cacheKey,
              let lastPlayedKey = result.columns.first(where: { $0.field.id == "lastPlayed" })?.cacheKey else { return nil }

        var rows: [MissingDataRow] = []
        for row in result.rows {
            guard let cell = row.cells[fieldKey], let bucket = field.bucket(cell) else { continue }
            let info = result.entityInfo[row.entity.id]
            let plays: Int = if case .value(.number(let n))? = row.cells[playsKey] { Int(n) } else { 0 }
            let lastPlayed: Date? = if case .value(.date(let d))? = row.cells[lastPlayedKey] { d } else { nil }
            var detail: String?
            if let detailText = field.detailText {
                var cells: [String: QueryCell] = [:]
                for id in field.detailFieldIDs {
                    if let key = result.columns.first(where: { $0.field.id == id })?.cacheKey, let cell = row.cells[key] { cells[id] = cell }
                }
                detail = detailText(cells)
            }
            rows.append(MissingDataRow(
                id: row.entity.id, target: target, artist: row.entity.id.artist, name: row.entity.id.name,
                bucket: bucket, imageURL: info?.imageURL, album: info?.album, plays: plays, lastPlayed: lastPlayed, detail: detail
            ))
        }
        return MissingDataResult(field: field, target: target, rows: rows, universeCount: result.universeCount)
    }

    /// Cheap in-memory re-ordering, applied at render time — no re-run of `compute`. Ties always break
    /// alphabetically so ordering never depends on iteration order.
    static func sorted(_ rows: [MissingDataRow], by sort: MissingDataSort) -> [MissingDataRow] {
        switch sort {
        case .alphabetical:
            return rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .plays:
            return rows.sorted { a, b in
                if a.plays != b.plays { return a.plays > b.plays }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        case .lastPlayed:
            return rows.sorted { a, b in
                switch (a.lastPlayed, b.lastPlayed) {
                case let (l?, r?) where l != r: return l > r
                case (nil, .some): return false
                case (.some, nil): return true
                default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            }
        }
    }

    /// The equivalent condition set for "Advanced" — necessarily the STRICT "is missing" reading (see
    /// `MissingDataField.missingCondition`'s doc comment), not this tool's broader missing-or-pending view.
    static func advancedSpec(field: MissingDataField, target: QueryTarget) -> QuerySpec {
        var spec = QuerySpec(target: target)
        spec.groups = [[field.missingCondition()]]
        spec.columns = [QueryFieldRef(field.queryFieldID)] + field.detailFieldIDs.map { QueryFieldRef($0) }
        return spec
    }

    /// Triggers the existing background resolution queue for exactly the given rows — never the whole
    /// library. The Duration/Release Date engine calls are idempotent (they re-check each entity's own
    /// resolution state before enqueuing), so passing the full missing+pending set (not just `.pending`
    /// rows) is safe and simpler than pre-filtering. No-ops for a field with no resolver (Images). Returns
    /// a message to surface to the user only when something needs their attention (missing credentials);
    /// nil means it started normally.
    @MainActor
    static func resolveNow(
        field: MissingDataField, rows: [MissingDataRow], scrobbles: [ScrobbleSnapshot], turnoverGroups: TurnoverGroupCache, context: ModelContext
    ) async -> String? {
        guard let resolverKind = field.resolverKind, !rows.isEmpty else { return nil }
        switch resolverKind {
        case .duration:
            let ids = Set(rows.map(\.id))
            let matching = scrobbles.filter { s in
                !s.trackName.isEmpty && ids.contains(QueryEntityID(target: .track, artist: s.artistName, name: s.trackName))
            }
            _ = await DurationEngine.resolveDurationLookup(context: context, client: DeezerAPIClient(), scrobbles: matching)
            return nil
        case .bpm:
            let ids = Set(rows.map(\.id))
            let matching = scrobbles.filter { s in
                !s.trackName.isEmpty && ids.contains(QueryEntityID(target: .track, artist: s.artistName, name: s.trackName))
            }
            _ = BPMEngine.resolveBPMLookup(context: context, scrobbles: matching)
            return nil
        case .releaseDate:
            let ids = Set(rows.map(\.id))
            let matching = scrobbles.filter { s in
                (!s.albumName.isEmpty && ids.contains(QueryEntityID(target: .album, artist: s.artistName, name: s.albumName)))
                    || (!s.trackName.isEmpty && ids.contains(QueryEntityID(target: .track, artist: s.artistName, name: s.trackName)))
            }
            let snapshot = ReleaseDateEngine.loadSnapshot(context: context)
            ReleaseDateEngine.resolvePending(
                context: context, musicBrainz: MusicBrainzAPIClient(), deezer: DeezerAPIClient(), scrobbles: matching, snapshot: snapshot
            )
            return nil
        case .albumTracklists:
            guard let credentials = LastfmCredentialsStore.load() else {
                return "Connect Last.fm in Settings to look up album tracklists."
            }
            let client = LastfmAPIClient(apiKey: credentials.apiKey, username: credentials.username)
            let ids = Set(rows.map(\.id))
            let snapshot = AlbumTurnoverEngine.loadSnapshot(context: context)
            let byArtist = turnoverGroups.groups(for: scrobbles, separating: snapshot.separateEditions)
            var seen = Set<String>()
            var requests: [AlbumTurnoverEngine.TracklistRequest] = []
            for row in rows where ids.contains(row.id) {
                guard let groups = byArtist[row.artist], let group = AlbumTurnoverEngine.findAlbumGroup(groups, album: row.name),
                      let request = snapshot.missingRequest(for: group) else { continue }
                if seen.insert(AlbumTurnoverEngine.tracklistCacheKey(artist: request.artist, album: request.album)).inserted {
                    requests.append(request)
                }
            }
            for request in requests {
                // A transient failure is never cached by the engine, so a later Resolve retries it.
                _ = try? await AlbumTurnoverEngine.getCachedTracklist(context: context, client: client, artist: request.artist, album: request.album)
            }
            return nil
        case .tags:
            return nil
        }
    }
}

#if DEBUG
/// Verification hook: with `SCROBLYTICS_MISSINGDATA_DUMP=/path/out.tsv` set (plus
/// `SCROBLYTICS_MISSINGDATA_FIELD`, `SCROBLYTICS_MISSINGDATA_TARGET`), computes Missing Data against the
/// real store at launch, writes it, and quits.
enum MissingDataDebugEval {
    @MainActor
    static func runHeadlessIfRequested(container: ModelContainer) {
        guard let path = ProcessInfo.processInfo.environment["SCROBLYTICS_MISSINGDATA_DUMP"] else { return }
        Task { @MainActor in
            let context = container.mainContext
            let raw = try context.fetch(FetchDescriptor<Scrobble>(sortBy: [SortDescriptor(\.playedAt)])).map(\.snapshot)
            let scrobbles = QueryIdentity.canonicalizingArtists(raw)
            let fieldID = ProcessInfo.processInfo.environment["SCROBLYTICS_MISSINGDATA_FIELD"] ?? "duration"
            let field = MissingDataField.all.first { $0.id == fieldID } ?? MissingDataField.all[2]
            let targetRaw = ProcessInfo.processInfo.environment["SCROBLYTICS_MISSINGDATA_TARGET"] ?? field.targets[0].rawValue
            let target = QueryTarget(rawValue: targetRaw) ?? field.targets[0]
            let loaded = await QuerySnapshotReader.loadAll(container: container)
            let snapshots = QuerySnapshots(
                durations: loaded.durations, bpm: loaded.bpm, releaseDates: loaded.releaseDates, turnover: loaded.turnover, images: loaded.images
            )
            let result = MissingDataEngine.compute(field: field, target: target, scrobbles: scrobbles, snapshots: snapshots)
            var lines = ["missingCount\tpendingCount\tuniverseCount"]
            if let result { lines.append("\(result.missingCount)\t\(result.pendingCount)\t\(result.universeCount)") }
            lines.append(contentsOf: (result?.rows ?? []).map { "\($0.artist)\t\($0.name)\t\($0.bucket)\t\($0.plays)\t\($0.lastPlayed?.description ?? "")" })
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            exit(0)
        }
    }
}
#endif
