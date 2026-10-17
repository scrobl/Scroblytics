import AppKit
import Foundation
import ImageIO
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

enum ImageTargetKind: String, Codable, Sendable {
    case artist
    case album
    case track
}

struct ImageTarget: Hashable, Sendable {
    let kind: ImageTargetKind
    let artist: String
    let album: String?
    let track: String?

    var displayTitle: String {
        switch kind {
        case .artist:
            artist
        case .album:
            "\(artist) — \(album ?? "Unknown Album")"
        case .track:
            "\(artist) — \(track ?? "Unknown Track")"
        }
    }
}

enum ImageStoreError: LocalizedError {
    case invalidImage
    case entityNotFound
    case noImageOnPasteboard

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            "The selected data is not a readable image."
        case .entityNotFound:
            "The matching library entity could not be found."
        case .noImageOnPasteboard:
            "The clipboard does not contain an image."
        }
    }
}

@MainActor
final class ImageStore {
    static let shared = ImageStore()

    nonisolated static func customImagesDirectory() -> URL {
        applicationSupportDirectory().appendingPathComponent("CustomImages", isDirectory: true)
    }

    nonisolated static func cachedImagesDirectory() -> URL {
        applicationSupportDirectory().appendingPathComponent("CachedImages", isDirectory: true)
    }

    nonisolated static func localCustomFileURL(for filename: String) -> URL? {
        existingFile(named: filename, in: customImagesDirectory())
    }

    nonisolated static func localCachedFileURL(for filename: String) -> URL? {
        existingFile(named: filename, in: cachedImagesDirectory())
    }

    func setCustomImage(data: Data, for target: ImageTarget, context: ModelContext) throws {
        guard NSImage(data: data) != nil else { throw ImageStoreError.invalidImage }
        let filename = try write(data: data, prefix: "override-\(Self.safeKey(for: target))", directory: Self.customImagesDirectory())

        switch target.kind {
        case .artist:
            let normalizedName = target.artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var descriptor = FetchDescriptor<Artist>(predicate: #Predicate { $0.normalizedName == normalizedName })
            descriptor.fetchLimit = 1
            guard let entity = try context.fetch(descriptor).first else {
                try? FileManager.default.removeItem(at: Self.customImagesDirectory().appendingPathComponent(filename))
                throw ImageStoreError.entityNotFound
            }
            removeCustomFile(entity.customImageFilename)
            entity.customImageFilename = filename
        case .album:
            let identityKey = TextNormalization.albumIdentityKey(artist: target.artist, album: target.album ?? "")
            var descriptor = FetchDescriptor<Album>(predicate: #Predicate { $0.identityKey == identityKey })
            descriptor.fetchLimit = 1
            guard let entity = try context.fetch(descriptor).first else {
                try? FileManager.default.removeItem(at: Self.customImagesDirectory().appendingPathComponent(filename))
                throw ImageStoreError.entityNotFound
            }
            let artworkKey = TextNormalization.albumArtworkIdentityKey(
                artist: target.artist, album: target.album ?? ""
            )
            var overrideDescriptor = FetchDescriptor<AlbumImageOverride>(
                predicate: #Predicate { $0.identityKey == artworkKey }
            )
            overrideDescriptor.fetchLimit = 1
            if let existing = try context.fetch(overrideDescriptor).first {
                removeCustomFile(existing.filename)
                existing.filename = filename
            } else {
                context.insert(AlbumImageOverride(
                    identityKey: artworkKey,
                    artist: target.artist,
                    album: target.album ?? "",
                    filename: filename
                ))
            }
            // Migrate away from the former group-wide slot. It cannot identify
            // which edition the user intended and is the source of cross-edition
            // artwork leakage.
            removeCustomFile(entity.customImageFilename)
            entity.customImageFilename = nil
        case .track:
            let identityKey = TextNormalization.lovedKey(artist: target.artist, track: target.track ?? "")
            var descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.identityKey == identityKey })
            descriptor.fetchLimit = 1
            guard let entity = try context.fetch(descriptor).first else {
                try? FileManager.default.removeItem(at: Self.customImagesDirectory().appendingPathComponent(filename))
                throw ImageStoreError.entityNotFound
            }
            removeCustomFile(entity.customImageFilename)
            entity.customImageFilename = filename
        }

        try context.save()
        NotificationCenter.default.post(name: .imageDidChange, object: target)
    }

    func clearCustomImage(for target: ImageTarget, context: ModelContext) throws {
        switch target.kind {
        case .artist:
            let normalizedName = target.artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var descriptor = FetchDescriptor<Artist>(predicate: #Predicate { $0.normalizedName == normalizedName })
            descriptor.fetchLimit = 1
            guard let entity = try context.fetch(descriptor).first else { throw ImageStoreError.entityNotFound }
            removeCustomFile(entity.customImageFilename)
            entity.customImageFilename = nil
        case .album:
            let identityKey = TextNormalization.albumIdentityKey(artist: target.artist, album: target.album ?? "")
            var descriptor = FetchDescriptor<Album>(predicate: #Predicate { $0.identityKey == identityKey })
            descriptor.fetchLimit = 1
            guard let entity = try context.fetch(descriptor).first else { throw ImageStoreError.entityNotFound }
            let artworkKey = TextNormalization.albumArtworkIdentityKey(
                artist: target.artist, album: target.album ?? ""
            )
            var overrideDescriptor = FetchDescriptor<AlbumImageOverride>(
                predicate: #Predicate { $0.identityKey == artworkKey }
            )
            overrideDescriptor.fetchLimit = 1
            if let existing = try context.fetch(overrideDescriptor).first {
                removeCustomFile(existing.filename)
                context.delete(existing)
            }
            removeCustomFile(entity.customImageFilename)
            entity.customImageFilename = nil
        case .track:
            let identityKey = TextNormalization.lovedKey(artist: target.artist, track: target.track ?? "")
            var descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.identityKey == identityKey })
            descriptor.fetchLimit = 1
            guard let entity = try context.fetch(descriptor).first else { throw ImageStoreError.entityNotFound }
            removeCustomFile(entity.customImageFilename)
            entity.customImageFilename = nil
        }

        try context.save()
        NotificationCenter.default.post(name: .imageDidChange, object: target)
    }

    func storeDetectedImage(
        data: Data?,
        for target: ImageTarget,
        context: ModelContext,
        notify: Bool = true,
        save: Bool = true
    ) async throws -> String? {
        guard target.kind != .track else { return nil }
        let filename = try await Self.writeDetectedImage(
            data: data,
            prefix: "detected-\(Self.safeKey(for: target))"
        )

        switch target.kind {
        case .artist:
            let normalizedName = target.artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var descriptor = FetchDescriptor<Artist>(predicate: #Predicate { $0.normalizedName == normalizedName })
            descriptor.fetchLimit = 1
            guard let artist = try context.fetch(descriptor).first else { throw ImageStoreError.entityNotFound }
            artist.detectedImageFilename = try stableDetectedFilename(
                newFilename: filename,
                data: data,
                existingFilename: artist.detectedImageFilename
            )
            artist.imageResolvedAt = Date()
        case .album:
            let identityKey = TextNormalization.albumIdentityKey(artist: target.artist, album: target.album ?? "")
            var descriptor = FetchDescriptor<Album>(predicate: #Predicate { $0.identityKey == identityKey })
            descriptor.fetchLimit = 1
            guard let album = try context.fetch(descriptor).first else { throw ImageStoreError.entityNotFound }
            album.detectedImageFilename = try stableDetectedFilename(
                newFilename: filename,
                data: data,
                existingFilename: album.detectedImageFilename
            )
            album.imageResolvedAt = Date()
        case .track:
            break
        }

        if save {
            try context.save()
        }
        if notify {
            NotificationCenter.default.post(name: .imageDidChange, object: target)
        }
        return filename
    }

    func imageDataOnPasteboard() throws -> Data {
        let pasteboard = NSPasteboard.general

        // Browsers and image editors often publish JPEG, WebP, HEIC, or a
        // vendor-specific type that conforms to `public.image` without also
        // providing AppKit's traditional TIFF representation.
        for item in pasteboard.pasteboardItems ?? [] {
            for type in item.types where Self.isImagePasteboardType(type) {
                if let rawData = item.data(forType: type),
                   let image = NSImage(data: rawData),
                   let data = pngData(from: image) {
                    return data
                }
            }
        }

        if let image = pasteboard.readObjects(forClasses: [NSImage.self])?.first as? NSImage,
           let data = pngData(from: image) {
            return data
        }

        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let rawData = pasteboard.data(forType: type),
               let image = NSImage(data: rawData),
               let data = pngData(from: image) {
                return data
            }
        }

        let fileOptions: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: fileOptions) as? [URL] {
            for url in urls {
                if let image = NSImage(contentsOf: url), let data = pngData(from: image) {
                    return data
                }
            }
        }

        throw ImageStoreError.noImageOnPasteboard
    }

    func hasImageOnPasteboard() -> Bool {
        let pasteboard = NSPasteboard.general
        if pasteboard.pasteboardItems?.contains(where: { item in
            item.types.contains(where: Self.isImagePasteboardType)
        }) == true {
            return true
        }
        if pasteboard.canReadObject(forClasses: [NSImage.self]) { return true }
        if pasteboard.availableType(from: [.png, .tiff]) != nil { return true }

        let fileOptions: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: fileOptions) as? [URL] else {
            return false
        }
        return urls.contains { NSImage(contentsOf: $0) != nil }
    }

    private nonisolated static func isImagePasteboardType(_ type: NSPasteboard.PasteboardType) -> Bool {
        UTType(type.rawValue)?.conforms(to: .image) == true
    }

    func copyImage(at urlString: String?) async throws {
        guard let urlString, let url = URL(string: urlString) else {
            throw ImageStoreError.invalidImage
        }

        let image: NSImage
        if url.isFileURL {
            guard let localImage = NSImage(contentsOf: url) else {
                throw ImageStoreError.invalidImage
            }
            image = localImage
        } else {
            try ConnectivityGate.check(host: url.host)
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  let remoteImage = NSImage(data: data) else {
                throw ImageStoreError.invalidImage
            }
            image = remoteImage
        }

        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.writeObjects([image]) else { throw ImageStoreError.invalidImage }
    }

    private func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff) else { return nil }
        return representation.representation(using: .png, properties: [:])
    }

    nonisolated static func writeDetectedImage(
        data: Data?,
        prefix: String
    ) async throws -> String? {
        guard let data else { return nil }
        return try await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithData(data as CFData, [
                kCGImageSourceShouldCache: false
            ] as CFDictionary) else {
                throw ImageStoreError.invalidImage
            }
            let validationOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 1
            ]
            guard CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                validationOptions as CFDictionary
            ) != nil else {
                throw ImageStoreError.invalidImage
            }

            let directory = cachedImagesDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let filename = "\(prefix)-\(UUID().uuidString.lowercased()).\(imageExtension(for: data))"
            try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
            return filename
        }.value
    }

    private func write(data: Data, prefix: String, directory: URL) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileExtension = Self.imageExtension(for: data)
        let filename = "\(prefix)-\(UUID().uuidString.lowercased()).\(fileExtension)"
        try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
        return filename
    }

    private func removeCustomFile(_ filename: String?) {
        guard let filename else { return }
        try? FileManager.default.removeItem(at: Self.customImagesDirectory().appendingPathComponent(filename))
    }

    private func stableDetectedFilename(
        newFilename: String?,
        data: Data?,
        existingFilename: String?
    ) throws -> String? {
        guard let existingFilename, let data else {
            removeCachedFile(existingFilename)
            return newFilename
        }

        let existingURL = Self.cachedImagesDirectory().appendingPathComponent(existingFilename)
        try data.write(to: existingURL, options: .atomic)
        if let newFilename, newFilename != existingFilename {
            removeCachedFile(newFilename)
        }
        return existingFilename
    }

    private func removeCachedFile(_ filename: String?) {
        guard let filename else { return }
        try? FileManager.default.removeItem(at: Self.cachedImagesDirectory().appendingPathComponent(filename))
    }

    private nonisolated static func applicationSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scroblytics", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private nonisolated static func existingFile(named filename: String, in directory: URL) -> URL? {
        let url = directory.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    nonisolated static func safeKey(for target: ImageTarget) -> String {
        let raw: String
        switch target.kind {
        case .artist:
            raw = target.artist
        case .album:
            raw = "\(target.artist)-\(target.album ?? "")"
        case .track:
            raw = "\(target.artist)-\(target.track ?? "")"
        }
        let safe = raw.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        return String(safe.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(64))
    }

    private nonisolated static func imageExtension(for data: Data) -> String {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if data.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "gif" }
        if data.starts(with: [0x52, 0x49, 0x46, 0x46]) { return "webp" }
        return "png"
    }
}

@MainActor
private final class LocalArtworkCache {
    static let shared = LocalArtworkCache()

    private let images = NSCache<NSString, NSImage>()

    private init() {
        images.countLimit = 300
        images.totalCostLimit = 96 * 1_024 * 1_024
    }

    func removeAll() {
        images.removeAllObjects()
    }

    /// What is already decoded, without waiting: a view that is rebuilt (a card that moves from one list to another) shows it at once
    /// instead of flashing its placeholder.
    func cachedImage(for url: URL, maxPixelSize: Int) -> NSImage? {
        images.object(forKey: "\(url.path)#\(maxPixelSize)" as NSString)
    }

    func image(for url: URL, maxPixelSize: Int) async -> NSImage? {
        let cacheKey = "\(url.path)#\(maxPixelSize)" as NSString
        if let cached = images.object(forKey: cacheKey) {
            return cached
        }

        let cgImage = await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [
                kCGImageSourceShouldCache: false
            ] as CFDictionary) else {
                return nil as CGImage?
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value

        guard let cgImage else { return nil }
        let image = NSImage(cgImage: cgImage, size: .zero)
        images.setObject(
            image,
            forKey: cacheKey,
            cost: cgImage.bytesPerRow * cgImage.height
        )
        return image
    }
}

private struct LocalArtworkImage<Placeholder: View>: View {
    let url: URL
    let size: CGSize
    let contentMode: ContentMode
    @ViewBuilder let placeholder: Placeholder

    @Environment(\.displayScale) private var displayScale
    @State private var image: NSImage?

    private var maxPixelSize: Int {
        max(1, Int(ceil(max(size.width, size.height) * displayScale)))
    }

    var body: some View {
        Group {
            if let shown = image ?? LocalArtworkCache.shared.cachedImage(for: url, maxPixelSize: maxPixelSize) {
                Image(nsImage: shown)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .task(id: "\(url.path)#\(maxPixelSize)") {
            image = await LocalArtworkCache.shared.image(
                for: url,
                maxPixelSize: maxPixelSize
            )
        }
    }
}

/// Pictures fetched from the web, kept in memory once seen. `AsyncImage` starts from its placeholder every time a view is rebuilt,
/// even for a picture it just showed, so a card that moves (a suggestion that becomes a step in a path) flashed empty and reloaded.
@MainActor
private final class RemoteArtworkCache {
    static let shared = RemoteArtworkCache()

    private let images = NSCache<NSURL, NSImage>()
    private var loading: [URL: Task<NSImage?, Never>] = [:]

    private init() {
        images.countLimit = 300
        images.totalCostLimit = 96 * 1_024 * 1_024
    }

    func removeAll() {
        images.removeAllObjects()
    }

    func cachedImage(for url: URL) -> NSImage? {
        images.object(forKey: url as NSURL)
    }

    /// Views asking for the same picture at once share one download. The system's URL cache still applies underneath.
    func image(for url: URL) async -> NSImage? {
        if let cached = cachedImage(for: url) { return cached }
        let task: Task<NSImage?, Never>
        if let running = loading[url] {
            task = running
        } else {
            task = Task {
                guard let (data, response) = try? await URLSession.shared.data(from: url),
                      (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                      let image = NSImage(data: data) else { return nil }
                return image
            }
            loading[url] = task
        }
        let image = await task.value
        loading[url] = nil
        if let image { images.setObject(image, forKey: url as NSURL, cost: cost(of: image)) }
        return image
    }

    private func cost(of image: NSImage) -> Int {
        let size = image.size
        return max(1, Int(size.width * size.height * 4))
    }
}

private struct RemoteArtworkImage<Placeholder: View>: View {
    let url: URL
    let contentMode: ContentMode
    @ViewBuilder let placeholder: Placeholder

    @State private var loaded: NSImage?

    var body: some View {
        Group {
            if let shown = loaded ?? RemoteArtworkCache.shared.cachedImage(for: url) {
                Image(nsImage: shown)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder
            }
        }
        .task(id: url) {
            loaded = nil
            if RemoteArtworkCache.shared.cachedImage(for: url) != nil { return }
            loaded = await RemoteArtworkCache.shared.image(for: url)
        }
    }
}

struct ArtworkImage<Placeholder: View>: View {
    let urlString: String?
    let contentMode: ContentMode
    @ViewBuilder let placeholder: Placeholder

    @State private var refreshID = UUID()

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let urlString, let url = URL(string: urlString) {
                    if url.isFileURL {
                        LocalArtworkImage(
                            url: url,
                            size: geometry.size,
                            contentMode: contentMode
                        ) {
                            placeholder
                        }
                    } else if Connectivity.shared.isOffline {
                        // Offline mode: don't ask the network for remote art; show the placeholder.
                        placeholder
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    } else {
                        RemoteArtworkImage(url: url, contentMode: contentMode) { placeholder }
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    }
                } else {
                    placeholder
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            .id(refreshID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .imageDidChange)) { _ in
            LocalArtworkCache.shared.removeAll()
            RemoteArtworkCache.shared.removeAll()
            refreshID = UUID()
        }
    }
}

extension Notification.Name {
    static let imageDidChange = Notification.Name("imageDidChange")
}
