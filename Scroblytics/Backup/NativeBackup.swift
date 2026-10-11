import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let scroblyticsBackup = UTType(exportedAs: "com.scroblytics.native-backup", conformingTo: .json)
}

struct NativeBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.scroblyticsBackup, .json] }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct ListeningHistoryCSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

@ModelActor
actor ListeningHistoryCSVExporter {
    func makeDocument() throws -> ListeningHistoryCSVDocument {
        let descriptor = FetchDescriptor<Scrobble>(sortBy: [SortDescriptor(\.playedAt)])
        let scrobbles = try modelContext.fetch(descriptor)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var csv = "\u{FEFF}artist,album,track,played_at_utc,unix_timestamp,image_url\r\n"
        csv.reserveCapacity(max(1_024, scrobbles.count * 120))
        for scrobble in scrobbles {
            let fields = [
                scrobble.artistName,
                scrobble.albumName,
                scrobble.trackName,
                formatter.string(from: scrobble.playedAt),
                String(Int(scrobble.playedAt.timeIntervalSince1970)),
                scrobble.imageURL ?? ""
            ]
            csv += fields.map(Self.escape).joined(separator: ",") + "\r\n"
        }
        return ListeningHistoryCSVDocument(data: Data(csv.utf8))
    }

    private static func escape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

enum NativeBackupFormat {
    static let currentVersion = 1

    struct Archive: Codable {
        let format: String
        let formatVersion: Int
        let createdAt: Date
        let appVersion: String
        let username: String?
        var albums: [AlbumRecord]
        var tracks: [TrackRecord]
        var artistImages: [ArtistImageRecord]
        var albumImages: [AlbumImageRecord]
        var flaggedTracks: [FlaggedTrackRecord]
        var savedConditionSets: [SavedConditionSetRecord]
        var legacySavedQueries: [SavedQueryRecord]
        var linerNotes: [LinerNoteRecord]
        var toolFilters: [ToolFilterRecord]
        /// Tracks confirmed in Library Gaps (stored under their original "dismissed" name). Optional so archives written before it existed still decode — and
        /// restoring one of those leaves the current confirmations alone.
        var dismissedLibraryGaps: [DismissedLibraryGapRecord]?
        /// Loved Status Audit decisions ("same track" / "different tracks"). Optional for the same reason as above.
        var lovedAuditDecisions: [LovedAuditDecisionRecord]?
        /// Tag Management playlist rules. Optional for the same reason as above.
        var tagRules: [TagRuleRecord]?
        var theme: String
        var images: [String: Data]
    }

    struct AlbumRecord: Codable {
        let artist: String
        let title: String
        let releaseDateOverride: String?
        let customImageFilename: String?
        let matchMode: String?
        let canonicalArtist: String?
        let canonicalAlbum: String?
        let manualTracklist: [String]?
    }

    struct TrackRecord: Codable {
        let artist: String
        let title: String
        let durationOverrideSeconds: Int?
        let bpmOverride: Double?
        let releaseDateOverride: String?
        let customImageFilename: String?
    }

    struct ArtistImageRecord: Codable { let artist: String; let filename: String }
    struct AlbumImageRecord: Codable { let artist: String; let album: String; let filename: String }
    struct FlaggedTrackRecord: Codable { let artist: String; let track: String; let album: String?; let flaggedAt: Date }
    struct SavedConditionSetRecord: Codable { let id: UUID; let name: String; let specJSON: Data; let createdAt: Date; let updatedAt: Date }
    struct SavedQueryRecord: Codable { let id: String; let name: String; let queryJSON: Data; let createdAt: Date; let columns: [String]? }
    struct LinerNoteRecord: Codable {
        let id: String; let periodType: String; let from: Date; let to: Date; let label: String
        let optionsJSON: Data; let text: String; let generatedText: String; let generatedAt: Date; let updatedAt: Date
    }
    struct TagRuleRecord: Codable {
        let id: UUID; let playlistPersistentID: String; let playlistName: String; let tags: [String]
        let mirrorRemovals: Bool; let createdAt: Date; let lastAppliedAt: Date?
    }
    struct DismissedLibraryGapRecord: Codable { let artist: String; let track: String; let dismissedAt: Date; var nearMatch: String? = nil }
    struct LovedAuditDecisionRecord: Codable {
        let lastfmArtist: String; let lastfmTrack: String; let appleArtist: String; let appleTrack: String
        let sameTrack: Bool; let decidedAt: Date
    }
    struct ToolFilterRecord: Codable { let toolId: String; let optionsJSON: Data; let advancedGroupsJSON: Data }
}

enum NativeBackupError: LocalizedError {
    case wrongFormat
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .wrongFormat:
            return "This is not a Scroblytics backup."
        case .unsupportedVersion(let version):
            return "This backup uses format version \(version), which this version of Scroblytics cannot restore."
        }
    }
}

@MainActor
enum NativeBackupEngine {
    struct Summary {
        let albums: Int
        let tracks: Int
        let customImages: Int
        let flaggedTracks: Int
        let savedQueries: Int
        var dismissedLibraryGaps = 0
        var lovedAuditDecisions = 0
        var tagRules = 0

        var description: String {
            var text = "\(albums) album edits · \(tracks) track edits · \(customImages) images · \(flaggedTracks) flagged tracks · \(savedQueries) saved queries"
            if dismissedLibraryGaps > 0 { text += " · \(dismissedLibraryGaps) confirmed library gaps" }
            if lovedAuditDecisions > 0 { text += " · \(lovedAuditDecisions) loved-audit decisions" }
            if tagRules > 0 { text += " · \(tagRules) tag rules" }
            return text
        }
    }

    static func makeDocument(context: ModelContext) throws -> NativeBackupDocument {
        let archive = try makeArchive(context: context)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return NativeBackupDocument(data: try encoder.encode(archive))
    }

    static func inspect(document: NativeBackupDocument) throws -> (NativeBackupFormat.Archive, Summary) {
        let archive = try decode(document.data)
        return (archive, summary(for: archive))
    }

    static func restore(_ archive: NativeBackupFormat.Archive, context: ModelContext) throws {
        try validate(archive)
        try clearRestorableData(context: context)

        for record in archive.albums {
            let artist = try findOrCreateArtist(named: record.artist, context: context)
            let key = TextNormalization.albumIdentityKey(artist: record.artist, album: record.title)
            var descriptor = FetchDescriptor<Album>(predicate: #Predicate { $0.identityKey == key })
            descriptor.fetchLimit = 1
            let album = try context.fetch(descriptor).first ?? Album(
                identityKey: key,
                title: record.title,
                normalizedTitle: TextNormalization.normalizeAlbumName(record.title),
                artist: artist
            )
            if album.modelContext == nil { context.insert(album) }
            album.releaseDateOverride = record.releaseDateOverride
            album.customImageFilename = record.customImageFilename
            album.matchResolutionMode = record.matchMode.flatMap(AlbumMatchMode.init(rawValue:))
            album.canonicalArtist = record.canonicalArtist
            album.canonicalAlbum = record.canonicalAlbum
            album.manualTracklist = record.manualTracklist
        }

        for record in archive.tracks {
            let artist = try findOrCreateArtist(named: record.artist, context: context)
            let key = TextNormalization.lovedKey(artist: record.artist, track: record.title)
            var descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.identityKey == key })
            descriptor.fetchLimit = 1
            let track = try context.fetch(descriptor).first ?? Track(
                identityKey: key,
                title: record.title,
                normalizedTitle: record.title.trimmingCharacters(in: .whitespaces).lowercased(),
                artist: artist
            )
            if track.modelContext == nil { context.insert(track) }
            track.durationOverrideSeconds = record.durationOverrideSeconds
            track.bpmOverride = record.bpmOverride
            track.releaseDateOverride = record.releaseDateOverride
            track.customImageFilename = record.customImageFilename
        }

        for record in archive.artistImages {
            let artist = try findOrCreateArtist(named: record.artist, context: context)
            artist.customImageFilename = record.filename
        }
        for record in archive.albumImages {
            let key = TextNormalization.albumIdentityKey(artist: record.artist, album: record.album)
            context.insert(AlbumImageOverride(identityKey: key, artist: record.artist, album: record.album, filename: record.filename))
        }
        for record in archive.flaggedTracks {
            context.insert(FlaggedTrack(artist: record.artist, track: record.track, album: record.album, flaggedAt: record.flaggedAt))
        }
        for record in archive.savedConditionSets {
            context.insert(SavedConditionSet(id: record.id, name: record.name, specJSON: record.specJSON, createdAt: record.createdAt, updatedAt: record.updatedAt))
        }
        for record in archive.legacySavedQueries {
            context.insert(SavedQuery(remoteId: record.id, name: record.name, queryJSON: record.queryJSON, createdAt: record.createdAt, columns: record.columns))
        }
        for record in archive.linerNotes {
            context.insert(LinerNote(remoteId: record.id, periodType: record.periodType, from: record.from, to: record.to, label: record.label, optionsJSON: record.optionsJSON, text: record.text, generatedText: record.generatedText, generatedAt: record.generatedAt, updatedAt: record.updatedAt))
        }
        for record in archive.toolFilters {
            context.insert(ToolFilterSetting(toolId: record.toolId, optionsJSON: record.optionsJSON, advancedGroupsJSON: record.advancedGroupsJSON))
        }
        try restoreDismissedLibraryGaps(archive.dismissedLibraryGaps, context: context, save: false)
        try restoreLovedAuditDecisions(archive.lovedAuditDecisions, context: context, save: false)
        try restoreTagRules(archive.tagRules, context: context, save: false)

        UserDefaults.standard.set(archive.theme, forKey: AppearancePreference.storageKey)
        let appSettings = try context.fetch(FetchDescriptor<AppSettings>()).first
        if let appSettings { appSettings.theme = archive.theme } else { context.insert(AppSettings(theme: archive.theme)) }
        try restoreImages(archive.images)
        try context.save()
    }

    /// Replaces the Library Gaps confirmations with the archive's. `nil` — an archive from before they were backed
    /// up — leaves the current ones alone rather than wiping them.
    static func restoreDismissedLibraryGaps(_ records: [NativeBackupFormat.DismissedLibraryGapRecord]?, context: ModelContext, save: Bool = true) throws {
        guard let records else { return }
        for item in try context.fetch(FetchDescriptor<LibraryGapDismissal>()) { context.delete(item) }
        var seen = Set<String>()
        for record in records {
            let key = LibraryGapsEngine.key(artist: record.artist, track: record.track)
            guard seen.insert(key).inserted else { continue }
            context.insert(LibraryGapDismissal(matchKey: key, artist: record.artist, track: record.track, dismissedAt: record.dismissedAt, nearMatch: record.nearMatch))
        }
        if save { try context.save() }
    }

    /// Replaces the Loved Status Audit decisions with the archive's; `nil` (an older archive) leaves the current ones alone.
    static func restoreLovedAuditDecisions(_ records: [NativeBackupFormat.LovedAuditDecisionRecord]?, context: ModelContext, save: Bool = true) throws {
        guard let records else { return }
        for item in try context.fetch(FetchDescriptor<LovedAuditDecision>()) { context.delete(item) }
        var seen = Set<String>()
        for record in records {
            let key = LovedStatusAuditEngine.pairKey(
                lastfm: .init(artist: record.lastfmArtist, track: record.lastfmTrack), apple: .init(artist: record.appleArtist, track: record.appleTrack)
            )
            guard seen.insert(key).inserted else { continue }
            context.insert(LovedAuditDecision(
                pairKey: key, lastfmArtist: record.lastfmArtist, lastfmTrack: record.lastfmTrack,
                appleArtist: record.appleArtist, appleTrack: record.appleTrack, sameTrack: record.sameTrack, decidedAt: record.decidedAt
            ))
        }
        if save { try context.save() }
    }

    /// Replaces the Tag Management rules with the archive's; `nil` (an older archive) leaves the current ones alone.
    static func restoreTagRules(_ records: [NativeBackupFormat.TagRuleRecord]?, context: ModelContext, save: Bool = true) throws {
        guard let records else { return }
        for item in try context.fetch(FetchDescriptor<TagPlaylistRule>()) { context.delete(item) }
        for record in records {
            context.insert(TagPlaylistRule(
                id: record.id, playlistPersistentID: record.playlistPersistentID, playlistName: record.playlistName, tags: record.tags,
                mirrorRemovals: record.mirrorRemovals, createdAt: record.createdAt, lastAppliedAt: record.lastAppliedAt
            ))
        }
        if save { try context.save() }
    }

    private static func makeArchive(context: ModelContext) throws -> NativeBackupFormat.Archive {
        let albums = try context.fetch(FetchDescriptor<Album>()).compactMap { album -> NativeBackupFormat.AlbumRecord? in
            guard album.releaseDateOverride != nil || album.customImageFilename != nil || album.matchResolutionMode != nil else { return nil }
            return .init(artist: album.artist?.name ?? "", title: album.title, releaseDateOverride: album.releaseDateOverride, customImageFilename: album.customImageFilename, matchMode: album.matchResolutionMode?.rawValue, canonicalArtist: album.canonicalArtist, canonicalAlbum: album.canonicalAlbum, manualTracklist: album.manualTracklist)
        }
        let tracks = try context.fetch(FetchDescriptor<Track>()).compactMap { track -> NativeBackupFormat.TrackRecord? in
            guard track.durationOverrideSeconds != nil || track.bpmOverride != nil || track.releaseDateOverride != nil || track.customImageFilename != nil else { return nil }
            return .init(artist: track.artist?.name ?? "", title: track.title, durationOverrideSeconds: track.durationOverrideSeconds, bpmOverride: track.bpmOverride, releaseDateOverride: track.releaseDateOverride, customImageFilename: track.customImageFilename)
        }
        let artists = try context.fetch(FetchDescriptor<Artist>())
        let artistImages = artists.compactMap { artist in artist.customImageFilename.map { NativeBackupFormat.ArtistImageRecord(artist: artist.name, filename: $0) } }
        let albumImages = try context.fetch(FetchDescriptor<AlbumImageOverride>()).map { NativeBackupFormat.AlbumImageRecord(artist: $0.artist, album: $0.album, filename: $0.filename) }
        let flagged = try context.fetch(FetchDescriptor<FlaggedTrack>()).map { NativeBackupFormat.FlaggedTrackRecord(artist: $0.artist, track: $0.track, album: $0.album, flaggedAt: $0.flaggedAt) }
        let conditions = try context.fetch(FetchDescriptor<SavedConditionSet>()).map { NativeBackupFormat.SavedConditionSetRecord(id: $0.id, name: $0.name, specJSON: $0.specJSON, createdAt: $0.createdAt, updatedAt: $0.updatedAt) }
        let savedQueries = try context.fetch(FetchDescriptor<SavedQuery>()).map { NativeBackupFormat.SavedQueryRecord(id: $0.remoteId, name: $0.name, queryJSON: $0.queryJSON, createdAt: $0.createdAt, columns: $0.columns) }
        let linerNotes = try context.fetch(FetchDescriptor<LinerNote>()).map { NativeBackupFormat.LinerNoteRecord(id: $0.remoteId, periodType: $0.periodType, from: $0.from, to: $0.to, label: $0.label, optionsJSON: $0.optionsJSON, text: $0.text, generatedText: $0.generatedText, generatedAt: $0.generatedAt, updatedAt: $0.updatedAt) }
        let filters = try context.fetch(FetchDescriptor<ToolFilterSetting>()).map { NativeBackupFormat.ToolFilterRecord(toolId: $0.toolId, optionsJSON: $0.optionsJSON, advancedGroupsJSON: $0.advancedGroupsJSON) }
        let filenames = Set(albums.compactMap(\.customImageFilename) + tracks.compactMap(\.customImageFilename) + artistImages.map(\.filename) + albumImages.map(\.filename))
        let images = readImages(named: filenames)
        let dismissed = try context.fetch(FetchDescriptor<LibraryGapDismissal>()).map { NativeBackupFormat.DismissedLibraryGapRecord(artist: $0.artist, track: $0.track, dismissedAt: $0.dismissedAt, nearMatch: $0.nearMatch) }
        let auditDecisions = try context.fetch(FetchDescriptor<LovedAuditDecision>()).map {
            NativeBackupFormat.LovedAuditDecisionRecord(lastfmArtist: $0.lastfmArtist, lastfmTrack: $0.lastfmTrack, appleArtist: $0.appleArtist, appleTrack: $0.appleTrack, sameTrack: $0.sameTrack, decidedAt: $0.decidedAt)
        }
        let tagRules = try context.fetch(FetchDescriptor<TagPlaylistRule>()).map {
            NativeBackupFormat.TagRuleRecord(id: $0.id, playlistPersistentID: $0.playlistPersistentID, playlistName: $0.playlistName, tags: $0.tags, mirrorRemovals: $0.mirrorRemovals, createdAt: $0.createdAt, lastAppliedAt: $0.lastAppliedAt)
        }
        let username = try context.fetch(FetchDescriptor<SyncState>()).first?.username
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let theme = UserDefaults.standard.string(forKey: AppearancePreference.storageKey) ?? AppearancePreference.dark.rawValue
        return .init(format: "Scroblytics Native Backup", formatVersion: NativeBackupFormat.currentVersion, createdAt: Date(), appVersion: appVersion, username: username, albums: albums, tracks: tracks, artistImages: artistImages, albumImages: albumImages, flaggedTracks: flagged, savedConditionSets: conditions, legacySavedQueries: savedQueries, linerNotes: linerNotes, toolFilters: filters, dismissedLibraryGaps: dismissed, lovedAuditDecisions: auditDecisions, tagRules: tagRules, theme: theme, images: images)
    }

    private static func decode(_ data: Data) throws -> NativeBackupFormat.Archive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(NativeBackupFormat.Archive.self, from: data)
        try validate(archive)
        return archive
    }

    private static func validate(_ archive: NativeBackupFormat.Archive) throws {
        guard archive.format == "Scroblytics Native Backup" else { throw NativeBackupError.wrongFormat }
        guard archive.formatVersion == NativeBackupFormat.currentVersion else { throw NativeBackupError.unsupportedVersion(archive.formatVersion) }
    }

    private static func summary(for archive: NativeBackupFormat.Archive) -> Summary {
        Summary(albums: archive.albums.count, tracks: archive.tracks.count, customImages: archive.images.count, flaggedTracks: archive.flaggedTracks.count, savedQueries: archive.savedConditionSets.count, dismissedLibraryGaps: archive.dismissedLibraryGaps?.count ?? 0, lovedAuditDecisions: archive.lovedAuditDecisions?.count ?? 0, tagRules: archive.tagRules?.count ?? 0)
    }

    private static func findOrCreateArtist(named name: String, context: ModelContext) throws -> Artist {
        let normalized = TextNormalization.artistIdentityKey(name)
        var descriptor = FetchDescriptor<Artist>(predicate: #Predicate { $0.normalizedName == normalized })
        descriptor.fetchLimit = 1
        if let artist = try context.fetch(descriptor).first { return artist }
        let artist = Artist(normalizedName: normalized, name: name)
        context.insert(artist)
        return artist
    }

    private static func clearRestorableData(context: ModelContext) throws {
        for album in try context.fetch(FetchDescriptor<Album>()) {
            album.releaseDateOverride = nil; album.customImageFilename = nil; album.matchResolutionMode = nil
            album.canonicalArtist = nil; album.canonicalAlbum = nil; album.manualTracklist = nil
        }
        for track in try context.fetch(FetchDescriptor<Track>()) {
            track.durationOverrideSeconds = nil; track.bpmOverride = nil; track.releaseDateOverride = nil; track.customImageFilename = nil
        }
        for artist in try context.fetch(FetchDescriptor<Artist>()) { artist.customImageFilename = nil }
        for item in try context.fetch(FetchDescriptor<AlbumImageOverride>()) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<FlaggedTrack>()) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<SavedConditionSet>()) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<SavedQuery>()) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<LinerNote>()) { context.delete(item) }
        for item in try context.fetch(FetchDescriptor<ToolFilterSetting>()) { context.delete(item) }
    }

    private static func readImages(named filenames: Set<String>) -> [String: Data] {
        let directory = ImageStore.customImagesDirectory()
        return filenames.reduce(into: [:]) { result, filename in
            result[filename] = try? Data(contentsOf: directory.appendingPathComponent(filename))
        }
    }

    private static func restoreImages(_ images: [String: Data]) throws {
        let directory = ImageStore.customImagesDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (filename, data) in images {
            let safeName = URL(fileURLWithPath: filename).lastPathComponent
            try data.write(to: directory.appendingPathComponent(safeName), options: .atomic)
        }
    }
}
