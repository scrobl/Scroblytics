import Foundation
import SwiftData

enum MultiAlbumTrackMatchMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case exact
    case editionAware

    var id: Self { self }

    var label: String {
        switch self {
        case .exact: "Exact titles"
        case .editionAware: "Edition-aware"
        }
    }
}

enum MultiAlbumTracksSort: String, CaseIterable, Identifiable, Codable, Sendable {
    case mostPlayed
    case mostAlbums
    case recentlyPlayed
    case trackTitle

    var id: Self { self }

    var label: String {
        switch self {
        case .mostPlayed: "Most plays"
        case .mostAlbums: "Most albums"
        case .recentlyPlayed: "Most recently played"
        case .trackTitle: "Track title"
        }
    }
}

struct MultiAlbumTrackOccurrence: Identifiable, Hashable, Sendable {
    let id: String
    let album: String
    let trackTitle: String
    let titleVariants: [String]
    let playCount: Int
    let lastPlayed: Date
    let imageURL: String?
}

struct MultiAlbumTrackGroup: Identifiable, Hashable, Sendable {
    let id: String
    let artist: String
    let trackTitle: String
    let titleVariants: [String]
    let playCount: Int
    let lastPlayed: Date
    let albums: [MultiAlbumTrackOccurrence]
    let hasRelatedAlbumTitles: Bool
    let includesSingle: Bool
}

enum MultiAlbumTracksEngine {
    private struct AlbumAccumulator {
        var albumNames: [String: Int] = [:]
        var trackNames: [String: Int] = [:]
        var playCount = 0
        var lastPlayed = Date.distantPast
        var imageURL: String?
    }

    private struct GroupAccumulator {
        var artistNames: [String: Int] = [:]
        var trackNames: [String: Int] = [:]
        var albums: [String: AlbumAccumulator] = [:]
        var playCount = 0
        var lastPlayed = Date.distantPast
    }

    static func groups(
        scrobbles: [ScrobbleSnapshot],
        mode: MultiAlbumTrackMatchMode,
        imageLookup: [String: String]
    ) -> [MultiAlbumTrackGroup] {
        var accumulators: [String: GroupAccumulator] = [:]

        for scrobble in scrobbles {
            let artist = scrobble.artistName.trimmingCharacters(in: .whitespacesAndNewlines)
            let album = scrobble.albumName.trimmingCharacters(in: .whitespacesAndNewlines)
            let track = scrobble.trackName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !artist.isEmpty, !album.isEmpty, !track.isEmpty else { continue }

            let artistKey = TextNormalization.artistIdentityKey(artist)
            let titleKey = identityKey(track, mode: mode)
            guard !artistKey.isEmpty, !titleKey.isEmpty else { continue }

            let groupKey = artistKey + "\u{0}" + titleKey
            let albumKey = exactKey(album)
            var group = accumulators[groupKey, default: GroupAccumulator()]
            group.artistNames[artist, default: 0] += 1
            group.trackNames[track, default: 0] += 1
            group.playCount += 1
            group.lastPlayed = max(group.lastPlayed, scrobble.playedAt)

            var albumValue = group.albums[albumKey, default: AlbumAccumulator()]
            albumValue.albumNames[album, default: 0] += 1
            albumValue.trackNames[track, default: 0] += 1
            albumValue.playCount += 1
            if scrobble.playedAt >= albumValue.lastPlayed {
                albumValue.lastPlayed = scrobble.playedAt
                if let imageURL = scrobble.imageURL, !imageURL.isEmpty {
                    albumValue.imageURL = imageURL
                }
            }
            group.albums[albumKey] = albumValue
            accumulators[groupKey] = group
        }

        return accumulators.compactMap { key, accumulator in
            guard accumulator.albums.count > 1,
                  let artist = preferredName(accumulator.artistNames),
                  let trackTitle = preferredName(accumulator.trackNames) else { return nil }

            let occurrences = accumulator.albums.map { albumKey, value in
                let album = preferredName(value.albumNames) ?? albumKey
                let rawTrack = preferredName(value.trackNames) ?? trackTitle
                let target = ImageTarget(kind: .album, artist: artist, album: album, track: nil)
                return MultiAlbumTrackOccurrence(
                    id: key + "\u{0}" + albumKey,
                    album: album,
                    trackTitle: rawTrack,
                    titleVariants: sortedNames(value.trackNames),
                    playCount: value.playCount,
                    lastPlayed: value.lastPlayed,
                    imageURL: ImageResolutionEngine.effectiveImageURL(
                        for: target,
                        lookup: imageLookup,
                        fallbackURL: value.imageURL
                    )
                )
            }
            .sorted {
                if $0.playCount != $1.playCount { return $0.playCount > $1.playCount }
                return $0.album.localizedStandardCompare($1.album) == .orderedAscending
            }

            return MultiAlbumTrackGroup(
                id: key,
                artist: artist,
                trackTitle: trackTitle,
                titleVariants: sortedNames(accumulator.trackNames),
                playCount: accumulator.playCount,
                lastPlayed: accumulator.lastPlayed,
                albums: occurrences,
                hasRelatedAlbumTitles: hasRelatedAlbumTitles(occurrences.map(\.album)),
                includesSingle: occurrences.contains { containsSingle($0.album) }
            )
        }
    }

    static func filteredAndSorted(
        _ groups: [MultiAlbumTrackGroup],
        searchText: String = "",
        minimumAlbums: Int,
        relatedAlbumsOnly: Bool,
        includesSingleOnly: Bool,
        sort: MultiAlbumTracksSort
    ) -> [MultiAlbumTrackGroup] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return groups.filter { group in
            let matchesSearch = query.isEmpty
                || group.artist.localizedCaseInsensitiveContains(query)
                || group.trackTitle.localizedCaseInsensitiveContains(query)
                || group.titleVariants.contains { $0.localizedCaseInsensitiveContains(query) }
                || group.albums.contains { occurrence in
                    occurrence.album.localizedCaseInsensitiveContains(query)
                        || occurrence.titleVariants.contains { $0.localizedCaseInsensitiveContains(query) }
                }
            return matchesSearch
                && group.albums.count >= minimumAlbums
                && (!relatedAlbumsOnly || group.hasRelatedAlbumTitles)
                && (!includesSingleOnly || group.includesSingle)
        }
        .sorted { lhs, rhs in
            switch sort {
            case .mostPlayed:
                return lhs.playCount != rhs.playCount
                    ? lhs.playCount > rhs.playCount
                    : alphabetical(lhs, rhs)
            case .mostAlbums:
                return lhs.albums.count != rhs.albums.count
                    ? lhs.albums.count > rhs.albums.count
                    : lhs.playCount > rhs.playCount
            case .recentlyPlayed:
                return lhs.lastPlayed != rhs.lastPlayed
                    ? lhs.lastPlayed > rhs.lastPlayed
                    : alphabetical(lhs, rhs)
            case .trackTitle:
                return alphabetical(lhs, rhs)
            }
        }
    }

    static func identityKey(_ title: String, mode: MultiAlbumTrackMatchMode) -> String {
        let exact = exactKey(title)
        guard mode == .editionAware else { return exact }

        var value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var previous = ""
        while value != previous {
            previous = value
            value = strippingSafeBracketedSuffix(value)
            value = strippingSafeSeparatedSuffix(value)
        }

        return value.lowercased()
            .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func exactKey(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func strippingSafeBracketedSuffix(_ value: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: "^(.*?)[ \\t]*[(\\[]([^()\\[\\]]+)[)\\]]\\s*$"),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let headRange = Range(match.range(at: 1), in: value),
              let suffixRange = Range(match.range(at: 2), in: value),
              isSafeEditionSuffix(String(value[suffixRange])) else { return value }
        return String(value[headRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func strippingSafeSeparatedSuffix(_ value: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: "^(.*?)(?:\\s[-–—:]\\s*)([^-–—:]+)$"),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let headRange = Range(match.range(at: 1), in: value),
              let suffixRange = Range(match.range(at: 2), in: value),
              isSafeEditionSuffix(String(value[suffixRange])) else { return value }
        return String(value[headRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isSafeEditionSuffix(_ suffix: String) -> Bool {
        var remainder = suffix.lowercased()
        let patterns = [
            "\\b(?:19|20)\\d{2}\\b",
            "\\b\\d+(?:st|nd|rd|th)\\b",
            "\\b(?:remaster|remastered|re-master|re-mastered|mono|stereo|explicit|clean|anniversary|edition|version|original|album|single|digital|deluxe)\\b"
        ]
        for pattern in patterns {
            remainder = remainder.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        remainder = remainder.replacingOccurrences(of: "[\\s,&/+]+", with: " ", options: .regularExpression)
        return remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func preferredName(_ counts: [String: Int]) -> String? {
        counts.max {
            if $0.value != $1.value { return $0.value < $1.value }
            return $0.key.localizedStandardCompare($1.key) == .orderedDescending
        }?.key
    }

    private static func sortedNames(_ counts: [String: Int]) -> [String] {
        counts.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func alphabetical(_ lhs: MultiAlbumTrackGroup, _ rhs: MultiAlbumTrackGroup) -> Bool {
        let titleOrder = lhs.trackTitle.localizedStandardCompare(rhs.trackTitle)
        if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
        return lhs.artist.localizedStandardCompare(rhs.artist) == .orderedAscending
    }

    private static func containsSingle(_ album: String) -> Bool {
        album.range(of: "\\bsingle\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func hasRelatedAlbumTitles(_ albums: [String]) -> Bool {
        for firstIndex in albums.indices {
            for secondIndex in albums.indices where secondIndex > firstIndex {
                let first = TextNormalization.normalizeAlbumName(albums[firstIndex])
                let second = TextNormalization.normalizeAlbumName(albums[secondIndex])
                if !first.isEmpty, first == second { return true }
            }
        }
        return false
    }
}

@ModelActor
actor MultiAlbumTracksReader {
    func load(mode: MultiAlbumTrackMatchMode) throws -> [MultiAlbumTrackGroup] {
        let scrobbles = try modelContext.fetch(FetchDescriptor<Scrobble>()).map(\.snapshot)
        let lookup = try ImageResolutionEngine.imageLookup(context: modelContext)
        return MultiAlbumTracksEngine.groups(scrobbles: scrobbles, mode: mode, imageLookup: lookup)
    }
}
