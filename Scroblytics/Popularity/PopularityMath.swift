import Foundation

/// Pure popularity calculation — no SwiftData, no network — so it can be
/// checked in isolation.

enum PopularityKind: String, Sendable, CaseIterable, Hashable {
    case artist, album, track

    /// Which raw signals feed each kind's combined score — exactly
    /// these. Notably an ARTIST's Last.fm
    /// playcount is fetched but never scored.
    var fields: [PopularityField] {
        switch self {
        case .artist: [.lfmListeners, .deezerFans]
        case .album: [.lfmListeners, .lfmPlaycount, .deezerFans]
        case .track: [.lfmListeners, .lfmPlaycount, .deezerRank]
        }
    }
}

enum PopularityField: String, Sendable, Hashable {
    case lfmListeners, lfmPlaycount, deezerFans, deezerRank

    var label: String {
        switch self {
        case .lfmListeners: "Last.fm listeners"
        case .lfmPlaycount: "Last.fm plays"
        case .deezerFans: "Deezer fans"
        case .deezerRank: "Deezer rank"
        }
    }
}

struct PopularitySignals: Sendable, Equatable {
    var lfmListeners: Int?
    var lfmPlaycount: Int?
    var deezerFans: Int?
    var deezerRank: Int?

    func value(_ field: PopularityField) -> Int? {
        switch field {
        case .lfmListeners: lfmListeners
        case .lfmPlaycount: lfmPlaycount
        case .deezerFans: deezerFans
        case .deezerRank: deezerRank
        }
    }
}

struct PopularityRecord: Sendable {
    let key: String
    let kind: PopularityKind
    /// Lowercased/trimmed artist name — the artist-scoped pool's grouping key.
    let artistKey: String
    let signals: PopularitySignals
}

enum PopularityConstants {
    /// `POPULARITY_TOP_PERCENTILE` — combined score at or above the 75th
    /// percentile of its pool's combined scores counts as popular.
    static let topPercentile = 0.75
    /// `POPULARITY_ARTIST_MIN_POOL` — an artist-scoped tier needs at least this
    /// many scored items of the same kind for that artist, else it isn't computed.
    static let artistMinPool = 4
    static let staleInterval: TimeInterval = 30 * 24 * 60 * 60
}

/// Fraction of `sorted` that is `<= value`.
func popularityPercentileRank(_ sorted: [Double], _ value: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    var lo = 0
    var hi = sorted.count
    while lo < hi {
        let mid = (lo + hi) >> 1
        if sorted[mid] <= value { lo = mid + 1 } else { hi = mid }
    }
    return Double(lo) / Double(sorted.count)
}

/// Value at index `floor(p * (n - 1))`. Empty →
/// +infinity so nothing qualifies.
func popularityPercentileValue(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return .infinity }
    let idx = min(sorted.count - 1, max(0, Int((p * Double(sorted.count - 1)).rounded(.down))))
    return sorted[idx]
}

/// One comparison pool: every record's per-signal percentile within the pool,
/// averaged into a combined score, plus the pool's top-quartile cutoff.
struct PopularityPool: Sendable {
    let kind: PopularityKind
    fileprivate let sortedByField: [PopularityField: [Double]]
    /// Combined score per record key — only records with at least one signal.
    let scores: [String: Double]
    let cutoff: Double?

    var size: Int { scores.count }

    init(kind: PopularityKind, records: [PopularityRecord]) {
        self.kind = kind
        var sorted: [PopularityField: [Double]] = [:]
        for field in kind.fields {
            sorted[field] = records.compactMap { $0.signals.value(field).map(Double.init) }.sorted()
        }
        sortedByField = sorted
        var scores: [String: Double] = [:]
        for record in records {
            if let score = Self.combinedScore(record.signals, kind: kind, sorted: sorted) {
                scores[record.key] = score
            }
        }
        self.scores = scores
        cutoff = scores.isEmpty ? nil : popularityPercentileValue(scores.values.sorted(), PopularityConstants.topPercentile)
    }

    private static func combinedScore(_ signals: PopularitySignals, kind: PopularityKind, sorted: [PopularityField: [Double]]) -> Double? {
        let percentiles = kind.fields.compactMap { field in
            signals.value(field).map { popularityPercentileRank(sorted[field] ?? [], Double($0)) }
        }
        guard !percentiles.isEmpty else { return nil }
        return percentiles.reduce(0, +) / Double(percentiles.count)
    }

    func isPopular(_ key: String) -> Bool {
        guard let score = scores[key], let cutoff else { return false }
        return score >= cutoff
    }

    func percentile(of field: PopularityField, value: Int) -> Double {
        popularityPercentileRank(sortedByField[field] ?? [], Double(value))
    }
}

struct PopularityDetail: Sendable {
    struct FieldRow: Sendable {
        let field: PopularityField
        let value: Int
        let libraryPercentile: Double
        /// nil when the artist-scoped pool is below the minimum size.
        let artistPercentile: Double?
    }

    let kind: PopularityKind
    let fields: [FieldRow]

    let libraryCombined: Double?
    let libraryCutoff: Double?
    let libraryPool: Int
    let libraryPopular: Bool

    /// False for artists — nothing to compare an artist against but itself.
    let hasArtistTier: Bool
    let artistPool: Int
    let artistMinPool: Int
    let artistPoolIsSufficient: Bool
    let artistCombined: Double?
    let artistCutoff: Double?
    let artistPopular: Bool
}

struct PopularityIndicator: Sendable, Equatable {
    let libraryPopular: Bool
    let artistPopular: Bool
    var isPopular: Bool { libraryPopular || artistPopular }
}

struct PopularitySnapshot: Sendable {
    private struct GroupKey: Hashable {
        let kind: PopularityKind
        let artistKey: String
    }

    static let empty = PopularitySnapshot(records: [])

    private let records: [String: PopularityRecord]
    private let libraryPools: [PopularityKind: PopularityPool]
    /// Artist-scoped pools, only for groups that reach the minimum size.
    private let artistPools: [GroupKey: PopularityPool]
    /// Scored-item counts for EVERY artist group, including ones below the
    /// minimum — the tooltip reports "n of 4 needed".
    private let artistGroupSizes: [GroupKey: Int]

    var recordCount: Int { records.count }

    init(records list: [PopularityRecord]) {
        var records: [String: PopularityRecord] = [:]
        for record in list { records[record.key] = record }
        self.records = records

        var library: [PopularityKind: PopularityPool] = [:]
        var groups: [GroupKey: [PopularityRecord]] = [:]
        for kind in PopularityKind.allCases {
            let ofKind = list.filter { $0.kind == kind }
            library[kind] = PopularityPool(kind: kind, records: ofKind)
            if kind != .artist {
                for record in ofKind { groups[GroupKey(kind: kind, artistKey: record.artistKey), default: []].append(record) }
            }
        }
        libraryPools = library

        var pools: [GroupKey: PopularityPool] = [:]
        var sizes: [GroupKey: Int] = [:]
        for (groupKey, members) in groups {
            let pool = PopularityPool(kind: groupKey.kind, records: members)
            sizes[groupKey] = pool.size
            if pool.size >= PopularityConstants.artistMinPool { pools[groupKey] = pool }
        }
        artistPools = pools
        artistGroupSizes = sizes
    }

    /// True once the key has a cached record — even an all-nil one (both
    /// services genuinely had nothing). False means still unresolved.
    func hasRecord(forKey key: String) -> Bool { records[key] != nil }

    /// The combined library-wide score (0–1) — the number the diamond's
    /// library tier thresholds. nil when unresolved OR when the record carries
    /// no scorable signal.
    func libraryScore(forKey key: String) -> Double? {
        records[key].flatMap { libraryPools[$0.kind]?.scores[key] }
    }

    /// Whether this entity's artist pool is big enough for an artist-scoped tier.
    func hasArtistTier(forKey key: String) -> Bool {
        guard let record = records[key] else { return false }
        return artistPools[GroupKey(kind: record.kind, artistKey: record.artistKey)] != nil
    }

    /// nil when the key has no cached record (still queued, or never seeded).
    func indicator(forKey key: String) -> PopularityIndicator? {
        guard let record = records[key] else { return nil }
        let library = libraryPools[record.kind]?.isPopular(key) ?? false
        let artist = artistPools[GroupKey(kind: record.kind, artistKey: record.artistKey)]?.isPopular(key) ?? false
        return PopularityIndicator(libraryPopular: library, artistPopular: artist)
    }

    /// nil when the key has no cached record.
    func detail(forKey key: String) -> PopularityDetail? {
        guard let record = records[key], let library = libraryPools[record.kind] else { return nil }
        let groupKey = GroupKey(kind: record.kind, artistKey: record.artistKey)
        let hasArtistTier = record.kind != .artist
        let artistPool = artistPools[groupKey]

        let rows: [PopularityDetail.FieldRow] = record.kind.fields.compactMap { field in
            guard let value = record.signals.value(field) else { return nil }
            return .init(
                field: field, value: value,
                libraryPercentile: library.percentile(of: field, value: value),
                artistPercentile: artistPool?.percentile(of: field, value: value)
            )
        }

        return PopularityDetail(
            kind: record.kind,
            fields: rows,
            libraryCombined: library.scores[key],
            libraryCutoff: library.cutoff,
            libraryPool: library.size,
            libraryPopular: library.isPopular(key),
            hasArtistTier: hasArtistTier,
            artistPool: hasArtistTier ? (artistGroupSizes[groupKey] ?? 0) : 0,
            artistMinPool: PopularityConstants.artistMinPool,
            artistPoolIsSufficient: artistPool != nil,
            artistCombined: artistPool?.scores[key],
            artistCutoff: artistPool?.cutoff,
            artistPopular: artistPool?.isPopular(key) ?? false
        )
    }
}
