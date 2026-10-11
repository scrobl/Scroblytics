import Foundation

/// Result of `AlbumScopeWarningEngine.check` — whether adding a tag to this
/// (artist, track) would silently also apply to another locally-scrobbled
/// album, and (best-effort) whether that other album looks like a genuinely
/// different recording rather than just a reissue.
struct AlbumScopeWarning: Sendable {
    struct OtherAlbum: Sendable, Hashable { let name: String; let plays: Int }
    struct Sharpen: Sendable { let otherAlbum: String; let thisSeconds: Int; let otherSeconds: Int }

    let hasWarning: Bool
    let otherAlbums: [OtherAlbum]
    let sharpen: Sharpen?

    static let none = AlbumScopeWarning(hasWarning: false, otherAlbums: [], sharpen: nil)
}

/// Same-track-name-across-albums detection, and the blocking-confirmation
/// check built on top of it for the single-track tags "+ Add" flow. Per
/// tags-feature-prompt.md: `track.addTags`/`removeTag` are scoped to
/// artist+track only, no album parameter, so a tag applied to a track
/// applies to that (artist, track) identity everywhere it appears — this is
/// a property of Last.fm's write call itself, not fixable here, so the app's
/// only recourse is warning the user before the write happens.
///
/// The ONE detector for this concept (`computeCrossAlbumGroups`), plus
/// `checkAlbumScopeWarning`, used by Tag Writing.
enum AlbumScopeWarningEngine {
    /// Meaningfully different recordings (e.g. a live cut vs. the studio
    /// version) tend to differ by much more than typical remaster/reissue
    /// runtime jitter.
    static let sharpenThresholdSeconds = 30

    struct CrossAlbumGroup {
        let artist: String
        let track: String
        let albums: [(name: String, plays: Int)]
    }

    /// Groups ALL scrobbles by (artist, track), then by exact album name
    /// (blank albums excluded), keeping only groups spanning 2+ distinct
    /// albums — sorted by play count descending, tied albums alphabetically.
    static func crossAlbumGroups(scrobbles: [ScrobbleSnapshot]) -> [CrossAlbumGroup] {
        var trackGroups: [String: [ScrobbleSnapshot]] = [:]
        var trackOrder: [String] = []
        for s in scrobbles {
            let key = TextNormalization.lovedKey(artist: s.artistName, track: s.trackName)
            if trackGroups[key] == nil { trackOrder.append(key) }
            trackGroups[key, default: []].append(s)
        }

        var result: [CrossAlbumGroup] = []
        for key in trackOrder {
            let trs = trackGroups[key]!
            var albumCounts: [String: Int] = [:]
            var albumOrder: [String] = []
            for s in trs where !s.albumName.isEmpty {
                if albumCounts[s.albumName] == nil { albumOrder.append(s.albumName) }
                albumCounts[s.albumName, default: 0] += 1
            }
            guard albumOrder.count >= 2 else { continue }
            let albums = albumOrder
                .map { (name: $0, plays: albumCounts[$0]!) }
                .sorted { $0.plays != $1.plays ? $0.plays > $1.plays : $0.name < $1.name }
            result.append(CrossAlbumGroup(artist: trs[0].artistName, track: trs[0].trackName, albums: albums))
        }
        return result
    }

    /// Best-effort: a duration lookup failure (network, no Deezer match)
    /// simply means no sharpening detail — the base warning still stands.
    static func check(
        scrobbles: [ScrobbleSnapshot], client: DeezerAPIClient, artist: String, track: String, album: String?
    ) async -> AlbumScopeWarning {
        let groups = crossAlbumGroups(scrobbles: scrobbles)
        let norm = TextNormalization.lovedKey(artist: artist, track: track)
        guard let group = groups.first(where: { TextNormalization.lovedKey(artist: $0.artist, track: $0.track) == norm }) else {
            return .none
        }
        let currentAlbumNormalized = (album ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let otherAlbums = group.albums.filter { $0.name.trimmingCharacters(in: .whitespaces).lowercased() != currentAlbumNormalized }
        guard !otherAlbums.isEmpty else { return .none }

        var sharpen: AlbumScopeWarning.Sharpen?
        if let album, let firstOther = otherAlbums.first {
            let thisResult = try? await client.fetchTrackDuration(artist: artist, track: track, album: album)
            let otherResult = try? await client.fetchTrackDuration(artist: artist, track: track, album: firstOther.name)
            if let thisSeconds = thisResult ?? nil, let otherSeconds = otherResult ?? nil,
               abs(thisSeconds - otherSeconds) >= sharpenThresholdSeconds {
                sharpen = AlbumScopeWarning.Sharpen(otherAlbum: firstOther.name, thisSeconds: thisSeconds, otherSeconds: otherSeconds)
            }
        }
        return AlbumScopeWarning(
            hasWarning: true,
            otherAlbums: otherAlbums.map { AlbumScopeWarning.OtherAlbum(name: $0.name, plays: $0.plays) },
            sharpen: sharpen
        )
    }
}
