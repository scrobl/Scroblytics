import Foundation
import SwiftData

/// A read-only copy of what the app knows about artwork, built on the main actor from the same
/// sources the tables and detail pages use (`ImageResolutionEngine.imageLookup`) so the fields
/// answer exactly what a row would show.
struct ImageStatusSnapshot: Sendable {
    /// Lookup key → image URL for every image the app has on disk (custom first, then detected).
    var lookup: [String: String] = [:]
    /// Lookup keys of the entities whose image the USER set by hand (a custom filename is stored).
    var customKeys: Set<String> = []

    static let empty = ImageStatusSnapshot()

    static func load(context: ModelContext) -> ImageStatusSnapshot {
        var snapshot = ImageStatusSnapshot()
        snapshot.lookup = (try? ImageResolutionEngine.imageLookup(context: context)) ?? [:]
        for artist in (try? context.fetch(FetchDescriptor<Artist>())) ?? [] where artist.customImageFilename != nil {
            snapshot.customKeys.insert(ImageResolutionEngine.lookupKey(for: ImageTarget(kind: .artist, artist: artist.name, album: nil, track: nil)))
        }
        for album in (try? context.fetch(FetchDescriptor<Album>())) ?? [] where album.customImageFilename != nil {
            guard let artistName = album.artist?.name else { continue }
            snapshot.customKeys.insert(ImageResolutionEngine.lookupKey(for: ImageTarget(kind: .album, artist: artistName, album: album.title, track: nil)))
        }
        for imageOverride in (try? context.fetch(FetchDescriptor<AlbumImageOverride>())) ?? [] {
            snapshot.customKeys.insert(ImageResolutionEngine.customAlbumLookupKey(artist: imageOverride.artist, album: imageOverride.album))
        }
        for track in (try? context.fetch(FetchDescriptor<Track>())) ?? [] where track.customImageFilename != nil {
            guard let artistName = track.artist?.name else { continue }
            snapshot.customKeys.insert(ImageResolutionEngine.lookupKey(for: ImageTarget(kind: .track, artist: artistName, album: nil, track: track.title)))
        }
        return snapshot
    }
}

/// Artwork status, for finding what still needs a picture and what has been hand-picked.
/// "Missing" is the table's own test: no image resolves through `effectiveImageURL` (custom, detected,
/// the album's art for a track, or the scrobble's own non-placeholder art).
extension QueryFieldRegistry {
    private static func imageTarget(_ entity: QueryEntity, albumOfTrack: String?) -> ImageTarget {
        switch entity.target {
        case .artist: ImageTarget(kind: .artist, artist: entity.artist, album: nil, track: nil)
        case .album: ImageTarget(kind: .album, artist: entity.artist, album: entity.name, track: nil)
        case .track, .scrobble: ImageTarget(kind: .track, artist: entity.artist, album: albumOfTrack, track: entity.name)
        }
    }

    static let imageFields: [QueryField] = {
        let all: Set<QueryTarget> = [.artist, .album, .track]
        return [
            QueryField(
                id: "missingImage", name: "Missing image", group: .flags, type: .boolean, targets: all,
                column: QueryColumnSpec(alignment: .center, style: .boolean, width: 110),
                help: "True when no artwork shows for it: no custom or downloaded image, nothing inherited from its album, and no usable art on its scrobbles. As of the last time artwork was refreshed."
            ) { run, _, entities in
                let images = run.snapshots.images
                let aggregates = run.universe.aggregates
                return Dictionary(uniqueKeysWithValues: entities.map { entity in
                    let aggregate = aggregates[entity.id]
                    let target = imageTarget(entity, albumOfTrack: aggregate?.album)
                    let url = ImageResolutionEngine.effectiveImageURL(for: target, lookup: images.lookup, fallbackURL: aggregate?.imageURL)
                    return (entity.id, .value(.bool(url == nil)))
                })
            },
            QueryField(
                id: "customImage", name: "Image set manually", group: .flags, type: .boolean, targets: all,
                column: QueryColumnSpec(alignment: .center, style: .boolean, width: 130),
                help: "True when you chose its artwork yourself (an image you uploaded or picked). An image it merely shows because its album has one doesn’t count."
            ) { run, _, entities in
                let images = run.snapshots.images
                return Dictionary(uniqueKeysWithValues: entities.map { entity in
                    let target = imageTarget(entity, albumOfTrack: nil)
                    var custom = images.customKeys.contains(ImageResolutionEngine.lookupKey(for: target))
                    if entity.target == .album, !custom {
                        custom = images.customKeys.contains(ImageResolutionEngine.customAlbumLookupKey(artist: entity.artist, album: entity.name))
                    }
                    return (entity.id, .value(.bool(custom)))
                })
            },
        ]
    }()
}
