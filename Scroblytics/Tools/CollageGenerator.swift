import Foundation
import SwiftData

enum CollageSource: String, Codable, CaseIterable, Identifiable {
    case top
    case period

    var id: Self { self }
    var label: String {
        switch self {
        case .top: "Top items"
        case .period: "One per release period"
        }
    }
}

enum CollagePeriod: String, Codable, CaseIterable, Identifiable {
    case week, month, year, decade

    var id: Self { self }
    var label: String { rawValue.capitalized }
}

enum CollageGrid: String, Codable, CaseIterable, Identifiable {
    case three = "3 × 3"
    case five = "5 × 5"
    case seven = "7 × 7"
    case ten = "10 × 10"
    case twelve = "12 × 12"
    case widescreen = "16 × 9"

    var id: Self { self }
    var dimensions: (columns: Int, rows: Int) {
        switch self {
        case .three: (3, 3)
        case .five: (5, 5)
        case .seven: (7, 7)
        case .ten: (10, 10)
        case .twelve: (12, 12)
        case .widescreen: (16, 9)
        }
    }
    var tileCount: Int { dimensions.columns * dimensions.rows }
}

struct CollageItem: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let artist: String
    let album: String?
    let metricValue: Int
    let imageURL: String?
    let periodLabel: String?
    /// What the tile's badge says when it is not the plays or time of the collage's own ranking (a collage made from a query shows the
    /// value of the column the results are sorted by). nil: the badge shows `metricValue`.
    var valueText: String? = nil
}

struct ChartTopperEntry: Identifiable, Hashable, Sendable {
    let id: String
    let rank: Int
    let name: String
    let artist: String
    let album: String?
    let metricValue: Int
    let imageURL: String?
    let loved: Bool
    let flagged: Bool
    let exportTrack: AppleMusicPlaylistTrack?
}

struct ChartTopperPeriod: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let start: Date
    let entries: [ChartTopperEntry]
}

@ModelActor
actor ChartToppersReader {
    func load(
        entity: TopChartsEntity,
        metric: TopChartsMetric,
        period: CollagePeriod,
        yearRange: Int
    ) throws -> [ChartTopperPeriod] {
        let rows = try modelContext.fetch(
            FetchDescriptor<Scrobble>(sortBy: [SortDescriptor(\.playedAt)])
        ).map(\.snapshot)
        let durations = DurationEngine.loadSnapshot(context: modelContext).secondsLookup
        let releaseDates = ReleaseDateEngine.loadSnapshot(context: modelContext)
        let imageLookup = try ImageResolutionEngine.imageLookup(context: modelContext)
        let lovedKeys = LovedTracksEngine.lovedSet(context: modelContext)
        let flaggedKeys = Set(
            (try modelContext.fetch(FetchDescriptor<FlaggedTrack>())).map {
                TextNormalization.lovedKey(artist: $0.artist, track: $0.track)
            }
        )
        return CollagePeriodEngine.rankPeriods(
            rows,
            entity: entity,
            metric: metric,
            period: period,
            yearRange: yearRange,
            entriesPerPeriod: 10,
            durations: durations,
            releaseDates: releaseDates,
            imageLookup: imageLookup,
            lovedKeys: lovedKeys,
            flaggedKeys: flaggedKeys
        )
    }
}

@ModelActor
actor CollagePeriodReader {
    func load(
        entity: TopChartsEntity,
        metric: TopChartsMetric,
        period: CollagePeriod,
        limit: Int
    ) throws -> [CollageItem] {
        let rows = try modelContext.fetch(
            FetchDescriptor<Scrobble>(sortBy: [SortDescriptor(\.playedAt)])
        ).map(\.snapshot)
        let durations = DurationEngine.loadSnapshot(context: modelContext).secondsLookup
        let releaseDates = ReleaseDateEngine.loadSnapshot(context: modelContext)
        let imageLookup = try ImageResolutionEngine.imageLookup(context: modelContext)
        return CollagePeriodEngine.rank(
            rows,
            entity: entity,
            metric: metric,
            period: period,
            limit: limit,
            durations: durations,
            releaseDates: releaseDates,
            imageLookup: imageLookup
        )
    }
}

enum CollagePeriodEngine {
    private struct BucketKey: Hashable {
        let periodStart: Date
        let entityKey: String
    }

    private struct Aggregate {
        var name: String
        var artist: String
        var album: String?
        var count = 0
        var seconds = 0
        var firstPlayedAt: Date
        var fallbackImageURL: String?
        var representativeTracks: [String: RepresentativeTrack]
    }

    private struct RepresentativeTrack {
        var artist: String
        var track: String
        var album: String
        var count: Int
        var seconds: Int
        var lastPlayedAt: Date
    }

    nonisolated static func rank(
        _ scrobbles: [ScrobbleSnapshot],
        entity: TopChartsEntity,
        metric: TopChartsMetric,
        period: CollagePeriod,
        limit: Int,
        durations: [String: Int],
        releaseDates: ReleaseDateEngine.Snapshot,
        imageLookup: [String: String]
    ) -> [CollageItem] {
        rankPeriods(
            scrobbles,
            entity: entity,
            metric: metric,
            period: period,
            yearRange: 0,
            entriesPerPeriod: 1,
            durations: durations,
            releaseDates: releaseDates,
            imageLookup: imageLookup,
            lovedKeys: [],
            flaggedKeys: []
        )
        .prefix(limit)
        .compactMap { period in
            guard let winner = period.entries.first else { return nil }
            return CollageItem(
                id: period.id,
                name: winner.name,
                artist: winner.artist,
                album: winner.album,
                metricValue: winner.metricValue,
                imageURL: winner.imageURL,
                periodLabel: period.label
            )
        }
    }

    nonisolated static func rankPeriods(
        _ scrobbles: [ScrobbleSnapshot],
        entity: TopChartsEntity,
        metric: TopChartsMetric,
        period: CollagePeriod,
        yearRange: Int,
        entriesPerPeriod: Int,
        durations: [String: Int],
        releaseDates: ReleaseDateEngine.Snapshot,
        imageLookup: [String: String],
        lovedKeys: Set<String>,
        flaggedKeys: Set<String>
    ) -> [ChartTopperPeriod] {
        var aggregates: [BucketKey: Aggregate] = [:]

        for row in scrobbles {
            guard let releaseDate = resolvedReleaseDate(for: row, entity: entity, snapshot: releaseDates),
                  let date = ReleaseDateEngine.periodStart(of: releaseDate),
                  let periodStart = bucketStart(date, period: period) else { continue }

            let identity = identity(for: row, entity: entity)
            let key = BucketKey(periodStart: periodStart, entityKey: identity.key)
            let seconds = durations[DurationEngine.cacheKey(artist: row.artistName, track: row.trackName), default: 0]
            let representativeKey = TextNormalization.lovedKey(artist: row.artistName, track: row.trackName)
            if var value = aggregates[key] {
                value.count += 1
                value.seconds += seconds
                value.firstPlayedAt = min(value.firstPlayedAt, row.playedAt)
                if value.fallbackImageURL == nil { value.fallbackImageURL = row.imageURL }
                if var representative = value.representativeTracks[representativeKey] {
                    representative.count += 1
                    representative.seconds += seconds
                    representative.lastPlayedAt = max(representative.lastPlayedAt, row.playedAt)
                    if !row.albumName.isEmpty { representative.album = row.albumName }
                    value.representativeTracks[representativeKey] = representative
                } else {
                    value.representativeTracks[representativeKey] = RepresentativeTrack(
                        artist: row.artistName,
                        track: row.trackName,
                        album: row.albumName,
                        count: 1,
                        seconds: seconds,
                        lastPlayedAt: row.playedAt
                    )
                }
                aggregates[key] = value
            } else {
                aggregates[key] = Aggregate(
                    name: identity.name,
                    artist: row.artistName,
                    album: identity.album,
                    count: 1,
                    seconds: seconds,
                    firstPlayedAt: row.playedAt,
                    fallbackImageURL: row.imageURL,
                    representativeTracks: [
                        representativeKey: RepresentativeTrack(
                            artist: row.artistName,
                            track: row.trackName,
                            album: row.albumName,
                            count: 1,
                            seconds: seconds,
                            lastPlayedAt: row.playedAt
                        )
                    ]
                )
            }
        }

        let grouped = Dictionary(grouping: aggregates, by: { $0.key.periodStart })
        let periods = grouped.keys.sorted(by: >).map { start in
            let ranked = (grouped[start] ?? []).sorted { lhs, rhs in
                let left = metric == .scrobbles ? lhs.value.count : lhs.value.seconds
                let right = metric == .scrobbles ? rhs.value.count : rhs.value.seconds
                if left != right { return left > right }
                if lhs.value.firstPlayedAt != rhs.value.firstPlayedAt {
                    return lhs.value.firstPlayedAt < rhs.value.firstPlayedAt
                }
                let artistOrder = lhs.value.artist.localizedStandardCompare(rhs.value.artist)
                if artistOrder != .orderedSame { return artistOrder == .orderedAscending }
                return lhs.value.name.localizedStandardCompare(rhs.value.name) == .orderedAscending
            }
            let entries = ranked.prefix(entriesPerPeriod).enumerated().map { offset, rankedEntry in
                let aggregate = rankedEntry.value
                let trackKey = TextNormalization.lovedKey(artist: aggregate.artist, track: aggregate.name)
                let representative = aggregate.representativeTracks.values.sorted { lhs, rhs in
                    let left = metric == .scrobbles ? lhs.count : lhs.seconds
                    let right = metric == .scrobbles ? rhs.count : rhs.seconds
                    if left != right { return left > right }
                    if lhs.lastPlayedAt != rhs.lastPlayedAt { return lhs.lastPlayedAt > rhs.lastPlayedAt }
                    return lhs.track.localizedStandardCompare(rhs.track) == .orderedAscending
                }.first
                let target = ImageTarget(
                    kind: imageKind(for: entity),
                    artist: aggregate.artist,
                    album: aggregate.album,
                    track: entity == .track ? aggregate.name : nil
                )
                return ChartTopperEntry(
                    id: "\(start.timeIntervalSince1970)-\(rankedEntry.key.entityKey)",
                    rank: offset + 1,
                    name: aggregate.name,
                    artist: aggregate.artist,
                    album: aggregate.album,
                    metricValue: metric == .scrobbles ? aggregate.count : aggregate.seconds,
                    imageURL: ImageResolutionEngine.effectiveImageURL(
                        for: target,
                        lookup: imageLookup,
                        fallbackURL: aggregate.fallbackImageURL
                    ),
                    loved: entity == .track && lovedKeys.contains(trackKey),
                    flagged: entity == .track && flaggedKeys.contains(trackKey),
                    exportTrack: representative.map {
                        AppleMusicPlaylistTrack(artist: $0.artist, track: $0.track, album: $0.album)
                    }
                )
            }
            return ChartTopperPeriod(
                id: String(start.timeIntervalSince1970),
                label: label(for: start, period: period),
                start: start,
                entries: entries
            )
        }
        guard period == .year, yearRange > 0 else { return periods }
        return Array(periods.prefix(yearRange))
    }

    private nonisolated static func resolvedReleaseDate(
        for row: ScrobbleSnapshot,
        entity: TopChartsEntity,
        snapshot: ReleaseDateEngine.Snapshot
    ) -> String? {
        guard !row.albumName.isEmpty else { return nil }
        switch entity {
        case .track:
            return snapshot.trackResolution(
                artist: row.artistName,
                track: row.trackName,
                primaryAlbum: row.albumName
            ).date
        case .artist, .album:
            return snapshot.albumResolution(artist: row.artistName, album: row.albumName).date
        }
    }

    private nonisolated static func identity(
        for row: ScrobbleSnapshot,
        entity: TopChartsEntity
    ) -> (key: String, name: String, album: String?) {
        switch entity {
        case .artist:
            return (TextNormalization.artistIdentityKey(row.artistName), row.artistName, nil)
        case .album:
            return (
                TextNormalization.albumIdentityKey(artist: row.artistName, album: row.albumName),
                row.albumName,
                row.albumName
            )
        case .track:
            return (
                TextNormalization.lovedKey(artist: row.artistName, track: row.trackName),
                row.trackName,
                row.albumName.isEmpty ? nil : row.albumName
            )
        }
    }

    private nonisolated static func imageKind(for entity: TopChartsEntity) -> ImageTargetKind {
        switch entity {
        case .artist: .artist
        case .album: .album
        case .track: .track
        }
    }

    private nonisolated static func bucketStart(_ date: Date, period: CollagePeriod) -> Date? {
        let calendar = AppCalendars.releaseDates
        switch period {
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: date)?.start
        case .month:
            return calendar.dateInterval(of: .month, for: date)?.start
        case .year:
            return calendar.dateInterval(of: .year, for: date)?.start
        case .decade:
            let year = calendar.component(.year, from: date)
            return calendar.date(from: DateComponents(year: year - year % 10, month: 1, day: 1))
        }
    }

    private nonisolated static func label(for date: Date, period: CollagePeriod) -> String {
        let calendar = AppCalendars.releaseDates
        switch period {
        case .week:
            let week = calendar.component(.weekOfYear, from: date)
            let year = calendar.component(.yearForWeekOfYear, from: date)
            return "Week \(week), \(year)"
        case .month:
            let month = calendar.component(.month, from: date)
            let year = calendar.component(.year, from: date)
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = calendar.locale
            formatter.timeZone = calendar.timeZone
            return "\(formatter.shortMonthSymbols[month - 1]) \(year)"
        case .year:
            return String(calendar.component(.year, from: date))
        case .decade:
            let year = calendar.component(.year, from: date)
            return "\(year)s"
        }
    }
}
