import Foundation
import SwiftUI
import SwiftData

/// One scrobbled track's library status as of the last check — a value copy of `LibraryPresenceEntry`.
struct LibraryPresenceRecord: Sendable, Equatable {
    var matchKey: String
    var artist: String
    var track: String
    var inLibrary: Bool
    var lastSeenAt: Date?
    var firstCheckedAt: Date
    var nearMatch: String?
    var cloudStatus: String?

    static let unavailableCloudStatus = "no longer available"

    var status: LibraryGapStatus {
        if inLibrary { return cloudStatus != nil ? .unavailable : .present }
        if nearMatch != nil { return .uncertain }
        return lastSeenAt != nil ? .removed : .neverInLibrary
    }
}

enum LibraryGapStatus: String, Sendable, CaseIterable {
    /// In the library — not a gap.
    case present
    /// In the library but greyed out in Music ("no longer available").
    case unavailable
    /// Was in the library at an earlier check, isn't now.
    case removed
    /// Not in the library, and never seen there (as far as the checks go).
    case neverInLibrary
    /// Not under this title, but Music has something close — probably a spelling or credit variant.
    case uncertain

    var isGap: Bool { self != .present }
}

/// A scrobbled track and how much it's been played, keyed by the Apple Music match key.
struct LibraryTrackUsage: Sendable {
    let matchKey: String
    let artist: String
    let track: String
    let plays: Int
    let lastPlayed: Date
}

struct LibraryGapRow: Identifiable, Sendable {
    let record: LibraryPresenceRecord
    let plays: Int
    let lastPlayed: Date?
    /// The user confirmed this track isn't in the library (it was Uncertain), so it shows as Never in library or Removed.
    var isConfirmed = false
    var id: String { record.matchKey }
}

/// Decides, for every distinct scrobbled track, whether it's in the Apple Music library — entirely in memory from
/// the same one-shot library read the Loved Status Audit uses, matched by the same key
/// (`AppleMusicMatcher.durationMatchKey`) and the same near-match test. Only rows whose state CHANGED are
/// returned for writing, so a run that finds nothing new writes nothing.
enum LibraryGapsEngine {
    /// `durationMatchKey` joins artist and title with a NUL, which SQLite silently truncates — that would collapse
    /// every track of an artist onto one `@Attribute(.unique)` row. The persisted/queried key swaps in a printable
    /// separator (the same fix the album identity key needed; see `TextNormalization.albumKeySeparator`).
    nonisolated static func key(artist: String, track: String) -> String {
        AppleMusicMatcher.durationMatchKey(artist: artist, track: track).replacingOccurrences(of: "\u{0}", with: "\u{241F}")
    }

    /// Distinct tracks from scrobble history, merged by match key (a remaster and its original are one track here,
    /// as everywhere Apple Music is matched). Display spelling is the most-played one.
    nonisolated static func usage(from scrobbles: [ScrobbleSnapshot]) -> [LibraryTrackUsage] {
        struct Accumulator {
            var plays = 0
            var last = Date.distantPast
            var spellings: [String: (artist: String, track: String, plays: Int)] = [:]
        }
        var byKey: [String: Accumulator] = [:]
        for s in scrobbles where !s.trackName.isEmpty && !s.artistName.isEmpty {
            let matchKey = LibraryGapsEngine.key(artist: s.artistName, track: s.trackName)
            byKey[matchKey, default: Accumulator()].plays += 1
            if s.playedAt > byKey[matchKey]!.last { byKey[matchKey]!.last = s.playedAt }
            let spelling = "\(s.artistName)\u{0}\(s.trackName)"
            byKey[matchKey]!.spellings[spelling, default: (s.artistName, s.trackName, 0)].plays += 1
        }
        return byKey.map { key, acc in
            let best = acc.spellings.values.max { $0.plays < $1.plays }!
            return LibraryTrackUsage(matchKey: key, artist: best.artist, track: best.track, plays: acc.plays, lastPlayed: acc.last)
        }
    }

    /// The new state of every tracked track. `previousCheck` is the date of the last run — the moment a track that
    /// has just gone missing was last seen present.
    nonisolated static func check(
        usage: [LibraryTrackUsage], apple: AppleMusicSnapshot,
        existing: [String: LibraryPresenceRecord], previousCheck: Date?, now: Date, confirmed: Set<String> = []
    ) -> [LibraryPresenceRecord] {
        func key(_ t: AppleMusicSnapshot.Track) -> String { LibraryGapsEngine.key(artist: t.artist, track: t.name) }
        // A key is "no longer available" only if EVERY copy of it in the library is greyed out.
        var allUnavailable: [String: Bool] = [:]
        for t in apple.library {
            let k = key(t)
            let unavailable = t.cloudStatus == LibraryPresenceRecord.unavailableCloudStatus
            allUnavailable[k] = (allUnavailable[k] ?? true) && unavailable
        }
        let nearIndex = LovedStatusAuditEngine.NearIndex(apple.library.map { .init(artist: $0.artist, track: $0.name) })

        return usage.map { u in
            let old = existing[u.matchKey]
            var record = old ?? LibraryPresenceRecord(
                matchKey: u.matchKey, artist: u.artist, track: u.track, inLibrary: false, lastSeenAt: nil,
                firstCheckedAt: now, nearMatch: nil, cloudStatus: nil
            )
            if let unavailable = allUnavailable[u.matchKey] {
                record.inLibrary = true
                record.nearMatch = nil
                record.cloudStatus = unavailable ? LibraryPresenceRecord.unavailableCloudStatus : nil
            } else {
                if old?.inLibrary == true { record.lastSeenAt = previousCheck ?? old?.firstCheckedAt }
                record.inLibrary = false
                record.cloudStatus = nil
                // A track the user confirmed isn't the near match stays that way, so it doesn't go back to Uncertain.
                record.nearMatch = confirmed.contains(u.matchKey)
                    ? nil
                    : nearIndex.nearest(artist: u.artist, track: u.track).map { "“\($0.track)” by \($0.artist)" }
            }
            return record
        }
    }

    nonisolated static func changes(from new: [LibraryPresenceRecord], existing: [String: LibraryPresenceRecord]) -> [LibraryPresenceRecord] {
        new.filter { existing[$0.matchKey] != $0 }
    }

    /// Saved statuses for tracks that no longer have any scrobbles — the plays were removed or corrected on Last.fm
    /// (a different artist credit or title is a different track here), so the old status describes nothing the
    /// history still contains. A check removes them.
    nonisolated static func orphanKeys(existing: [String: LibraryPresenceRecord], usage: [LibraryTrackUsage]) -> [String] {
        let live = Set(usage.map(\.matchKey))
        return existing.keys.filter { !live.contains($0) }
    }
}

/// Reads and writes the persisted library status off the main actor.
@ModelActor
actor LibraryPresenceStore {
    func records() throws -> [String: LibraryPresenceRecord] {
        Dictionary(uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<LibraryPresenceEntry>()).map {
            ($0.matchKey, LibraryPresenceRecord(
                matchKey: $0.matchKey, artist: $0.artist, track: $0.track, inLibrary: $0.inLibrary, lastSeenAt: $0.lastSeenAt,
                firstCheckedAt: $0.firstCheckedAt, nearMatch: $0.nearMatch, cloudStatus: $0.cloudStatus
            ))
        })
    }

    func lastCheck() throws -> (checkedAt: Date, libraryTrackCount: Int, trackedCount: Int)? {
        try modelContext.fetch(FetchDescriptor<LibraryPresenceCheck>()).first.map { ($0.checkedAt, $0.libraryTrackCount, $0.trackedCount) }
    }

    func apply(
        changed: [LibraryPresenceRecord], removing: [String] = [], checkedAt: Date, libraryTrackCount: Int, trackedCount: Int
    ) throws {
        if !removing.isEmpty {
            let gone = Set(removing)
            for entry in try modelContext.fetch(FetchDescriptor<LibraryPresenceEntry>()) where gone.contains(entry.matchKey) {
                modelContext.delete(entry)
            }
        }
        if !changed.isEmpty {
            let wanted = Set(changed.map(\.matchKey))
            var entries: [String: LibraryPresenceEntry] = [:]
            for entry in try modelContext.fetch(FetchDescriptor<LibraryPresenceEntry>()) where wanted.contains(entry.matchKey) {
                entries[entry.matchKey] = entry
            }
            for record in changed {
                if let entry = entries[record.matchKey] {
                    entry.artist = record.artist
                    entry.track = record.track
                    entry.inLibrary = record.inLibrary
                    entry.lastSeenAt = record.lastSeenAt
                    entry.nearMatch = record.nearMatch
                    entry.cloudStatus = record.cloudStatus
                } else {
                    modelContext.insert(LibraryPresenceEntry(
                        matchKey: record.matchKey, artist: record.artist, track: record.track, inLibrary: record.inLibrary,
                        lastSeenAt: record.lastSeenAt, firstCheckedAt: record.firstCheckedAt, nearMatch: record.nearMatch,
                        cloudStatus: record.cloudStatus
                    ))
                }
            }
        }
        // A confirmation says "it isn't in my library, and that's fine": once the track is back it no longer applies,
        // so if it goes missing again it needs reviewing again.
        // The old "dismissals" (no stored near match) mean nothing any more and are removed here too.
        let returned = Set(changed.filter(\.inLibrary).map(\.matchKey))
        for item in try modelContext.fetch(FetchDescriptor<LibraryGapDismissal>()) where item.nearMatch == nil || returned.contains(item.matchKey) {
            modelContext.delete(item)
        }
        if let check = try modelContext.fetch(FetchDescriptor<LibraryPresenceCheck>()).first {
            check.checkedAt = checkedAt
            check.libraryTrackCount = libraryTrackCount
            check.trackedCount = trackedCount
        } else {
            modelContext.insert(LibraryPresenceCheck(checkedAt: checkedAt, libraryTrackCount: libraryTrackCount, trackedCount: trackedCount))
        }
        try modelContext.save()
    }

    /// `LibraryGapsEngine.key`s of the tracks the user has confirmed aren't in the library. Records with no stored near
    /// match are the retired "dismissals" and don't count.
    func confirmedKeys() throws -> Set<String> {
        Set(try modelContext.fetch(FetchDescriptor<LibraryGapDismissal>()).filter { $0.nearMatch != nil }.map(\.matchKey))
    }

    /// Confirms an Uncertain track isn't in the library (`true`) — its near match is cleared, so it shows as Never in
    /// library or Removed, and later checks keep it that way — or undoes that (`false`), restoring the near match.
    /// Returns false when there was nothing to do: not Uncertain, or no longer a saved row.
    @discardableResult
    func setConfirmed(_ confirmed: Bool, artist: String, track: String) throws -> Bool {
        let key = LibraryGapsEngine.key(artist: artist, track: track)
        var entryDescriptor = FetchDescriptor<LibraryPresenceEntry>(predicate: #Predicate { $0.matchKey == key })
        entryDescriptor.fetchLimit = 1
        guard let entry = try modelContext.fetch(entryDescriptor).first else { return false }
        var descriptor = FetchDescriptor<LibraryGapDismissal>(predicate: #Predicate { $0.matchKey == key })
        descriptor.fetchLimit = 1
        let existing = try modelContext.fetch(descriptor).first
        if confirmed {
            guard !entry.inLibrary, let near = entry.nearMatch else { return false }
            if let existing {
                existing.nearMatch = near
            } else {
                modelContext.insert(LibraryGapDismissal(matchKey: key, artist: artist, track: track, dismissedAt: .now, nearMatch: near))
            }
            entry.nearMatch = nil
        } else if let existing {
            if !entry.inLibrary, entry.nearMatch == nil { entry.nearMatch = existing.nearMatch }
            modelContext.delete(existing)
        }
        try modelContext.save()
        return true
    }
}

extension Notification.Name {
    /// The saved Library Gaps status or confirmations changed outside the tool itself (a backup restore).
    static let libraryGapsDidChange = Notification.Name("LibraryGapsDidChange")
}

@ModelActor
private actor LibraryGapBadgeReader {
    /// Keys of tracks to mark: not in the library (never there or removed) or greyed out in Music — not the
    /// uncertain ones, which are probably present under another name. A track the user has confirmed keeps its mark;
    /// confirming only stops Library Gaps asking about it.
    func gapKeys() throws -> Set<String> {
        var keys = Set<String>()
        for entry in try modelContext.fetch(FetchDescriptor<LibraryPresenceEntry>()) {
            let missing = !entry.inLibrary && entry.nearMatch == nil
            let unavailable = entry.inLibrary && entry.cloudStatus != nil
            if missing || unavailable { keys.insert(entry.matchKey) }
        }
        return keys
    }
}

/// Which tracks get the "not in your Apple Music library" badge next to their title — the same job
/// `LovedTracksStore` does for hearts. Loaded once at launch from the saved Library Gaps result (never touches
/// Music) and reloaded after a check or a backup restore.
@MainActor
@Observable
final class LibraryGapBadgeStore {
    private(set) var keys: Set<String> = []
    private(set) var hasLoaded = false

    func load(container: ModelContainer, force: Bool = false) async {
        guard force || !hasLoaded else { return }
        if let loaded = try? await offMain({ try await LibraryGapBadgeReader(modelContainer: container).gapKeys() }) {
            keys = loaded
            hasLoaded = true
        }
    }

    func isGap(artist: String, track: String) -> Bool {
        // Cheap exit for a library that has never been checked (or has no gaps) — the key below costs a regex.
        guard !keys.isEmpty else { return false }
        return keys.contains(LibraryGapsEngine.key(artist: artist, track: track))
    }
}

extension View {
    /// Provides the gap-badge store to everything below and keeps it current when the saved status changes outside
    /// the tool (a backup restore). One modifier, because `ContentView`'s modifier chain is already at the limit of
    /// what the compiler will type-check.
    func libraryGapBadges(_ store: LibraryGapBadgeStore, container: ModelContainer) -> some View {
        environment(store)
            .onReceive(NotificationCenter.default.publisher(for: .libraryGapsDidChange)) { _ in
                Task { await store.load(container: container, force: true) }
            }
    }
}

/// Reads Music, matches it against everything scrobbled, and records what changed.
enum LibraryGapsRunner {
    struct Summary: Sendable {
        let checkedAt: Date
        let trackedCount: Int
        let libraryTrackCount: Int
        let changedCount: Int
        let readSeconds: Double
        let totalSeconds: Double
        /// Where the time went, for the DEBUG dump.
        var phases = ""
    }

    /// Throws `AppleMusicFavoritesReader.ReadError.musicNotRunning` (without launching Music) or a Music
    /// automation error; the persisted state is untouched on any failure.
    static func run(container: ModelContainer) async throws -> Summary {
        let started = Date()
        let apple = try await AppleMusicFavoritesReader.read(includeCloudStatus: true)
        let t1 = Date()
        let usage = try await scrobbledUsage(container: container)
        let t2 = Date()
        let store = LibraryPresenceStore(modelContainer: container)
        let existing = try await store.records()
        let previous = try await store.lastCheck()?.checkedAt
        let confirmed = try await store.confirmedKeys()
        let t3 = Date()
        let now = Date()
        let (changed, tracked, orphans) = await Task.detached(priority: .userInitiated) {
            let all = LibraryGapsEngine.check(usage: usage, apple: apple, existing: existing, previousCheck: previous, now: now, confirmed: confirmed)
            return (LibraryGapsEngine.changes(from: all, existing: existing), all.count, LibraryGapsEngine.orphanKeys(existing: existing, usage: usage))
        }.value
        let t4 = Date()
        try await store.apply(changed: changed, removing: orphans, checkedAt: now, libraryTrackCount: apple.library.count, trackedCount: tracked)
        let t5 = Date()
        func f(_ a: Date, _ b: Date) -> String { String(format: "%.2f", b.timeIntervalSince(a)) }
        return Summary(
            checkedAt: now, trackedCount: tracked, libraryTrackCount: apple.library.count, changedCount: changed.count,
            readSeconds: apple.readSeconds, totalSeconds: Date().timeIntervalSince(started),
            phases: "scrobbles=\(f(t1, t2)) storeRead=\(f(t2, t3)) match=\(f(now, t4)) write=\(f(t4, t5))"
        )
    }

    /// Distinct scrobbled tracks with plays, artists canonicalized the way Query and the other tools see them.
    static func scrobbledUsage(container: ModelContainer) async throws -> [LibraryTrackUsage] {
        let snapshots = try await offMain {
            try await ScrobbleHistoryCache.shared.canonicalSnapshots(container: container)
        }
        return await Task.detached(priority: .userInitiated) { LibraryGapsEngine.usage(from: snapshots) }.value
    }
}

#if DEBUG
/// Verification hook: `SCROBLYTICS_LIBGAPS_DUMP=/path/out.txt` (with SCROBLYTICS_STORE_PATH on a COPY of the store)
/// runs the check three times against live Music — plain; after pretending the top never-seen track used to be in
/// the library; after confirming an Uncertain one — and writes counts, timings and the gap rows.
enum LibraryGapsDebugEval {
    @MainActor
    static func runHeadlessIfRequested(container: ModelContainer) {
        guard let path = ProcessInfo.processInfo.environment["SCROBLYTICS_LIBGAPS_DUMP"] else { return }
        Task { @MainActor in
            var out: [String] = []
            defer { try? out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8); exit(0) }
            do {
                let store = LibraryPresenceStore(modelContainer: container)
                let usage = try await LibraryGapsRunner.scrobbledUsage(container: container)
                let plays = Dictionary(uniqueKeysWithValues: usage.map { ($0.matchKey, $0.plays) })
                func summarize(_ label: String, _ s: LibraryGapsRunner.Summary) {
                    out.append("\(label): tracked=\(s.trackedCount) library=\(s.libraryTrackCount) changedRows=\(s.changedCount) read=\(String(format: "%.2f", s.readSeconds))s total=\(String(format: "%.2f", s.totalSeconds))s [\(s.phases)]")
                }
                summarize("RUN1", try await LibraryGapsRunner.run(container: container))
                var records = try await store.records()
                func counts() -> String {
                    Dictionary(grouping: records.values, by: \.status).map { "\($0.key.rawValue)=\($0.value.count)" }.sorted().joined(separator: " ")
                }
                out.append("COUNTS1 \(counts())")

                // Pretend the most-played never-seen track used to be in the library.
                let top = records.values.filter { $0.status == .neverInLibrary }.max { plays[$0.matchKey, default: 0] < plays[$1.matchKey, default: 0] }
                if var top {
                    top.inLibrary = true
                    try await store.apply(changed: [top], checkedAt: (try await store.lastCheck())!.checkedAt, libraryTrackCount: 0, trackedCount: 0)
                    out.append("SEEDED present: \(top.artist) — \(top.track)")
                }
                let check1 = try await store.lastCheck()!.checkedAt
                summarize("RUN2", try await LibraryGapsRunner.run(container: container))
                records = try await store.records()
                out.append("COUNTS2 \(counts())")
                if let top, let after = records[top.matchKey] {
                    out.append("SEEDED now status=\(after.status.rawValue) lastSeenAt=\(String(describing: after.lastSeenAt)) equalsRun1Check=\(after.lastSeenAt == check1)")
                }

                // The greyed-out ("no longer available") path, synthetic: none of the two such tracks in this
                // library has been scrobbled, so real data can't exercise it.
                do {
                    let probe = LibraryTrackUsage(matchKey: LibraryGapsEngine.key(artist: "A", track: "T"), artist: "A", track: "T", plays: 1, lastPlayed: .now)
                    let both = LibraryTrackUsage(matchKey: LibraryGapsEngine.key(artist: "B", track: "U"), artist: "B", track: "U", plays: 1, lastPlayed: .now)
                    let library = [
                        AppleMusicSnapshot.Track(name: "T", artist: "A", album: "", cloudStatus: "no longer available"),
                        AppleMusicSnapshot.Track(name: "U", artist: "B", album: "", cloudStatus: "no longer available"),
                        AppleMusicSnapshot.Track(name: "U", artist: "B", album: "x", cloudStatus: "subscription"),
                    ]
                    let apple = AppleMusicSnapshot(favorites: [], library: library, source: .favoritesPlaylist, readSeconds: 0)
                    let result = LibraryGapsEngine.check(usage: [probe, both], apple: apple, existing: [:], previousCheck: nil, now: .now)
                    out.append("SYNTHETIC all copies greyed -> \(result[0].status.rawValue); one greyed + one playable -> \(result[1].status.rawValue)")
                }

                // Query fields, checked against the saved table through the real engine.
                do {
                    let canon = try await offMain {
                        try await ScrobbleHistoryCache.shared.canonicalSnapshots(container: container)
                    }
                    let loaded = await QuerySnapshotReader(modelContainer: container).loadAll()
                    let snapshots = QuerySnapshots(libraryPresence: loaded.libraryPresence)
                    func evaluate(_ conditions: [QueryCondition]) throws -> Set<String> {
                        var spec = QuerySpec(target: .track)
                        if !conditions.isEmpty { spec.groups = [conditions] }
                        spec.columns = [QueryFieldRef("plays")]
                        let validated = try spec.validate(against: .standard)
                        let run = QueryRun(target: .track, asOf: Date(), scrobbles: canon, allTimeScrobbles: canon, snapshots: snapshots)
                        return Set(QueryEngine.evaluate(validated, run: run).rows.map { LibraryGapsEngine.key(artist: $0.entity.artist, track: $0.entity.name) })
                    }
                    let all = try evaluate([])
                    let notIn = try evaluate([QueryCondition("inAppleLibrary", .isFalse)])
                    let inLib = try evaluate([QueryCondition("inAppleLibrary", .isTrue)])
                    let unknown = try evaluate([QueryCondition("inAppleLibrary", .isMissing)])
                    let removed = try evaluate([QueryCondition("removedFromAppleLibrary", .hasValue)])
                    let expectedNotIn = Set(records.values.filter { !$0.inLibrary && $0.nearMatch == nil }.map(\.matchKey))
                    let expectedRemoved = Set(records.values.filter { $0.status == .removed }.map(\.matchKey))
                    out.append("QUERY universe(keys)=\(all.count) notInLibrary=\(notIn.count) inLibrary=\(inLib.count) unknown=\(unknown.count) removed=\(removed.count)")
                    out.append("QUERY notInLibrary == table(!inLibrary && no near match): \(notIn == expectedNotIn.intersection(all)) (table \(expectedNotIn.count))")
                    out.append("QUERY removed == table(status removed): \(removed == expectedRemoved.intersection(all)) (table \(expectedRemoved.count))")
                    out.append("QUERY inLibrary(incl. near)+notInLibrary partition the universe: \(inLib.isDisjoint(with: notIn) && inLib.union(notIn) == all && unknown.isEmpty); inLibrary == present+unavailable+uncertain rows: \(inLib == Set(records.values.filter { $0.inLibrary || $0.nearMatch != nil }.map(\.matchKey)).intersection(all))")
                    let emptyRun = QuerySnapshots()
                    var spec = QuerySpec(target: .track)
                    spec.groups = [[QueryCondition("inAppleLibrary", .isMissing)]]
                    spec.columns = [QueryFieldRef("plays")]
                    let validated = try spec.validate(against: .standard)
                    let neverChecked = QueryEngine.evaluate(validated, run: QueryRun(target: .track, asOf: Date(), scrobbles: canon, allTimeScrobbles: canon, snapshots: emptyRun)).rows.count
                    out.append("QUERY with no saved check: unknown=\(neverChecked) of \(all.count) keys' entities")
                } catch {
                    out.append("QUERY ERROR: \(error)")
                }

                // Confirm: an Uncertain track is confirmed as not in the library. The saved table may also hold the old
                // "dismissals" (no stored near match), which must mean nothing.
                let context = container.mainContext
                func tableCount() throws -> Int { try context.fetch(FetchDescriptor<LibraryGapDismissal>()).count }
                func queryNotInLibrary() async throws -> Set<String> {
                    let canon = try await offMain {
                        try await ScrobbleHistoryCache.shared.canonicalSnapshots(container: container)
                    }
                    let loaded = await QuerySnapshotReader(modelContainer: container).loadAll()
                    var spec = QuerySpec(target: .track)
                    spec.groups = [[QueryCondition("inAppleLibrary", .isFalse)]]
                    spec.columns = [QueryFieldRef("plays")]
                    let validated = try spec.validate(against: .standard)
                    let run = QueryRun(target: .track, asOf: Date(), scrobbles: canon, allTimeScrobbles: canon, snapshots: QuerySnapshots(libraryPresence: loaded.libraryPresence))
                    return Set(QueryEngine.evaluate(validated, run: run).rows.map { LibraryGapsEngine.key(artist: $0.entity.artist, track: $0.entity.name) })
                }
                func statusCounts() async throws -> [LibraryGapStatus: Int] {
                    Dictionary(grouping: try await store.records().values.filter { $0.status.isGap }, by: \.status).mapValues(\.count)
                }
                @MainActor func badgeKeys() async -> Set<String> {
                    let badge = LibraryGapBadgeStore()
                    await badge.load(container: container, force: true)
                    return badge.keys
                }
                out.append("OLD dismissals in the table: \(try tableCount()); counted as confirmed: \(try await store.confirmedKeys().count) (expected 0)")
                if let victim = records.values.first(where: { $0.status == .uncertain }) {
                    let originalNear = victim.nearMatch
                    let expectedAfter: LibraryGapStatus = victim.lastSeenAt != nil ? .removed : .neverInLibrary
                    let before = try await statusCounts()
                    let beforeBadge = await badgeKeys()
                    let beforeQuery = try await queryNotInLibrary()
                    out.append("UNCERTAIN victim: \(victim.artist) — \(victim.track) near=\(originalNear ?? "nil") | in badge=\(beforeBadge.contains(victim.matchKey)) in Query notInLibrary=\(beforeQuery.contains(victim.matchKey)) (expected false false)")

                    let accepted = try await store.setConfirmed(true, artist: victim.artist, track: victim.track)
                    var now = try await store.records()[victim.matchKey]!
                    let after = try await statusCounts()
                    let afterBadge = await badgeKeys()
                    let afterQuery = try await queryNotInLibrary()
                    out.append("CONFIRM accepted=\(accepted) status=\(now.status.rawValue) (expected \(expectedAfter.rawValue)) nearMatch=\(now.nearMatch ?? "nil") | in badge=\(afterBadge.contains(victim.matchKey)) in Query notInLibrary=\(afterQuery.contains(victim.matchKey)) (expected true true)")
                    out.append("COUNTS shift: uncertain \(before[.uncertain] ?? 0)->\(after[.uncertain] ?? 0), \(expectedAfter.rawValue) \(before[expectedAfter] ?? 0)->\(after[expectedAfter] ?? 0), total gaps \(before.values.reduce(0, +))->\(after.values.reduce(0, +)); badge keys +\(afterBadge.count - beforeBadge.count) (expected -1, +1, same total, +1)")
                    out.append("LIST under All: \(LibraryGapsView.Filter.all.matches(now.status)) under its own filter: \(LibraryGapsView.Filter.allCases.filter { $0 != .all && $0.matches(now.status) }.map(\.label))")
                    let unknownKeyAccepted = try await store.setConfirmed(true, artist: "no such artist", track: "no such track")
                    var settledAccepted: Bool?
                    if let settled = try await store.records().values.first(where: { $0.status == .neverInLibrary }) {
                        settledAccepted = try await store.setConfirmed(true, artist: settled.artist, track: settled.track)
                    }
                    out.append("CONFIRM refused: unknown track=\(unknownKeyAccepted) never-in-library track=\(String(describing: settledAccepted)) (expected false, Optional(false))")

                    summarize("RUN3", try await LibraryGapsRunner.run(container: container))
                    now = try await store.records()[victim.matchKey]!
                    out.append("SURVIVES a re-check: status=\(now.status.rawValue) confirmed=\(try await store.confirmedKeys() == [victim.matchKey]) (expected \(expectedAfter.rawValue), true)")

                    // Native backup round trip.
                    let document = try NativeBackupEngine.makeDocument(context: context)
                    let (archive, summary) = try NativeBackupEngine.inspect(document: document)
                    let archived = archive.dismissedLibraryGaps ?? []
                    out.append("BACKUP archive holds \(archived.count) record(s), victim near match kept=\(archived.first { LibraryGapsEngine.key(artist: $0.artist, track: $0.track) == victim.matchKey }?.nearMatch == originalNear) summary=\(summary.description)")
                    try await store.setConfirmed(false, artist: victim.artist, track: victim.track)
                    now = try await store.records()[victim.matchKey]!
                    out.append("UNDO: status=\(now.status.rawValue) near match restored=\(now.nearMatch == originalNear) in badge=\(await badgeKeys().contains(victim.matchKey)) confirmed=\(try await store.confirmedKeys().isEmpty) (expected uncertain, true, false, true)")
                    try NativeBackupEngine.restoreDismissedLibraryGaps(archive.dismissedLibraryGaps, context: context)
                    out.append("BACKUP restored: confirmed=\(try await store.confirmedKeys() == [victim.matchKey])")
                    summarize("RUN3b", try await LibraryGapsRunner.run(container: container))
                    now = try await store.records()[victim.matchKey]!
                    out.append("BACKUP restore then a check -> status=\(now.status.rawValue) (expected \(expectedAfter.rawValue))")
                    try NativeBackupEngine.restoreDismissedLibraryGaps(nil, context: context)
                    out.append("BACKUP old archive (nil) keeps confirmations: \(try await store.confirmedKeys() == [victim.matchKey])")
                    if var json = try JSONSerialization.jsonObject(with: document.data) as? [String: Any] {
                        json.removeValue(forKey: "dismissedLibraryGaps")
                        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                        let old = try decoder.decode(NativeBackupFormat.Archive.self, from: try JSONSerialization.data(withJSONObject: json))
                        out.append("BACKUP archive without the field decodes: \(String(describing: old.dismissedLibraryGaps))")
                    }
                    try NativeBackupEngine.restoreDismissedLibraryGaps([], context: context)
                    out.append("BACKUP archive with none clears: \(try await store.confirmedKeys().isEmpty)")

                    // Retired dismissals (no near match) mean nothing, and a check removes them.
                    context.insert(LibraryGapDismissal(matchKey: "old-1", artist: "x", track: "y", dismissedAt: .now))
                    context.insert(LibraryGapDismissal(matchKey: "old-2", artist: "x", track: "z", dismissedAt: .now))
                    try context.save()
                    out.append("RETIRED dismissals ignored: confirmed=\(try await store.confirmedKeys().count) table=\(try tableCount()) (expected 0, 2)")
                    summarize("RUN3c", try await LibraryGapsRunner.run(container: container))
                    out.append("RETIRED dismissals purged by a check: table=\(try tableCount()) (expected 0)")

                    // A confirmation ends when the track turns up in the library.
                    try await store.setConfirmed(true, artist: victim.artist, track: victim.track)
                    var back = try await store.records()[victim.matchKey]!
                    back.inLibrary = true
                    try await store.apply(changed: [back], checkedAt: (try await store.lastCheck())!.checkedAt, libraryTrackCount: 0, trackedCount: 0)
                    out.append("TRACK back in the library: confirmation cleared=\(try await store.confirmedKeys().isEmpty) table=\(try tableCount())")
                    summarize("RUN3d (missing again)", try await LibraryGapsRunner.run(container: container))
                    now = try await store.records()[victim.matchKey]!
                    out.append("MISSING again -> status=\(now.status.rawValue) (expected uncertain: it needs reviewing again)")
                    try await store.setConfirmed(true, artist: victim.artist, track: victim.track)
                }
                do {
                    let badge = LibraryGapBadgeStore()
                    await badge.load(container: container, force: true)
                    records = try await store.records()
                    let expected = Set(records.values.filter { $0.status == .removed || $0.status == .neverInLibrary || $0.status == .unavailable }.map(\.matchKey))
                    out.append("BADGE keys=\(badge.keys.count) expected=\(expected.count) equal=\(badge.keys == expected) (uncertain excluded=\(records.values.filter { $0.status == .uncertain }.allSatisfy { !badge.keys.contains($0.matchKey) }))")
                    if let sample = records.values.first(where: { badge.keys.contains($0.matchKey) }), let present = records.values.first(where: { $0.status == .present }) {
                        out.append("BADGE gap track -> \(badge.isGap(artist: sample.artist, track: sample.track)); present track -> \(badge.isGap(artist: present.artist, track: present.track))")
                    }
                }
                summarize("RUN4 (no change expected)", try await LibraryGapsRunner.run(container: container))

                for r in records.values.filter({ $0.status.isGap }).sorted(by: { plays[$0.matchKey, default: 0] > plays[$1.matchKey, default: 0] }) {
                    out.append("GAP\t\(r.status.rawValue)\t\(plays[r.matchKey, default: 0])\t\(r.artist)\t\(r.track)\t\(r.nearMatch ?? "")\t\(r.cloudStatus ?? "")")
                }
            } catch {
                out.append("ERROR: \(error)")
            }
        }
    }
}
#endif
