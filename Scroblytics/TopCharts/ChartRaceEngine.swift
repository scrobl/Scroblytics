import Foundation
import SwiftData

struct ChartRaceEntity: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let artist: String?
    let album: String?
    let imageURL: String?
}

struct ChartRaceFrame: Sendable {
    let date: Date
    let values: [String: Int]
}

struct ChartRaceTimeline: Sendable {
    let entities: [String: ChartRaceEntity]
    let frames: [ChartRaceFrame]
    let maximumValue: Int

    func rows(at progress: Double, limit: Int) -> [ChartRaceRow] {
        guard !frames.isEmpty else { return [] }
        let clamped = min(max(progress, 0), 1)
        let position = clamped * Double(frames.count - 1)
        let lowerIndex = Int(position.rounded(.down))
        let upperIndex = min(lowerIndex + 1, frames.count - 1)
        let fraction = position - Double(lowerIndex)
        let lower = frames[lowerIndex]
        let upper = frames[upperIndex]

        return entities.values.map { entity in
            let start = Double(lower.values[entity.id, default: 0])
            let end = Double(upper.values[entity.id, default: 0])
            return ChartRaceRow(entity: entity, value: start + ((end - start) * fraction))
        }
        .filter { $0.value > 0.001 }
        .sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            if $0.entity.artist != $1.entity.artist {
                return ($0.entity.artist ?? "") < ($1.entity.artist ?? "")
            }
            return $0.entity.name < $1.entity.name
        }
        .prefix(limit)
        .map { $0 }
    }

    func date(at progress: Double) -> Date {
        guard let first = frames.first, let last = frames.last else { return Date() }
        return first.date.addingTimeInterval(last.date.timeIntervalSince(first.date) * min(max(progress, 0), 1))
    }
}

struct ChartRaceRow: Identifiable, Equatable {
    let entity: ChartRaceEntity
    let value: Double
    var id: String { entity.id }
}

@ModelActor
private actor ChartRaceDataReader {
    func fetch(range: DateRange) throws -> [ScrobbleSnapshot] {
        let from = range.from
        let to = range.to
        let descriptor = FetchDescriptor<Scrobble>(
            predicate: #Predicate<Scrobble> { $0.playedAt >= from && $0.playedAt <= to },
            sortBy: [SortDescriptor(\.playedAt)]
        )
        return try modelContext.fetch(descriptor).map(\.snapshot)
    }
}

enum ChartRaceEngine {
    private static let checkpointCount = 160
    private static let candidateLimit = 50
    @MainActor private static var cache: [CacheKey: (timeline: ChartRaceTimeline, loadedAt: Date)] = [:]

    private struct CacheKey: Hashable {
        let entity: String
        let metric: String
        let from: Date
        let to: Date
    }

    @MainActor
    static func invalidateCache() {
        cache.removeAll()
    }

    @MainActor
    static func fetchTimeline(
        container: ModelContainer,
        context: ModelContext,
        entity: TopChartsEntity,
        range: DateRange,
        metric: TopChartsMetric
    ) async throws -> ChartRaceTimeline {
        let cacheKey = CacheKey(entity: entity.rawValue, metric: metric.rawValue, from: range.from, to: range.to)
        if let cached = cache[cacheKey], Date().timeIntervalSince(cached.loadedAt) < 5 * 60 {
            return cached.timeline
        }
        let scrobbles = try await offMain {
            try await ChartRaceDataReader(modelContainer: container).fetch(range: range)
        }
        let durationSnapshot = metric == .timeListened ? DurationEngine.loadSnapshot(context: context) : nil
        let durationPairs: [(String, Int)] = Set(scrobbles.map {
            DurationEngine.cacheKey(artist: $0.artistName, track: $0.trackName)
        }).compactMap { key in
            guard let durationSnapshot else { return nil }
            if case .seconds(let seconds) = durationSnapshot.resolution(forKey: key) {
                return (key, seconds)
            }
            return nil
        }
        let durationLookup = Dictionary(uniqueKeysWithValues: durationPairs)
        let imageLookup = try ImageResolutionEngine.imageLookup(context: context)

        let timeline = await Task.detached(priority: .userInitiated) {
            build(
                scrobbles: scrobbles,
                entity: entity,
                range: range,
                metric: metric,
                durationLookup: durationLookup,
                imageLookup: imageLookup
            )
        }.value
        cache[cacheKey] = (timeline, Date())
        return timeline
    }

    private static func build(
        scrobbles: [ScrobbleSnapshot],
        entity: TopChartsEntity,
        range: DateRange,
        metric: TopChartsMetric,
        durationLookup: [String: Int],
        imageLookup: [String: String]
    ) -> ChartRaceTimeline {
        guard !scrobbles.isEmpty else {
            return ChartRaceTimeline(entities: [:], frames: [], maximumValue: 1)
        }

        let canonicalArtists = TextNormalization.canonicalArtistNames(scrobbles.map(\.artistName))
        let albumMerges = entity == .album
            ? TextNormalization.detectAlbumMerges(scrobbles.compactMap {
                $0.albumName.isEmpty ? nil : (
                    canonicalArtists[TextNormalization.artistIdentityKey($0.artistName)] ?? $0.artistName,
                    $0.albumName
                )
            })
            : nil

        struct Event {
            let date: Date
            let key: String
            let value: Int
            let snapshot: ScrobbleSnapshot
            let canonicalArtist: String
        }

        func key(for snapshot: ScrobbleSnapshot, canonicalArtist: String) -> String? {
            switch entity {
            case .artist:
                return canonicalArtist
            case .album:
                guard !snapshot.albumName.isEmpty else { return nil }
                let normalized = TextNormalization.normalizeAlbumName(snapshot.albumName)
                switch albumMerges?[normalized] {
                case .compilation: return "\u{0}VA\u{0}\(normalized)"
                case .primaryArtist: return "\u{0}PA\u{0}\(normalized)"
                case nil: return "\(canonicalArtist)\u{0}\(snapshot.albumName)"
                }
            case .track:
                return "\(canonicalArtist)\u{0}\(snapshot.trackName)"
            }
        }

        let events = scrobbles.compactMap { snapshot -> Event? in
            let artist = canonicalArtists[TextNormalization.artistIdentityKey(snapshot.artistName)]
                ?? snapshot.artistName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let key = key(for: snapshot, canonicalArtist: artist) else { return nil }
            let value = metric == .scrobbles
                ? 1
                : durationLookup[DurationEngine.cacheKey(artist: snapshot.artistName, track: snapshot.trackName), default: 0]
            return Event(date: snapshot.playedAt, key: key, value: value, snapshot: snapshot, canonicalArtist: artist)
        }

        guard !events.isEmpty else {
            return ChartRaceTimeline(entities: [:], frames: [], maximumValue: 1)
        }

        let duration = max(0, range.to.timeIntervalSince(range.from))
        let boundaries = (0..<checkpointCount).map { index in
            range.from.addingTimeInterval(duration * Double(index) / Double(checkpointCount - 1))
        }

        var samples: [String: Event] = [:]
        var counts: [String: Int] = [:]
        var candidateKeys = Set<String>()
        var cursor = 0

        for boundary in boundaries {
            while cursor < events.count, events[cursor].date <= boundary {
                let event = events[cursor]
                counts[event.key, default: 0] += event.value
                if samples[event.key] == nil { samples[event.key] = event }
                cursor += 1
            }
            candidateKeys.formUnion(
                counts.sorted { lhs, rhs in
                    if lhs.value != rhs.value { return lhs.value > rhs.value }
                    return lhs.key < rhs.key
                }
                .prefix(candidateLimit)
                .map(\.key)
            )
        }

        var entities: [String: ChartRaceEntity] = [:]
        for key in candidateKeys {
            guard let event = samples[key] else { continue }
            let name: String
            let artist: String?
            let album: String?
            switch entity {
            case .artist:
                name = event.canonicalArtist
                artist = nil
                album = nil
            case .album:
                name = event.snapshot.albumName
                let normalized = TextNormalization.normalizeAlbumName(name)
                switch albumMerges?[normalized] {
                case .compilation: artist = TextNormalization.variousArtistsLabel
                case .primaryArtist(let primary): artist = primary
                case nil: artist = event.canonicalArtist
                }
                album = nil
            case .track:
                name = event.snapshot.trackName
                artist = event.canonicalArtist
                album = event.snapshot.albumName.isEmpty ? nil : event.snapshot.albumName
            }
            let target = ImageTarget(
                kind: entity == .artist ? .artist : (entity == .album ? .album : .track),
                artist: event.canonicalArtist,
                album: entity == .album ? name : album,
                track: entity == .track ? name : nil
            )
            entities[key] = ChartRaceEntity(
                id: key,
                name: name,
                artist: artist,
                album: album,
                imageURL: ImageResolutionEngine.effectiveImageURL(
                    for: target,
                    lookup: imageLookup,
                    fallbackURL: event.snapshot.imageURL
                )
            )
        }

        counts.removeAll(keepingCapacity: true)
        cursor = 0
        var frames: [ChartRaceFrame] = []
        for boundary in boundaries {
            while cursor < events.count, events[cursor].date <= boundary {
                let event = events[cursor]
                if candidateKeys.contains(event.key) {
                    counts[event.key, default: 0] += event.value
                }
                cursor += 1
            }
            frames.append(ChartRaceFrame(date: boundary, values: counts))
        }

        let maximumValue = max(1, frames.last?.values.values.max() ?? 1)
        return ChartRaceTimeline(entities: entities, frames: frames, maximumValue: maximumValue)
    }
}
