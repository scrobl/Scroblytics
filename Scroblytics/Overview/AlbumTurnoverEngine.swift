import Foundation
import SwiftData

struct AlbumGroup: Sendable {
    var artist: String
    let displayName: String
    let normalizedName: String
    let variants: [String]
    /// Ascending by playedAt.
    let scrobbles: [ScrobbleSnapshot]
}

enum MatchConfidence: Sendable {
    case confident
    case ambiguous
}

enum AlbumMatchBasis: Sendable {
    case canonical
    case observed
}

/// A user's saved
/// "Fix album match…" decision for one album group. `nil` means no
/// resolution has ever been recorded for it (the auto-classify path).
enum StoredAlbumResolution: Sendable {
    case canonical(canonicalArtist: String, canonicalAlbum: String)
    case observed
    case manual(tracks: [String])
}

/// Where an album's Last.fm match stands — the same states the album page badges ("Uncertain match",
/// "No match found") plus the ones that need no attention. Derived from `matchResult` and the saved
/// resolution, never re-decided.
enum AlbumMatchStatus: String, CaseIterable, Sendable {
    case autoMatched = "Auto-matched"
    case confirmed = "Confirmed by you"
    case usingPlayedTracks = "Using played tracks"
    case uncertain = "Uncertain match"
    case noMatch = "No match found"
    /// You confirmed a Last.fm album, but its tracklist can't be found any more.
    case tracklistUnavailable = "Confirmed, tracklist unavailable"

    /// The states that are still waiting for a human decision.
    var needsReview: Bool { self == .uncertain || self == .noMatch }

    nonisolated static func classify(_ match: AlbumTurnoverMatchResult, resolution: StoredAlbumResolution?) -> AlbumMatchStatus {
        switch resolution {
        case .manual?: return .confirmed
        case .observed?: return .usingPlayedTracks
        case .canonical?: return match.basis == .canonical ? .confirmed : .tracklistUnavailable
        case nil:
            if match.ambiguous { return .uncertain }
            if match.basis == .canonical { return .autoMatched }
            return .noMatch
        }
    }
}

struct AlbumTurnoverMatchResult: Sendable {
    let basis: AlbumMatchBasis
    /// True when a canonical tracklist was found but classified ambiguous.
    let ambiguous: Bool
    /// True when Last.fm genuinely has no matching album AND there was no
    /// (or a non-canonical) resolution — on a lookup miss.
    let noCanonicalMatch: Bool
    /// Last.fm's own artist/album for the tracklist actually used, when one
    /// was found — kept because it's useful for debugging/validation.
    let canonicalArtist: String?
    let canonicalAlbum: String?
    let canonicalTrackCount: Int?
    let observedDistinct: Int
    let coverage: Double?
    /// The tracklist used as the turnover denominator — the canonical
    /// tracklist when `basis == .canonical`, else the user's own distinct
    /// observed titles. Feeds `trackCount`/`applicable` and (later) cycle
    /// computation.
    let denominatorTitles: [String]
    let trackCount: Int
    /// True one-track singles aren't a full-album listening pattern.
    let applicable: Bool
    let resolved: Bool
}

/// The Album Turnover matching/classification pipeline
/// (`buildAlbumGroups`, `resolveAlbumTurnover`'s
/// automatic-match branch) — deliberately built and validated BEFORE being
/// treated as correct, per the user's explicit instruction, by testing
/// against every real stored album-match resolution in a synced library
/// (see the one-off validation hook run for this).
@MainActor
enum AlbumTurnoverEngine {
    /// True one-track singles aren't a full-album listening pattern.
    /// Confirmed against the live source: MIN_TURNOVER_TRACKS = 2, NOT 4 as
    /// the export-backup-restore PRD's prose describes — real source wins.
    nonisolated static let minTurnoverTracks = 2

    /// Consolidates one artist's scrobbled album-name variants into groups,
    /// merging close matches (edition/token/edit similarity) via
    /// `albumNamesSimilar`. `scrobbles` MUST be pre-sorted ascending by
    /// playedAt — both for `group.scrobbles` ordering and because the greedy
    /// clustering below is order-sensitive (first-encountered normalized
    /// variant becomes each cluster's seed), mirroring JS Map/Set's
    /// insertion-order iteration, which Swift's Dictionary/Set do NOT
    /// provide — hence the explicit "Ordered" bookkeeping throughout.
    /// `nonisolated` (unlike the rest of this `@MainActor` enum) — pure
    /// computation over Sendable data, deliberately callable from a
    /// background task. The per-artist pairwise fuzzy-matching pass below is
    /// genuinely expensive across a whole library (was the actual cause of a
    /// multi-second UI freeze, confirmed directly), so `fetchRankings`/
    /// `fetchAllCompletions` run it off the main actor.
    nonisolated static func buildAlbumGroups(from scrobbles: [ScrobbleSnapshot]) -> [AlbumGroup] {
        var byNorm: [String: [ScrobbleSnapshot]] = [:]
        var normKeysOrdered: [String] = []
        for s in scrobbles {
            guard !s.albumName.isEmpty else { continue }
            let norm = TextNormalization.normalizeAlbumName(s.albumName)
            guard !norm.isEmpty else { continue }
            if byNorm[norm] == nil { normKeysOrdered.append(norm) }
            byNorm[norm, default: []].append(s)
        }

        var clusterOf: [String: String] = [:]
        var seedsOrdered: [String] = []
        for key in normKeysOrdered {
            var matchedSeed: String?
            for existingSeed in seedsOrdered {
                if TextNormalization.albumNamesSimilar(key, existingSeed) {
                    matchedSeed = existingSeed
                    break
                }
            }
            let finalSeed = matchedSeed ?? key
            clusterOf[key] = finalSeed
            if matchedSeed == nil { seedsOrdered.append(finalSeed) }
        }

        var clusters: [String: [ScrobbleSnapshot]] = [:]
        for norm in normKeysOrdered {
            clusters[clusterOf[norm]!, default: []].append(contentsOf: byNorm[norm]!)
        }

        var groups: [AlbumGroup] = []
        for seed in seedsOrdered {
            let groupScrobbles = clusters[seed]!
            var variantCounts: [String: Int] = [:]
            var variantsOrdered: [String] = []
            for s in groupScrobbles {
                if variantCounts[s.albumName] == nil { variantsOrdered.append(s.albumName) }
                variantCounts[s.albumName, default: 0] += 1
            }
            // Display name = most-played original variant.
            let displayName = variantsOrdered.sorted { a, b in
                let ca = variantCounts[a]!, cb = variantCounts[b]!
                return ca != cb ? ca > cb : a < b
            }.first!
            groups.append(AlbumGroup(
                artist: groupScrobbles[0].artistName,
                displayName: displayName,
                normalizedName: seed,
                variants: variantsOrdered,
                scrobbles: groupScrobbles.sorted { $0.playedAt < $1.playedAt }
            ))
        }
        return groups
    }

    /// Finds the group an album name belongs to (by normalized match against its variants).
    nonisolated static func findAlbumGroup(_ groups: [AlbumGroup], album: String) -> AlbumGroup? {
        let norm = TextNormalization.normalizeAlbumName(album)
        return groups.first { g in
            g.normalizedName == norm || g.variants.contains { TextNormalization.normalizeAlbumName($0) == norm }
        }
    }

    nonisolated static func distinctObserved(_ group: AlbumGroup) -> (titles: [String], count: Int) {
        var seen = Set<String>()
        var titles: [String] = []
        for s in group.scrobbles {
            let n = TextNormalization.normalizeTrackTitle(s.trackName)
            if !n.isEmpty, !seen.contains(n) {
                seen.insert(n)
                titles.append(s.trackName)
            }
        }
        return (titles, seen.count)
    }

    /// Fraction of the canonical tracklist the user has scrobbled at least once (ever).
    nonisolated static func coverageOf(scrobbleTitles: [String], canonicalTitles: [String]) -> Double {
        let canon = Set(canonicalTitles.map(TextNormalization.normalizeTrackTitle).filter { !$0.isEmpty })
        guard !canon.isEmpty else { return 0 }
        var heard = Set<String>()
        for t in scrobbleTitles {
            let n = TextNormalization.normalizeTrackTitle(t)
            if canon.contains(n) { heard.insert(n) }
        }
        return Double(heard.count) / Double(canon.count)
    }

    nonisolated static func classifyConfidence(canonicalCount: Int, observedDistinct: Int, coverage: Double) -> MatchConfidence {
        if canonicalCount == 0 || observedDistinct == 0 { return .ambiguous }
        if canonicalCount > observedDistinct * 2 { return .ambiguous } // canonical much longer
        if Double(canonicalCount) < Double(observedDistinct) * 0.7 { return .ambiguous } // canonical much shorter
        if coverage < 0.6 { return .ambiguous }
        return .confident
    }

    /// Automatic (no user resolution) classification for one album group —
    /// a thin convenience wrapper over `resolveTurnover` with `resolution: nil`.
    static func resolveAutomatic(context: ModelContext, group: AlbumGroup, client: LastfmAPIClient) async throws -> AlbumTurnoverMatchResult {
        try await resolveTurnover(context: context, group: group, resolution: nil, client: client)
    }

    /// Bridges the persisted "Fix album match…" decision (`Album.matchResolutionMode`
    /// + `canonicalArtist`/`canonicalAlbum`/`manualTracklist`) into the
    /// `StoredAlbumResolution` `resolveTurnover` consumes. Looks the `Album` row up
    /// by the same `identityKey` every other resolver in this codebase uses
    /// (`TextNormalization.albumIdentityKey`), so it finds exactly the row the Fix UI
    /// (or a backup restore) wrote to. Returns `nil` when no `Album` row exists yet,
    /// or one exists but has never been resolved — both mean "take the auto-classify
    /// path", same as before this bridge existed.
    static func storedResolution(context: ModelContext, group: AlbumGroup) -> StoredAlbumResolution? {
        let keys = resolutionKeys(for: group)
        let descriptor = FetchDescriptor<Album>(predicate: #Predicate { keys.contains($0.identityKey) })
        let albums = (try? context.fetch(descriptor)) ?? []
        // The display name's own decision wins; otherwise the first name variant that has one.
        for key in keys {
            if let album = albums.first(where: { $0.identityKey == key }), let resolution = resolution(from: album) { return resolution }
        }
        return nil
    }

    /// Every `Album.identityKey` a group's saved "Fix album match…" decision may live under, in
    /// precedence order: its display name, then each raw name variant. A group merges editions of
    /// one album ("Starship Casual '23/'24/'25/'26"), and which variant is the display name can
    /// change with the scrobbles the group was built from — so a decision saved under any variant
    /// still applies to the whole group.
    nonisolated static func resolutionKeys(for group: AlbumGroup) -> [String] {
        var seen = Set<String>()
        return ([group.displayName] + group.variants)
            .map { TextNormalization.albumIdentityKey(artist: group.artist, album: $0) }
            .filter { seen.insert($0).inserted }
    }

    /// The `Album` row → `StoredAlbumResolution` bridge, shared by the per-group lookup above
    /// and the query framework's bulk snapshot.
    nonisolated static func resolution(from album: Album) -> StoredAlbumResolution? {
        guard let mode = album.matchResolutionMode else { return nil }
        switch mode {
        case .canonical:
            guard let canonicalArtist = album.canonicalArtist, let canonicalAlbum = album.canonicalAlbum else { return nil }
            return .canonical(canonicalArtist: canonicalArtist, canonicalAlbum: canonicalAlbum)
        case .observed:
            return .observed
        case .manual:
            guard let tracks = album.manualTracklist, !tracks.isEmpty else { return nil }
            return .manual(tracks: tracks)
        }
    }

    /// `"<queried artist><separator><queried album>"`, trimmed + lowercased —
    /// using the same fix as `TextNormalization.albumIdentityKey`: a literal NUL byte
    /// as the separator gets silently truncated when persisted to the
    /// underlying SQLite column, which collapses every album by the same
    /// artist onto ONE cache row keyed by the truncated artist-only string —
    /// confirmed directly via a hex dump of a real cache row (`hex(cacheKey)`
    /// decoded to just the artist name, no album portion at all) after a "Fix
    /// album match…" save on one album silently returned a DIFFERENT
    /// album's cached tracklist by the same artist. Deliberately NOT the same key as
    /// `groupKey`: this caches the exact string pair sent to `album.getInfo`,
    /// and an auto-guessed query vs. a user's stored canonical resolution can
    /// each produce a different query for the same physical release.
    private nonisolated static let tracklistKeySeparator = "\u{241F}" // ␟ SYMBOL FOR UNIT SEPARATOR — same fix as albumIdentityKey
    nonisolated static func tracklistCacheKey(artist: String, album: String) -> String {
        "\(artist.trimmingCharacters(in: .whitespaces).lowercased())\(tracklistKeySeparator)\(album.trimmingCharacters(in: .whitespaces).lowercased())"
    }

    /// Cache-aware canonical-tracklist fetch. A transient fetch failure (network/rate-limit/
    /// server — surfaces here as a thrown error, per `LastfmAPIClient`'s
    /// existing transient-vs-genuine-miss split) is NEVER persisted: no row
    /// is written, so the next lookup retries instead of freezing a blip as
    /// a permanent "no catalog match." Only a genuine `.found` or `.noMatch`
    /// is cached, and cached indefinitely — tracklists don't change (explicit
    /// PRD requirement, not an optional optimization). A 120ms politeness
    /// delay follows every live fetch attempt regardless of outcome — never on a cache hit,
    /// since no network call was made.
    static func getCachedTracklist(
        context: ModelContext, client: LastfmAPIClient, artist: String, album: String
    ) async throws -> AlbumTracklistResult {
        let key = tracklistCacheKey(artist: artist, album: album)
        var descriptor = FetchDescriptor<AlbumTracklistCacheEntry>(predicate: #Predicate { $0.cacheKey == key })
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            return result(from: existing)
        }

        do {
            let fetched = try await client.fetchAlbumTracklist(artist: artist, album: album)
            switch fetched {
            case .found(let tracklist):
                context.insert(AlbumTracklistCacheEntry(
                    cacheKey: key, canonicalArtist: tracklist.artist, canonicalAlbum: tracklist.album,
                    tracks: tracklist.tracks, cachedAt: Date()
                ))
            case .noMatch:
                context.insert(AlbumTracklistCacheEntry(
                    cacheKey: key, canonicalArtist: nil, canonicalAlbum: nil, tracks: nil, cachedAt: Date()
                ))
            }
            try context.save()
            try? await Task.sleep(nanoseconds: 120_000_000)
            return fetched
        } catch {
            try? await Task.sleep(nanoseconds: 120_000_000)
            throw error
        }
    }

    /// A cache row → the lookup result it stands for (`nil` fields = a cached genuine miss).
    nonisolated static func result(from entry: AlbumTracklistCacheEntry) -> AlbumTracklistResult {
        if let tracks = entry.tracks, let canonicalArtist = entry.canonicalArtist, let canonicalAlbum = entry.canonicalAlbum {
            return .found(AlbumTracklist(album: canonicalAlbum, artist: canonicalArtist, tracks: tracks))
        }
        return .noMatch
    }

    /// The matching/classification branch of `resolveAlbumTurnover` — the piece that decides `basis`,
    /// `ambiguous`, and `noCanonicalMatch` from a group and its (possibly
    /// absent) saved resolution. The cycle-completion math
    /// (`computeCycles`/`rateDays`/`inProgress`) is separate.
    ///
    /// Branching:
    /// - `resolution == .observed` -> basis stays `.observed`, no lookup.
    /// - `resolution == .manual(tracks)` -> basis is `.canonical` with the
    ///   captured tracklist as denominator directly — no catalog lookup;
    ///   a manually-captured tracklist IS the canonical one.
    /// - `resolution == .canonical` or `nil` -> query Last.fm (using the
    ///   resolution's own canonical artist/album when present, else the
    ///   group's own artist + edition-stripped display name) and:
    ///   - no tracklist found: `noCanonicalMatch` is true ONLY when there
    ///     was no canonical resolution to begin with (a resolved album's
    ///     canonical name failing to re-resolve is a lookup miss, not a
    ///     "never had a match" case) — falls back to `.observed`.
    ///   - tracklist found + a canonical resolution: basis is
    ///     UNCONDITIONALLY `.canonical` — the confidence classifier is
    ///     bypassed entirely once a human has confirmed the match.
    ///   - tracklist found + no resolution: run `classifyConfidence`;
    ///     confident -> `.canonical`, else `.ambiguous`/`.observed`.
    /// The catalog lookup a resolution needs, if any: `.observed` and `.manual` resolutions
    /// never look anything up; a `.canonical` one looks up its own canonical name; no
    /// resolution looks up the group's own artist + edition-stripped display name.
    struct TracklistRequest: Sendable {
        let artist: String
        let album: String
        /// True when a human already confirmed the match (`.canonical` resolution).
        let isCanonicalResolution: Bool
    }

    nonisolated static func tracklistRequest(group: AlbumGroup, resolution: StoredAlbumResolution?) -> TracklistRequest? {
        switch resolution {
        case .observed?, .manual?:
            return nil
        case .canonical(let cArtist, let cAlbum)?:
            return TracklistRequest(artist: cArtist, album: cAlbum, isCanonicalResolution: true)
        case nil:
            return TracklistRequest(artist: group.artist, album: TextNormalization.stripEditionSuffix(group.displayName), isCanonicalResolution: false)
        }
    }

    static func resolveTurnover(
        context: ModelContext, group: AlbumGroup, resolution: StoredAlbumResolution?, client: LastfmAPIClient
    ) async throws -> AlbumTurnoverMatchResult {
        var lookup: AlbumTracklistResult?
        if let request = tracklistRequest(group: group, resolution: resolution) {
            lookup = try await getCachedTracklist(context: context, client: client, artist: request.artist, album: request.album)
        }
        return matchResult(group: group, resolution: resolution, lookup: lookup)
    }

    /// The matching/classification decision itself, given the catalog lookup (if the
    /// resolution needed one). Pure — `resolveTurnover` fetches, the query framework reads a
    /// cached snapshot, and both come through here.
    nonisolated static func matchResult(
        group: AlbumGroup, resolution: StoredAlbumResolution?, lookup: AlbumTracklistResult?
    ) -> AlbumTurnoverMatchResult {
        let observed = distinctObserved(group)
        var basis: AlbumMatchBasis = .observed
        var ambiguous = false
        var noCanonicalMatch = false
        var denominatorTitles = observed.titles
        var canonicalArtist: String?
        var canonicalAlbum: String?
        var canonicalTrackCount: Int?
        var coverage: Double?

        if case .observed = resolution {
            basis = .observed
        } else if case .manual(let tracks) = resolution {
            basis = .canonical
            denominatorTitles = tracks
        } else if let request = tracklistRequest(group: group, resolution: resolution), let lookup {
            let isCanonicalResolution = request.isCanonicalResolution
            switch lookup {
            case .noMatch:
                noCanonicalMatch = !isCanonicalResolution
                basis = .observed
            case .found(let tracklist):
                let canonNorm = Set(tracklist.tracks.map(TextNormalization.normalizeTrackTitle).filter { !$0.isEmpty })
                let cov = coverageOf(scrobbleTitles: group.scrobbles.map(\.trackName), canonicalTitles: tracklist.tracks)
                coverage = cov
                canonicalTrackCount = canonNorm.count
                if isCanonicalResolution {
                    basis = .canonical
                    denominatorTitles = tracklist.tracks
                    canonicalArtist = tracklist.artist
                    canonicalAlbum = tracklist.album
                } else {
                    let confidence = classifyConfidence(canonicalCount: canonNorm.count, observedDistinct: observed.count, coverage: cov)
                    if confidence == .confident {
                        basis = .canonical
                        denominatorTitles = tracklist.tracks
                        canonicalArtist = tracklist.artist
                        canonicalAlbum = tracklist.album
                    } else {
                        ambiguous = true
                        basis = .observed
                    }
                }
            }
        } else {
            // A lookup-needing resolution was given no lookup result: a programming error, not data.
            preconditionFailure("matchResult needs the tracklist lookup for this resolution")
        }

        let trackCount = denominatorTitles.count
        let applicable = trackCount >= minTurnoverTracks

        return AlbumTurnoverMatchResult(
            basis: basis, ambiguous: ambiguous, noCanonicalMatch: noCanonicalMatch,
            canonicalArtist: canonicalArtist, canonicalAlbum: canonicalAlbum, canonicalTrackCount: canonicalTrackCount,
            observedDistinct: observed.count, coverage: coverage,
            denominatorTitles: denominatorTitles, trackCount: trackCount, applicable: applicable,
            resolved: resolution != nil
        )
    }

    // MARK: - Cycle math

    struct TrackCycleState: Sendable {
        let title: String
        let heardThisCycle: Bool
    }

    struct CycleResult: Sendable {
        /// Duration in days of each completed listen-through, in completion order.
        let cycleDurationsDays: [Double]
        /// The date of the scrobble that completed the most recent cycle; nil if none completed.
        let lastCycleEndDate: Date?
        /// Distinct canonical tracks heard since the last completed cycle.
        let inProgressHeard: Int
        /// Canonical tracklist size (counting repeated titles as separate occurrences).
        let inProgressTotal: Int
        /// Canonical track titles (original casing) still unheard this cycle.
        let inProgressMissing: [String]
        /// Every canonical track in tracklist order with whether it's been heard this cycle.
        let trackStates: [TrackCycleState]
    }

    /// Median of a value list — sorted ascending; average of the two middle
    /// values on an even count, else the middle value; 0 for an empty list.
    nonisolated static func median(_ nums: [Double]) -> Double {
        guard !nums.isEmpty else { return 0 }
        let sorted = nums.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// Counts completed listen-through cycles. A cycle completes when every
    /// canonical track has been scrobbled at least once since the last
    /// completion; its duration is measured from the cycle's first canonical
    /// scrobble to the one that completes it.
    ///
    /// `scrobbles` MUST be sorted ascending by `playedAt` (guaranteed by
    /// `AlbumGroup.scrobbles`). Non-canonical scrobbles are ignored (they
    /// can't advance a cycle), which is what makes a consistently-skipped
    /// deep cut stall turnover rather than silently shrinking the denominator.
    ///
    /// A release can legitimately repeat a title (e.g. two same-named hidden
    /// interludes) — `requiredCounts` tracks how many times each normalized
    /// title occurs on the physical release so hearing a repeated title twice
    /// satisfies both occurrences, since a scrobble's title alone can't say
    /// which physical position was played.
    nonisolated static func computeCycles(scrobbles: [ScrobbleSnapshot], canonicalTitles: [String]) -> CycleResult {
        var normToOriginal: [String: String] = [:]
        var requiredCounts: [String: Int] = [:]
        for title in canonicalTitles {
            let norm = TextNormalization.normalizeTrackTitle(title)
            guard !norm.isEmpty else { continue }
            if normToOriginal[norm] == nil { normToOriginal[norm] = title }
            requiredCounts[norm, default: 0] += 1
        }
        let total = requiredCounts.values.reduce(0, +)

        var durations: [Double] = []
        var lastCycleEndDate: Date?
        var seenCounts: [String: Int] = [:]
        var satisfied = 0
        var cycleStart: Date?

        for s in scrobbles {
            let norm = TextNormalization.normalizeTrackTitle(s.trackName)
            guard let required = requiredCounts[norm] else { continue }
            if cycleStart == nil { cycleStart = s.playedAt }
            let prevSeen = seenCounts[norm] ?? 0
            let newSeen = prevSeen + 1
            seenCounts[norm] = newSeen
            satisfied += min(newSeen, required) - min(prevSeen, required)
            if satisfied == total, total > 0 {
                durations.append(s.playedAt.timeIntervalSince(cycleStart!) / 86400.0)
                lastCycleEndDate = s.playedAt
                seenCounts = [:]
                satisfied = 0
                cycleStart = nil
            }
        }

        // Built from the original list, not `normToOriginal`, so a repeated
        // title gets a row per physical occurrence. Occurrences of the same
        // title are credited in tracklist order as qualifying scrobbles
        // accumulate — not a claim about which exact position was played,
        // just cumulative progress within the still-open trailing cycle.
        var missing: [String] = []
        var missingSeen = Set<String>()
        var trackStates: [TrackCycleState] = []
        var consumed: [String: Int] = [:]
        for title in canonicalTitles {
            let norm = TextNormalization.normalizeTrackTitle(title)
            guard !norm.isEmpty else { continue }
            let seen = seenCounts[norm] ?? 0
            let usedSoFar = consumed[norm] ?? 0
            consumed[norm] = usedSoFar + 1
            let heard = usedSoFar < seen
            if seen < (requiredCounts[norm] ?? 1), !missingSeen.contains(norm) {
                missingSeen.insert(norm)
                missing.append(normToOriginal[norm] ?? title)
            }
            trackStates.append(TrackCycleState(title: title, heardThisCycle: heard))
        }

        return CycleResult(
            cycleDurationsDays: durations, lastCycleEndDate: lastCycleEndDate,
            inProgressHeard: satisfied, inProgressTotal: total, inProgressMissing: missing, trackStates: trackStates
        )
    }

    // MARK: - Full per-album result + Overview-card entry point

    /// Stable per-album-group key for match-resolution persistence and list
    /// identity.
    ///
    /// Formats a turnover rate — shared by the album detail page and
    /// Overview's post-sync turnover banner.
    nonisolated static func formatTurnoverRate(_ rateDays: Double?) -> String {
        guard let rateDays else { return "No full cycle yet" }
        let d = rateDays.rounded()
        if d <= 1 { return "~once a day" }
        if rateDays < 14 { return "once every \(Int(d)) days" }
        if rateDays < 60 { return "once every \(Int((rateDays / 7).rounded())) weeks" }
        return "once every \(Int((rateDays / 30).rounded())) months"
    }

    nonisolated static func groupKey(artist: String, displayName: String) -> String {
        "\(artist)\u{0}\(TextNormalization.normalizeAlbumName(displayName))"
    }

    struct AlbumTurnover: Sendable {
        let artist: String
        let album: String
        let applicable: Bool
        let basis: AlbumMatchBasis
        let ambiguous: Bool
        let noCanonicalMatch: Bool
        let resolved: Bool
        /// Median days per completed cycle; nil if no cycle has ever completed.
        let rateDays: Double?
        let cyclesCompleted: Int
        let lastTurnoverDate: Date?
        let trackCount: Int
        let observedDistinct: Int
        let inProgressHeard: Int
        let inProgressTotal: Int
        let inProgressMissing: [String]
        let tracks: [TrackCycleState]
        let isCompilation: Bool
        let groupKey: String
        let imageURL: String?
    }

    /// Composes the matching/classification branch (`resolveTurnover`) with
    /// the cycle-completion math (`computeCycles`) into the complete result
    /// shape the Album Turnover tool and Overview card both consume.
    static func resolveAlbumTurnover(
        context: ModelContext, group: AlbumGroup, resolution: StoredAlbumResolution?, client: LastfmAPIClient
    ) async throws -> AlbumTurnover {
        let match = try await resolveTurnover(context: context, group: group, resolution: resolution, client: client)
        return assemble(group: group, match: match)
    }

    /// The cycle math + result shape, from a group and its match decision. Pure.
    nonisolated static func assemble(group: AlbumGroup, match: AlbumTurnoverMatchResult) -> AlbumTurnover {
        let cycles = computeCycles(scrobbles: group.scrobbles, canonicalTitles: match.denominatorTitles)
        let rateDays: Double? = cycles.cycleDurationsDays.isEmpty ? nil : median(cycles.cycleDurationsDays)
        return AlbumTurnover(
            artist: group.artist, album: group.displayName, applicable: match.applicable,
            basis: match.basis, ambiguous: match.ambiguous, noCanonicalMatch: match.noCanonicalMatch,
            resolved: match.resolved, rateDays: rateDays, cyclesCompleted: cycles.cycleDurationsDays.count,
            lastTurnoverDate: cycles.lastCycleEndDate, trackCount: match.trackCount, observedDistinct: match.observedDistinct,
            inProgressHeard: cycles.inProgressHeard, inProgressTotal: cycles.inProgressTotal, inProgressMissing: cycles.inProgressMissing,
            tracks: cycles.trackStates, isCompilation: TextNormalization.isCompilationArtist(group.artist),
            groupKey: groupKey(artist: group.artist, displayName: group.displayName),
            imageURL: TextNormalization.firstNonPlaceholderImage(group.scrobbles.map(\.imageURL))
        )
    }

    /// An immutable, read-only copy of everything Turnover resolution reads — the cached
    /// Last.fm tracklists and the user's saved "Fix album match" decisions — so the query
    /// framework can run the engine's own match + cycle math off the main actor. It never
    /// touches the network: an album whose tracklist isn't cached yet is `.pending`.
    struct Snapshot: Sendable {
        enum Lookup: Sendable {
            case value(AlbumTurnover)
            /// Fewer than `minTurnoverTracks` tracks — not a full-album listening pattern.
            case notApplicable
            /// The tracklist this album needs hasn't been fetched and cached yet.
            case pending
        }

        /// `tracklistCacheKey` → cached lookup result.
        var tracklists: [String: AlbumTracklistResult] = [:]
        /// `Album.identityKey` → saved resolution (only albums that have one).
        var resolutions: [String: StoredAlbumResolution] = [:]

        nonisolated static let empty = Snapshot()

        nonisolated func resolution(for group: AlbumGroup) -> StoredAlbumResolution? {
            AlbumTurnoverEngine.resolutionKeys(for: group).lazy.compactMap { resolutions[$0] }.first
        }

        /// The cached catalog lookup a group's resolution needs, or nil when it needs none or
        /// it isn't cached yet.
        nonisolated func cachedLookup(for group: AlbumGroup) -> AlbumTracklistResult? {
            guard let request = AlbumTurnoverEngine.tracklistRequest(group: group, resolution: resolution(for: group)) else { return nil }
            return tracklists[AlbumTurnoverEngine.tracklistCacheKey(artist: request.artist, album: request.album)]
        }

        /// The catalog lookup this group still needs, if it isn't cached.
        nonisolated func missingRequest(for group: AlbumGroup) -> TracklistRequest? {
            guard let request = AlbumTurnoverEngine.tracklistRequest(group: group, resolution: resolution(for: group)),
                  tracklists[AlbumTurnoverEngine.tracklistCacheKey(artist: request.artist, album: request.album)] == nil
            else { return nil }
            return request
        }

        /// The album's match status, or nil while the tracklist it needs isn't cached yet. Unlike
        /// `lookup`, this answers for one-track "albums" too — the match is a fact about the album.
        nonisolated func matchStatus(for group: AlbumGroup) -> AlbumMatchStatus? {
            let resolution = resolution(for: group)
            var found: AlbumTracklistResult?
            if let request = AlbumTurnoverEngine.tracklistRequest(group: group, resolution: resolution) {
                guard let cached = tracklists[AlbumTurnoverEngine.tracklistCacheKey(artist: request.artist, album: request.album)] else { return nil }
                found = cached
            }
            return AlbumMatchStatus.classify(AlbumTurnoverEngine.matchResult(group: group, resolution: resolution, lookup: found), resolution: resolution)
        }

        nonisolated func lookup(for group: AlbumGroup) -> Lookup {
            let resolution = resolution(for: group)
            var found: AlbumTracklistResult?
            if let request = AlbumTurnoverEngine.tracklistRequest(group: group, resolution: resolution) {
                guard let cached = tracklists[AlbumTurnoverEngine.tracklistCacheKey(artist: request.artist, album: request.album)] else { return .pending }
                found = cached
            }
            let match = AlbumTurnoverEngine.matchResult(group: group, resolution: resolution, lookup: found)
            guard match.applicable else { return .notApplicable }
            return .value(AlbumTurnoverEngine.assemble(group: group, match: match))
        }
    }

    /// Read-only: never fetches and never writes.
    nonisolated static func loadSnapshot(context: ModelContext) -> Snapshot {
        var snapshot = Snapshot()
        for entry in (try? context.fetch(FetchDescriptor<AlbumTracklistCacheEntry>())) ?? [] {
            snapshot.tracklists[entry.cacheKey] = result(from: entry)
        }
        for album in (try? context.fetch(FetchDescriptor<Album>())) ?? [] {
            if let resolution = resolution(from: album) { snapshot.resolutions[album.identityKey] = resolution }
        }
        return snapshot
    }

    /// Every album group in `scrobbles`, keyed by artist — the same per-artist grouping
    /// `buildAllGroups` does, synchronously.
    nonisolated static func buildGroupsByArtist(scrobbles: [ScrobbleSnapshot]) -> [String: [AlbumGroup]] {
        let byArtist = Dictionary(grouping: scrobbles.filter { !$0.albumName.isEmpty }, by: \.artistName)
        return byArtist.mapValues { buildAlbumGroups(from: $0) }
    }

    enum TurnoverSort {
        case fastest, slowest, most, fewest, recent, stale
    }

    /// Builds every artist's plausible full-album candidates — the
    /// candidate-selection step of `fetchRankings`/`fetchAllCompletions`,
    /// factored out so callers can run it inside `Task.detached`.
    /// `nonisolated`: the per-artist pairwise fuzzy-matching pass inside
    /// `buildAlbumGroups` is genuinely expensive across a whole library —
    /// confirmed directly (via a heartbeat probe) to be a multi-second
    /// synchronous block on the main actor before this was detached.
    ///
    /// `async` purely to insert periodic `Task.yield()`s: Swift's
    /// cooperative thread pool has roughly one thread per core, and a tight
    /// non-yielding loop here can starve that pool — including the main
    /// actor's own thread — even though this work is already off the main
    /// actor by construction. Confirmed directly: without these yields, the
    /// main actor's own timer continuations were measurably delayed while
    /// this loop ran, the same "app feels frozen" symptom as before, just
    /// via thread-pool contention instead of a direct main-actor block.
    nonisolated static func buildCandidates(scrobbles allScrobbles: [ScrobbleSnapshot], includeCompilations: Bool) async -> [AlbumGroup] {
        let byArtist = Dictionary(grouping: allScrobbles.filter { !$0.albumName.isEmpty }, by: \.artistName)
        var candidates: [AlbumGroup] = []
        for (index, artistScrobbles) in byArtist.values.enumerated() {
            for group in buildAlbumGroups(from: artistScrobbles) {
                if !includeCompilations, TextNormalization.isCompilationArtist(group.artist) { continue }
                // Source also widens this to a cached canonical tracklist's
                // size when a stored resolution exists, so a manually
                // confirmed full album isn't dropped just because only a
                // couple of its tracks have been scrobbled so far. Not
                // reachable until a resolution has been stored.
                let distinct = distinctObserved(group).count
                guard distinct >= minTurnoverTracks else { continue }
                candidates.append(group)
            }
            if index % 5 == 4 { await Task.yield() }
        }
        return candidates
    }

    /// Album turnover rankings — builds every
    /// artist's album groups, keeps plausible full-album candidates (enough
    /// tracks, and not a compilation unless asked), evaluates the
    /// most-played `limit` of them against Last.fm, and sorts. Stored
    /// resolutions are honored when present; otherwise a group takes the
    /// auto-classify path.
    ///
    /// Evaluates candidates sequentially, not concurrently like
    /// `TopTagsEngine` — the per-candidate `resolveAlbumTurnover` calls below
    /// share one `ModelContext`/`LastfmAPIClient`, neither Sendable, so
    /// batching them across `withTaskGroup` child tasks isn't safe. Still
    /// documented technical debt (unlike the candidate-building step above,
    /// which IS now off the main actor): a cold run makes up to `limit`
    /// sequential live fetches, each 120ms apart, but every subsequent
    /// reload after that is cache hits only, and each already yields via its
    /// own network `await` rather than blocking synchronously.
    static func fetchRankings(
        context: ModelContext, client: LastfmAPIClient,
        sort: TurnoverSort = .fastest, includeCompilations: Bool = false, limit: Int = 150
    ) async throws -> [AlbumTurnover] {
        let container = context.container
        let snapshots = try await offMain { try await AlbumTurnoverDataReader(modelContainer: container).fetchSortedSnapshots() }
        var candidates = await offMain {
            await buildCandidates(scrobbles: snapshots, includeCompilations: includeCompilations)
        }
        candidates.sort { $0.scrobbles.count > $1.scrobbles.count }
        let evaluated = Array(candidates.prefix(limit))

        let results = try await resolveTurnovers(for: evaluated, context: context, client: client)
        var applicable = results.filter(\.applicable)
        switch sort {
        case .most, .fewest:
            applicable.sort { a, b in
                let diff = sort == .most ? b.cyclesCompleted - a.cyclesCompleted : a.cyclesCompleted - b.cyclesCompleted
                return diff != 0 ? diff < 0 : a.album < b.album
            }
        case .recent, .stale:
            applicable.sort { a, b in
                let aNull = a.lastTurnoverDate == nil
                let bNull = b.lastTurnoverDate == nil
                if aNull, bNull { return a.album < b.album }
                if aNull { return false }
                if bNull { return true }
                return sort == .recent ? a.lastTurnoverDate! > b.lastTurnoverDate! : a.lastTurnoverDate! < b.lastTurnoverDate!
            }
        case .fastest, .slowest:
            applicable.sort { a, b in
                let aNull = a.rateDays == nil
                let bNull = b.rateDays == nil
                if aNull, bNull { return a.album < b.album }
                if aNull { return sort == .slowest }
                if bNull { return sort != .slowest }
                return sort == .fastest ? a.rateDays! < b.rateDays! : a.rateDays! > b.rateDays!
            }
        }
        return applicable
    }

    /// Every group's turnover, in the order given. Groups whose tracklist is already cached are
    /// computed from a read-only `Snapshot` on a background task — the same `matchResult` +
    /// `assemble` the per-group path runs, just without a main-context fetch per group. Only the
    /// groups still missing a tracklist go through `resolveAlbumTurnover`, which fetches it from
    /// Last.fm (sequentially, rate-limited) and caches it, exactly as before. Measured after a
    /// first sync: this loop alone had kept the main thread ~60% busy for minutes.
    static func resolveTurnovers(
        for groups: [AlbumGroup], context: ModelContext, client: LastfmAPIClient
    ) async throws -> [AlbumTurnover] {
        let container = context.container
        let snapshot = await offMain { await AlbumTurnoverDataReader(modelContainer: container).loadSnapshot() }
        let cached: [Int: AlbumTurnover] = await offMain {
            var cached: [Int: AlbumTurnover] = [:]
            for (index, group) in groups.enumerated() {
                switch snapshot.lookup(for: group) {
                case .value(let turnover): cached[index] = turnover
                case .notApplicable:
                    // `resolveAlbumTurnover` would return the same result with `applicable == false`;
                    // every caller drops those, so it is built without the cycle math.
                    cached[index] = assemble(group: group, match: matchResult(
                        group: group, resolution: snapshot.resolution(for: group),
                        lookup: snapshot.cachedLookup(for: group)
                    ))
                case .pending: break
                }
                if index % 200 == 199 { await Task.yield() }
            }
            return cached
        }
        var results: [AlbumTurnover] = []
        results.reserveCapacity(groups.count)
        for (index, group) in groups.enumerated() {
            if let turnover = cached[index] {
                results.append(turnover)
            } else {
                let resolution = storedResolution(context: context, group: group)
                results.append(try await resolveAlbumTurnover(context: context, group: group, resolution: resolution, client: client))
            }
            if index % 10 == 9 { await Task.yield() }
        }
        return results
    }

    struct AlbumTurnoverOverviewEntry: Identifiable, Sendable {
        let id: String
        let artist: String
        let album: String
        let missingCount: Int
        let imageURL: String?
    }

    /// Overview-card-specific filter — mirrors `AlbumTurnoversCard`'s "1 or 2
    /// tracks away from completing the current cycle" rule (the same "Only
    /// show albums close to turnover" filter as the Album Turnover tool).
    /// Custom image overrides/popularity flags are still deferred — not
    /// built anywhere else either — but the plain locally-known
    /// artwork (from the album's own scrobbles) isn't, so it's used here.
    static func overviewCandidates(from turnovers: [AlbumTurnover]) -> [AlbumTurnoverOverviewEntry] {
        turnovers
            .filter { !$0.inProgressMissing.isEmpty && $0.inProgressMissing.count <= 2 }
            .map { AlbumTurnoverOverviewEntry(id: $0.groupKey, artist: $0.artist, album: $0.album, missingCount: $0.inProgressMissing.count, imageURL: $0.imageURL) }
    }

    // MARK: - Overview totals "N turned over" stat

    /// Every artist's full set of album groups, unfiltered (unlike
    /// `buildCandidates`, which drops compilations/too-short albums for the
    /// visible Turnover card) — `fetchAllCompletions`'s full-library scope
    /// needs every group, not a candidate shortlist. `nonisolated` for the
    /// same reason as `buildCandidates`: the fuzzy-matching pass inside
    /// `buildAlbumGroups` is genuinely expensive run across a whole library.
    nonisolated static func buildAllGroups(scrobbles allScrobbles: [ScrobbleSnapshot]) async -> [AlbumGroup] {
        let byArtist = Dictionary(grouping: allScrobbles.filter { !$0.albumName.isEmpty }, by: \.artistName)
        var groups: [AlbumGroup] = []
        for (index, artistScrobbles) in byArtist.values.enumerated() {
            groups.append(contentsOf: buildAlbumGroups(from: artistScrobbles))
            // Same thread-pool-starvation reasoning as `buildCandidates`.
            if index % 5 == 4 { await Task.yield() }
        }
        return groups
    }

    /// Cache-aware fetch of every applicable album's most recent completed-
    /// cycle date, across the WHOLE library (not capped to a candidate pool
    /// like `fetchRankings`) — matches `lastfm:getOverviewCompletedAlbums`'s
    /// full scope. Recomputed once per sync; a cache hit needs no network
    /// calls at all. This is the single most expensive computation in the
    /// whole Overview page on a cold cache — potentially more albums than
    /// the 150-candidate Overview Turnover card ever evaluates, since every
    /// album with an album-tagged scrobble is in scope, not just the most-
    /// played 150. Genuinely can take a while the first time (or after a
    /// cache clear), same category of cost as Album Turnover's own
    /// already-flagged cold-cache case, just larger in scope.
    static func fetchAllCompletions(context: ModelContext, client: LastfmAPIClient) async throws -> [String: Date] {
        let syncedAt = try context.fetch(FetchDescriptor<SyncState>()).first?.lastSyncedAt

        var descriptor = FetchDescriptor<AlbumTurnoverCompletionCache>()
        descriptor.fetchLimit = 1
        let existing = try context.fetch(descriptor).first
        if let existing, existing.computedForSyncAt == syncedAt {
            return (try? JSONDecoder().decode([String: Date].self, from: existing.completionsJSON)) ?? [:]
        }

        let container = context.container
        let snapshots = try await offMain { try await AlbumTurnoverDataReader(modelContainer: container).fetchSortedSnapshots() }
        let allGroups = await offMain { await buildAllGroups(scrobbles: snapshots) }

        var completions: [String: Date] = [:]
        for turnover in try await resolveTurnovers(for: allGroups, context: context, client: client) {
            if turnover.applicable, let lastDate = turnover.lastTurnoverDate {
                completions[turnover.groupKey] = lastDate
            }
        }

        let entry = existing ?? AlbumTurnoverCompletionCache(computedForSyncAt: nil, computedAt: Date(), completionsJSON: Data())
        entry.computedForSyncAt = syncedAt
        entry.computedAt = Date()
        entry.completionsJSON = (try? JSONEncoder().encode(completions)) ?? Data()
        if existing == nil { context.insert(entry) }
        try context.save()

        return completions
    }

    /// Count of albums whose most recently completed cycle falls within
    /// `[from, to]` — a cheap filter over the cached completions map, safe
    /// to call on every date-range change without touching the network.
    static func completedCount(in completions: [String: Date], from: Date, to: Date) -> Int {
        completions.values.filter { $0 >= from && $0 <= to }.count
    }
}

/// The turnover engine's own background reader: the library as plain snapshots, and the read-only
/// tracklist/resolution snapshot, each on its own context.
@ModelActor
actor AlbumTurnoverDataReader {
    func fetchSortedSnapshots() throws -> [ScrobbleSnapshot] {
        try modelContext.fetch(FetchDescriptor<Scrobble>(sortBy: [SortDescriptor(\.playedAt)])).map(\.snapshot)
    }

    func loadSnapshot() -> AlbumTurnoverEngine.Snapshot {
        AlbumTurnoverEngine.loadSnapshot(context: modelContext)
    }
}
