import Foundation
import SwiftData

struct MissingImageEntry: Identifiable, Sendable {
    let id: String
    let target: ImageTarget
    let reason: String
}

enum MissingImagesEngine {
    @MainActor
    static func findMissingImages(context: ModelContext) throws -> [MissingImageEntry] {
        let lookup = try ImageResolutionEngine.imageLookup(context: context)
        var missing: [MissingImageEntry] = []

        for artist in try context.fetch(FetchDescriptor<Artist>(sortBy: [SortDescriptor(\.normalizedName)])) {
            let target = ImageTarget(kind: .artist, artist: artist.name, album: nil, track: nil)
            if ImageResolutionEngine.effectiveImageURL(for: target, lookup: lookup) == nil {
                missing.append(MissingImageEntry(
                    id: ImageResolutionEngine.lookupKey(for: target),
                    target: target,
                    reason: "Missing artist image"
                ))
            }
        }

        for album in try context.fetch(FetchDescriptor<Album>(sortBy: [SortDescriptor(\.identityKey)])) {
            guard let artist = album.artist?.name else { continue }
            let target = ImageTarget(kind: .album, artist: artist, album: album.title, track: nil)
            if ImageResolutionEngine.effectiveImageURL(for: target, lookup: lookup) == nil {
                missing.append(MissingImageEntry(
                    id: ImageResolutionEngine.lookupKey(for: target),
                    target: target,
                    reason: "Missing album image"
                ))
            }
        }

        let scrobbles = try context.fetch(FetchDescriptor<Scrobble>())
        var trackAlbums: [String: (artist: String, track: String, albumCounts: [String: Int])] = [:]
        for scrobble in scrobbles {
            let key = TextNormalization.lovedKey(artist: scrobble.artistName, track: scrobble.trackName)
            var entry = trackAlbums[key] ?? (scrobble.artistName, scrobble.trackName, [:])
            if !scrobble.albumName.isEmpty {
                entry.albumCounts[scrobble.albumName, default: 0] += 1
            }
            trackAlbums[key] = entry
        }

        for (key, entry) in trackAlbums {
            let album = entry.albumCounts.max { lhs, rhs in lhs.value < rhs.value }?.key
            let target = ImageTarget(kind: .track, artist: entry.artist, album: album, track: entry.track)
            if ImageResolutionEngine.effectiveImageURL(for: target, lookup: lookup) == nil {
                missing.append(MissingImageEntry(
                    id: "track_\(key)",
                    target: target,
                    reason: "Missing track image"
                ))
            }
        }

        return missing
    }
}
