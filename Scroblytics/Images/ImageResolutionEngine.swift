import Foundation
import SwiftData

enum ImageResolutionError: LocalizedError {
    case invalidHTTPResponse
    case httpStatus(Int)
    case missingAlbumArtist(String)
    case noImageFound
    case trackAlbumNotFound

    var errorDescription: String? {
        switch self {
        case .invalidHTTPResponse:
            "The image server returned an invalid response."
        case .httpStatus(let status):
            "The image server returned HTTP \(status)."
        case .missingAlbumArtist(let album):
            "Cannot resolve “\(album)” because its artist relationship is missing."
        case .noImageFound:
            "No replacement artwork was found on Deezer or in the synced Last.fm history."
        case .trackAlbumNotFound:
            "This track has no album in the synced listening history, so there is no album artwork to refresh."
        }
    }
}

@ModelActor
private actor BackgroundImageResolutionWorker {
    private let batchSize = 25

    /// `onProgress(remaining, failed)` fires at the top of every batch, and with
    /// `remaining == 0` once nothing is left to try. Failed rows stay unresolved
    /// in the store (retried next launch), so they're subtracted from `remaining`.
    func resolveAll(onProgress: (@Sendable (_ remaining: Int, _ failed: Int) -> Void)? = nil) async throws -> Bool {
        let deezer = DeezerAPIClient()
        var failedArtistIDs = Set<PersistentIdentifier>()
        var failedAlbumIDs = Set<PersistentIdentifier>()
        var imagesChanged = false

        // Older rows may already record a genuine Deezer miss. Give those
        // albums one local-cache promotion pass using their Last.fm artwork.
        // What it reads only changes when a sync lands, so it runs once per
        // sync rather than on every launch (it re-scanned ~115 albums' scrobbles
        // at each launch for the same answer).
        let syncedAt = try modelContext.fetch(FetchDescriptor<SyncState>()).first?.lastSyncedAt
        let fallbackPassKey = "artwork.fallbackPassForSyncAt"
        if !ConnectivityGate.isOffline, syncedAt == nil || UserDefaults.standard.object(forKey: fallbackPassKey) as? Date != syncedAt {
            if try await cacheFallbacksForResolvedAlbumMisses() {
                imagesChanged = true
            }
            if let syncedAt { UserDefaults.standard.set(syncedAt, forKey: fallbackPassKey) }
        }

        while !Task.isCancelled {
            var artistDescriptor = FetchDescriptor<Artist>(
                predicate: #Predicate { $0.imageResolvedAt == nil },
                sortBy: [SortDescriptor(\.normalizedName)]
            )
            artistDescriptor.fetchLimit = batchSize + failedArtistIDs.count
            var albumDescriptor = FetchDescriptor<Album>(
                predicate: #Predicate { $0.imageResolvedAt == nil },
                sortBy: [SortDescriptor(\.identityKey)]
            )
            albumDescriptor.fetchLimit = batchSize + failedAlbumIDs.count

            let unresolvedArtists = try modelContext.fetchCount(FetchDescriptor<Artist>(predicate: #Predicate { $0.imageResolvedAt == nil }))
            let unresolvedAlbums = try modelContext.fetchCount(FetchDescriptor<Album>(predicate: #Predicate { $0.imageResolvedAt == nil }))
            onProgress?(
                max(0, unresolvedArtists - failedArtistIDs.count) + max(0, unresolvedAlbums - failedAlbumIDs.count),
                failedArtistIDs.count + failedAlbumIDs.count
            )

            let artists = try modelContext.fetch(artistDescriptor)
                .filter { !failedArtistIDs.contains($0.persistentModelID) }
                .prefix(batchSize)
            let albums = try modelContext.fetch(albumDescriptor)
                .filter { !failedAlbumIDs.contains($0.persistentModelID) }
                .prefix(batchSize)
            if artists.isEmpty && albums.isEmpty { return imagesChanged }

            for artist in artists {
                try Task.checkCancellation()
                // Offline mode: stop the run quietly. Nothing is marked resolved or failed; the next run picks it up.
                if ConnectivityGate.isOffline { throw CancellationError() }
                let target = ImageTarget(kind: .artist, artist: artist.name, album: nil, track: nil)
                do {
                    let sourceURL = try await deezer.fetchArtistImageURL(artist: artist.name)
                    if try await storeResolvedImage(from: sourceURL, target: target, artist: artist, album: nil) {
                        imagesChanged = true
                    }
                } catch is OfflineError {
                    throw CancellationError()
                } catch {
                    // Keep the row unresolved for a later launch, but don't let
                    // one API or download failure stop every remaining image.
                    failedArtistIDs.insert(artist.persistentModelID)
                }
                try await Task.sleep(for: .milliseconds(200))
            }
            if modelContext.hasChanges { try modelContext.save() }

            for album in albums {
                try Task.checkCancellation()
                if ConnectivityGate.isOffline { throw CancellationError() }
                guard let artistName = album.artist?.name, !artistName.isEmpty else {
                    album.imageResolvedAt = Date()
                    continue
                }
                let target = ImageTarget(kind: .album, artist: artistName, album: album.title, track: nil)
                do {
                    // A lookup that failed to CONNECT must not look like "Deezer has no picture": that would record the
                    // album as resolved-with-no-artwork for good. Only a real answer (including "none") counts.
                    let deezerURL: URL?
                    do {
                        deezerURL = try await deezer.fetchAlbumImageURL(artist: artistName, album: album.title)
                    } catch is OfflineError {
                        throw CancellationError()
                    } catch DeezerAPIError.network {
                        failedAlbumIDs.insert(album.persistentModelID)
                        try await Task.sleep(for: .milliseconds(200))
                        continue
                    } catch {
                        deezerURL = nil
                    }
                    let fallbackURL = try lastfmFallbackURL(artist: artistName, album: album.title)
                    if try await storeResolvedImage(
                        from: deezerURL ?? fallbackURL,
                        fallbackURL: deezerURL == nil ? nil : fallbackURL,
                        target: target,
                        artist: nil,
                        album: album
                    ) {
                        imagesChanged = true
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failedAlbumIDs.insert(album.persistentModelID)
                }
                try await Task.sleep(for: .milliseconds(200))
            }
            if modelContext.hasChanges { try modelContext.save() }
        }
        return imagesChanged
    }

    private func cacheFallbacksForResolvedAlbumMisses() async throws -> Bool {
        var imagesChanged = false
        let descriptor = FetchDescriptor<Album>(
            predicate: #Predicate { $0.imageResolvedAt != nil && $0.detectedImageFilename == nil },
            sortBy: [SortDescriptor(\.identityKey)]
        )
        for album in try modelContext.fetch(descriptor) {
            try Task.checkCancellation()
            guard let artistName = album.artist?.name,
                  let sourceURL = try lastfmFallbackURL(artist: artistName, album: album.title) else { continue }
            let target = ImageTarget(kind: .album, artist: artistName, album: album.title, track: nil)
            do {
                if try await storeResolvedImage(from: sourceURL, target: target, artist: nil, album: album) {
                    imagesChanged = true
                }
            } catch {
                continue
            }
        }
        if modelContext.hasChanges { try modelContext.save() }
        return imagesChanged
    }

    /// The newest real Last.fm picture of each album, by artist and album as the scrobbles spell them. Built on first use from one
    /// pass over the scrobbles (newest first) and kept for this run. The lookup used to be a query per album, and with a
    /// 370,000-scrobble history those queries kept the app busy for hours after an import.
    private var lastfmArtworkIndex: [String: URL]?
    /// What the scrobbles looked like when the index was built, and when it was last checked against them. A sync can land while
    /// this run is still going (it can last an hour); the index is rebuilt then, so a new album's picture isn't missed.
    private var indexedScrobbleCount = 0
    private var indexedSyncAt: Date?
    private var indexCheckedAt = Date.distantPast
    private static let indexRecheckInterval: TimeInterval = 30

    private func artworkIndex() throws -> [String: URL] {
        let now = Date()
        if let index = lastfmArtworkIndex {
            if now.timeIntervalSince(indexCheckedAt) < Self.indexRecheckInterval { return index }
            indexCheckedAt = now
            let count = try modelContext.checkedCount(FetchDescriptor<Scrobble>())
            let syncAt = try modelContext.fetch(FetchDescriptor<SyncState>()).first?.lastSyncedAt
            if count == indexedScrobbleCount, syncAt == indexedSyncAt { return index }
        }
        let built = try LastfmArtworkIndex.build(context: modelContext)
        lastfmArtworkIndex = built.index
        indexedScrobbleCount = built.scrobbles
        indexedSyncAt = try modelContext.fetch(FetchDescriptor<SyncState>()).first?.lastSyncedAt
        indexCheckedAt = now
        return built.index
    }

    private func lastfmFallbackURL(artist: String, album: String) throws -> URL? {
        try artworkIndex()[LastfmArtworkIndex.key(artist: artist, album: album)]
    }

    private func storeResolvedImage(
        from sourceURL: URL?,
        fallbackURL: URL? = nil,
        target: ImageTarget,
        artist: Artist?,
        album: Album?
    ) async throws -> Bool {
        let data: Data?
        if let sourceURL {
            do {
                data = try await downloadImage(from: sourceURL)
            } catch {
                guard let fallbackURL, fallbackURL != sourceURL else { throw error }
                data = try await downloadImage(from: fallbackURL)
            }
        } else {
            data = nil
        }
        let filename = try await ImageStore.writeDetectedImage(
            data: data,
            prefix: "detected-\(ImageStore.safeKey(for: target))"
        )

        let previousFilename = artist?.detectedImageFilename ?? album?.detectedImageFilename
        if let previousFilename {
            try? FileManager.default.removeItem(
                at: ImageStore.cachedImagesDirectory().appendingPathComponent(previousFilename)
            )
        }
        artist?.detectedImageFilename = filename
        artist?.imageResolvedAt = Date()
        album?.detectedImageFilename = filename
        album?.imageResolvedAt = Date()
        return filename != previousFilename
    }

    private func downloadImage(from url: URL) async throws -> Data {
        try ConnectivityGate.check(host: url.host)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(from: url)
            ConnectivityHub.reportSuccess()
        } catch {
            ConnectivityHub.report(error, host: url.host, source: "Artwork")
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            throw ImageResolutionError.invalidHTTPResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ImageResolutionError.httpStatus(http.statusCode)
        }
        return data
    }
}

/// The newest real Last.fm picture of every album, from one pass over the scrobbles (newest first). Looking an album's picture up
/// by querying the scrobbles once per album walks the table each time; with a 370,000-scrobble history that was the app's biggest
/// background cost.
enum LastfmArtworkIndex {
    static func key(artist: String, album: String) -> String { artist + "\u{1F}" + album }

    static func build(context: ModelContext) throws -> (index: [String: URL], scrobbles: Int) {
        var index: [String: URL] = [:]
        var descriptor = FetchDescriptor<Scrobble>(sortBy: [SortDescriptor(\.playedAt, order: .reverse)])
        descriptor.propertiesToFetch = [\.artistName, \.albumName, \.imageURL]
        var seen = 0
        try context.enumerate(descriptor, batchSize: 5_000) { scrobble in
            try Task.checkCancellation()
            seen += 1
            guard let raw = scrobble.imageURL, !TextNormalization.isLastfmPlaceholderImage(raw), let url = URL(string: raw) else { return }
            let key = key(artist: scrobble.artistName, album: scrobble.albumName)
            if index[key] == nil { index[key] = url }
        }
        return (index, seen)
    }
}

enum ImageResolutionEngine {
    @MainActor private(set) static var isBulkResolving = false

    static func customAlbumLookupKey(artist: String, album: String) -> String {
        "album_override_\(TextNormalization.albumArtworkIdentityKey(artist: artist, album: album))"
    }

    static func lookupKey(for target: ImageTarget) -> String {
        switch target.kind {
        case .artist:
            "artist_\(target.artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
        case .album:
            "album_\(TextNormalization.albumIdentityKey(artist: target.artist, album: target.album ?? ""))"
        case .track:
            "track_\(TextNormalization.lovedKey(artist: target.artist, track: target.track ?? ""))"
        }
    }

    static func imageLookup(context: ModelContext) throws -> [String: String] {
        var lookup: [String: String] = [:]

        for artist in try context.fetch(FetchDescriptor<Artist>()) {
            let target = ImageTarget(kind: .artist, artist: artist.name, album: nil, track: nil)
            if let url = customURL(filename: artist.customImageFilename)
                ?? detectedURL(filename: artist.detectedImageFilename) {
                lookup[lookupKey(for: target)] = url.absoluteString
            }
        }

        for album in try context.fetch(FetchDescriptor<Album>()) {
            guard let artistName = album.artist?.name else { continue }
            let target = ImageTarget(kind: .album, artist: artistName, album: album.title, track: nil)
            if let url = customURL(filename: album.customImageFilename)
                ?? detectedURL(filename: album.detectedImageFilename) {
                lookup[lookupKey(for: target)] = url.absoluteString
            }
        }

        for imageOverride in try context.fetch(FetchDescriptor<AlbumImageOverride>()) {
            if let url = customURL(filename: imageOverride.filename) {
                lookup[customAlbumLookupKey(
                    artist: imageOverride.artist,
                    album: imageOverride.album
                )] = url.absoluteString
            }
        }

        for track in try context.fetch(FetchDescriptor<Track>()) {
            guard let artistName = track.artist?.name,
                  let url = customURL(filename: track.customImageFilename) else { continue }
            let target = ImageTarget(kind: .track, artist: artistName, album: nil, track: track.title)
            lookup[lookupKey(for: target)] = url.absoluteString
        }

        return lookup
    }

    static func effectiveImageURL(
        for target: ImageTarget,
        lookup: [String: String],
        fallbackURL: String? = nil
    ) -> String? {
        if target.kind == .album, let album = target.album,
           let custom = lookup[customAlbumLookupKey(artist: target.artist, album: album)] {
            return custom
        }
        if let direct = lookup[lookupKey(for: target)] { return direct }
        if target.kind == .track, let album = target.album {
            if let custom = lookup[customAlbumLookupKey(artist: target.artist, album: album)] {
                return custom
            }
            let albumTarget = ImageTarget(kind: .album, artist: target.artist, album: album, track: nil)
            if let inherited = lookup[lookupKey(for: albumTarget)] { return inherited }
        }
        guard let fallbackURL, !TextNormalization.isLastfmPlaceholderImage(fallbackURL) else { return nil }
        return target.kind == .artist ? nil : fallbackURL
    }

    @MainActor
    static func effectiveImageURL(for target: ImageTarget, context: ModelContext, fallbackURL: String? = nil) throws -> String? {
        effectiveImageURL(for: target, lookup: try imageLookup(for: target, context: context), fallbackURL: fallbackURL)
    }

    /// The part of `imageLookup(context:)` that `effectiveImageURL(for:lookup:)` can read for ONE target: the same entries,
    /// built the same way, from the few rows that can match it. Resolving a single picture (a detail page's header) used to
    /// build the whole-library index on the main thread, which took about a third of a second on a mid-sized library and
    /// repeated for every page on every return to the tab.
    static func imageLookup(for target: ImageTarget, context: ModelContext) throws -> [String: String] {
        var lookup: [String: String] = [:]

        func addAlbums(artist: String, album: String) throws {
            let normalized = TextNormalization.normalizeAlbumName(album)
            for row in try context.fetch(FetchDescriptor<Album>(predicate: #Predicate { $0.normalizedTitle == normalized })) {
                guard let artistName = row.artist?.name else { continue }
                let rowTarget = ImageTarget(kind: .album, artist: artistName, album: row.title, track: nil)
                if let url = customURL(filename: row.customImageFilename) ?? detectedURL(filename: row.detectedImageFilename) {
                    lookup[lookupKey(for: rowTarget)] = url.absoluteString
                }
            }
            for override in try context.fetch(FetchDescriptor<AlbumImageOverride>()) {
                if let url = customURL(filename: override.filename) {
                    lookup[customAlbumLookupKey(artist: override.artist, album: override.album)] = url.absoluteString
                }
            }
        }

        switch target.kind {
        case .artist:
            let key = TextNormalization.artistIdentityKey(target.artist)
            for artist in try context.fetch(FetchDescriptor<Artist>(predicate: #Predicate { $0.normalizedName == key })) {
                let rowTarget = ImageTarget(kind: .artist, artist: artist.name, album: nil, track: nil)
                if let url = customURL(filename: artist.customImageFilename) ?? detectedURL(filename: artist.detectedImageFilename) {
                    lookup[lookupKey(for: rowTarget)] = url.absoluteString
                }
            }
        case .album:
            try addAlbums(artist: target.artist, album: target.album ?? "")
        case .track:
            let trackKey = TextNormalization.lovedKey(artist: target.artist, track: target.track ?? "")
            for track in try context.fetch(FetchDescriptor<Track>(predicate: #Predicate { $0.identityKey == trackKey })) {
                guard let artistName = track.artist?.name, let url = customURL(filename: track.customImageFilename) else { continue }
                let rowTarget = ImageTarget(kind: .track, artist: artistName, album: nil, track: track.title)
                lookup[lookupKey(for: rowTarget)] = url.absoluteString
            }
            // A track with no picture of its own shows its album's.
            if let album = target.album { try addAlbums(artist: target.artist, album: album) }
        }
        return lookup
    }

    /// A track's own most-played album (by scrobble count, so a track that appears on several releases
    /// picks the one it's actually mostly played from) and its effective artwork — the same resolution
    /// The Climb/Most Recent, Most Often/Overview's mini-sections all use for a bare (artist, track) pair
    /// read out of a query result, where the row itself carries no album of its own.
    static func resolvedTrackArtwork(
        artist: String, track: String, scrobbles: [ScrobbleSnapshot], lookup: [String: String]
    ) -> (album: String?, imageURL: String?) {
        let matches = scrobbles.filter { $0.artistName == artist && $0.trackName == track }
        let album = Dictionary(grouping: matches, by: \.albumName).max { $0.value.count < $1.value.count }?.key
        let fallback = matches.first { $0.albumName == (album ?? "") && $0.imageURL != nil }?.imageURL
        let target = ImageTarget(kind: .track, artist: artist, album: album, track: track)
        return (album, effectiveImageURL(for: target, lookup: lookup, fallbackURL: fallback))
    }

    @MainActor
    static func hasCustomImage(for target: ImageTarget, context: ModelContext) throws -> Bool {
        switch target.kind {
        case .artist:
            let normalizedName = target.artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var descriptor = FetchDescriptor<Artist>(predicate: #Predicate { $0.normalizedName == normalizedName })
            descriptor.fetchLimit = 1
            return try context.fetch(descriptor).first?.customImageFilename != nil
        case .album:
            let artworkKey = TextNormalization.albumArtworkIdentityKey(
                artist: target.artist, album: target.album ?? ""
            )
            var overrideDescriptor = FetchDescriptor<AlbumImageOverride>(
                predicate: #Predicate { $0.identityKey == artworkKey }
            )
            overrideDescriptor.fetchLimit = 1
            if try context.fetch(overrideDescriptor).first != nil { return true }
            let identityKey = TextNormalization.albumIdentityKey(artist: target.artist, album: target.album ?? "")
            var descriptor = FetchDescriptor<Album>(predicate: #Predicate { $0.identityKey == identityKey })
            descriptor.fetchLimit = 1
            return try context.fetch(descriptor).first?.customImageFilename != nil
        case .track:
            let identityKey = TextNormalization.lovedKey(artist: target.artist, track: target.track ?? "")
            var descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.identityKey == identityKey })
            descriptor.fetchLimit = 1
            return try context.fetch(descriptor).first?.customImageFilename != nil
        }
    }

    @MainActor
    static func resolve(
        target: ImageTarget,
        context: ModelContext,
        deezer: DeezerAPIClient,
        force: Bool = false,
        returnEffectiveURL: Bool = true
    ) async throws -> String? {
        if target.kind == .track {
            let album = try resolvedAlbumForTrack(target, context: context)
            let albumTarget = ImageTarget(kind: .album, artist: target.artist, album: album, track: nil)
            return try await resolve(
                target: albumTarget,
                context: context,
                deezer: deezer,
                force: force,
                returnEffectiveURL: returnEffectiveURL
            )
        }

        if !force, isAlreadyResolved(target: target, context: context) {
            return try effectiveImageURL(for: target, context: context)
        }

        let sourceURL: URL?
        let fallbackURL: URL?
        switch target.kind {
        case .artist:
            sourceURL = try await deezer.fetchArtistImageURL(artist: target.artist)
            fallbackURL = nil
        case .album:
            sourceURL = try await deezer.fetchAlbumImageURL(artist: target.artist, album: target.album ?? "")
            fallbackURL = try lastfmFallbackURL(artist: target.artist, album: target.album ?? "", context: context)
        case .track:
            sourceURL = nil
            fallbackURL = nil
        }

        guard sourceURL != nil || fallbackURL != nil else {
            throw ImageResolutionError.noImageFound
        }

        let data: Data
        if let sourceURL {
            do {
                data = try await downloadImage(from: sourceURL)
            } catch {
                guard let fallbackURL, fallbackURL != sourceURL else { throw error }
                data = try await downloadImage(from: fallbackURL)
            }
        } else if let fallbackURL {
            data = try await downloadImage(from: fallbackURL)
        } else {
            throw ImageResolutionError.noImageFound
        }
        _ = try await ImageStore.shared.storeDetectedImage(
            data: data,
            for: target,
            context: context,
            notify: !isBulkResolving,
            save: !isBulkResolving
        )
        guard returnEffectiveURL else { return nil }
        return try effectiveImageURL(for: target, context: context)
    }

    @MainActor
    static func resolveAllUnresolved(
        container: ModelContainer,
        onProgress: (@MainActor @Sendable (_ remaining: Int, _ failed: Int) -> Void)? = nil
    ) async throws {
        guard !isBulkResolving else { return }
        isBulkResolving = true
        defer { isBulkResolving = false }

        var workerProgress: (@Sendable (Int, Int) -> Void)?
        if let onProgress {
            workerProgress = { remaining, failed in
                Task { @MainActor in onProgress(remaining, failed) }
            }
        }
        let progress = workerProgress
        let imagesChanged = try await offMain { try await BackgroundImageResolutionWorker(modelContainer: container).resolveAll(onProgress: progress) }
        if imagesChanged {
            NotificationCenter.default.post(name: .imageDidChange, object: nil)
        }
    }

    @MainActor
    private static func isAlreadyResolved(target: ImageTarget, context: ModelContext) -> Bool {
        switch target.kind {
        case .artist:
            let normalizedName = target.artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var descriptor = FetchDescriptor<Artist>(predicate: #Predicate { $0.normalizedName == normalizedName })
            descriptor.fetchLimit = 1
            return (try? context.fetch(descriptor).first?.imageResolvedAt) != nil
        case .album:
            let identityKey = TextNormalization.albumIdentityKey(artist: target.artist, album: target.album ?? "")
            var descriptor = FetchDescriptor<Album>(predicate: #Predicate { $0.identityKey == identityKey })
            descriptor.fetchLimit = 1
            return (try? context.fetch(descriptor).first?.imageResolvedAt) != nil
        case .track:
            return true
        }
    }

    @MainActor
    private static func resolvedAlbumForTrack(_ target: ImageTarget, context: ModelContext) throws -> String {
        if let album = target.album?.trimmingCharacters(in: .whitespacesAndNewlines), !album.isEmpty {
            return album
        }
        guard let track = target.track, !track.isEmpty else {
            throw ImageResolutionError.trackAlbumNotFound
        }

        let artist = target.artist
        let descriptor = FetchDescriptor<Scrobble>(
            predicate: #Predicate { $0.artistName == artist && $0.trackName == track }
        )
        let album = Dictionary(
            grouping: try context.fetch(descriptor).filter { !$0.albumName.isEmpty },
            by: \.albumName
        )
        .max { lhs, rhs in lhs.value.count < rhs.value.count }?
        .key

        guard let album else { throw ImageResolutionError.trackAlbumNotFound }
        return album
    }

    @MainActor
    private static func lastfmFallbackURL(
        artist: String,
        album: String,
        context: ModelContext
    ) throws -> URL? {
        var descriptor = FetchDescriptor<Scrobble>(
            predicate: #Predicate { $0.artistName == artist && $0.albumName == album },
            sortBy: [SortDescriptor(\.playedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 50
        return try context.fetch(descriptor)
            .compactMap(\.imageURL)
            .first { !TextNormalization.isLastfmPlaceholderImage($0) }
            .flatMap(URL.init(string:))
    }

    private static func downloadImage(from url: URL) async throws -> Data {
        try ConnectivityGate.check(host: url.host)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(from: url)
            ConnectivityHub.reportSuccess()
        } catch {
            ConnectivityHub.report(error, host: url.host, source: "Artwork")
            throw error
        }
        guard let http = response as? HTTPURLResponse else { throw ImageResolutionError.invalidHTTPResponse }
        guard (200..<300).contains(http.statusCode) else { throw ImageResolutionError.httpStatus(http.statusCode) }
        return data
    }

    private static func customURL(filename: String?) -> URL? {
        guard let filename else { return nil }
        return ImageStore.localCustomFileURL(for: filename)
    }

    private static func detectedURL(filename: String?) -> URL? {
        guard let filename else { return nil }
        return ImageStore.localCachedFileURL(for: filename)
    }
}
