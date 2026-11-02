import Foundation
import SwiftData

#if DEBUG
/// `SCROBLYTICS_BACKUPCOVERAGE_CHECK=1`: every model in the database is either written to a backup or deliberately left out because it can
/// be rebuilt, and nothing is classified twice or not at all. Adding a model to `AppSchema` without deciding which fails here, as does a
/// backup field no model accounts for. Exits 0 on success.
enum BackupCoverageChecks {
    enum Coverage {
        /// Written to the backup, in these fields of the archive.
        case backedUp([String])
        /// Not in a backup, because it comes back by syncing or by looking it up again.
        case rebuildable(String)
    }

    /// Every model, by type name. A new model must be added here with its decision.
    static let models: [String: Coverage] = [
        // What you created
        "Artist": .backedUp(["artistImages"]),
        "Album": .backedUp(["albums"]),
        "Track": .backedUp(["tracks"]),
        "AlbumImageOverride": .backedUp(["albumImages"]),
        "FlaggedTrack": .backedUp(["flaggedTracks"]),
        "SavedQuery": .backedUp(["legacySavedQueries"]),
        "SavedConditionSet": .backedUp(["savedConditionSets"]),
        "LinerNote": .backedUp(["linerNotes"]),
        "ToolFilterSetting": .backedUp(["toolFilters"]),
        "AppSettings": .backedUp(["theme"]),
        "LibraryGapDismissal": .backedUp(["dismissedLibraryGaps"]),
        "LovedAuditDecision": .backedUp(["lovedAuditDecisions"]),
        "ReleaseYearDecision": .backedUp(["releaseYearDecisions"]),
        "AlbumEditionMatch": .backedUp(["albumEditionMatches"]),
        "TagPlaylistRule": .backedUp(["tagRules"]),
        "AutoPlaylist": .backedUp(["autoPlaylists"]),
        // What comes back by syncing or looking it up again
        "Scrobble": .rebuildable("the listening history is imported again from Last.fm"),
        "SyncState": .rebuildable("where the import stands on this Mac"),
        "AlbumTracklistCacheEntry": .rebuildable("looked up again"),
        "ReverbPoolCache": .rebuildable("computed again"),
        "AlbumTurnoverCompletionCache": .rebuildable("computed again"),
        "TrackDurationCacheEntry": .rebuildable("looked up again"),
        "TrackBPMCacheEntry": .rebuildable("looked up again"),
        "SimilarityLookupCacheEntry": .rebuildable("looked up again"),
        "LovedTrackEntry": .rebuildable("loved tracks are read again from Last.fm"),
        "EntityCommunityTagCacheEntry": .rebuildable("looked up again"),
        "UserEntityTagCacheEntry": .rebuildable("your tags are read again from Last.fm"),
        "PersonalTagSyncState": .rebuildable("where the tag import stands on this Mac"),
        "TrackReleaseDateCacheEntry": .rebuildable("looked up again"),
        "PopularityCacheEntry": .rebuildable("looked up again"),
        "LibraryPresenceEntry": .rebuildable("read again from Music"),
        "LibraryPresenceCheck": .rebuildable("read again from Music"),
    ]

    /// Parts of the archive that are not a model's records: its header, the image files, and the weather places (a file, not a model).
    static let otherFields: Set<String> = ["format", "formatVersion", "createdAt", "appVersion", "username", "images", "weatherLocations"]

    @MainActor
    static func runHeadlessIfRequested() {
        guard ProcessInfo.processInfo.environment["SCROBLYTICS_BACKUPCOVERAGE_CHECK"] != nil else { return }
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty || ok ? "" : "  [\(detail)]"))
            if !ok { failures += 1 }
        }

        let schemaNames = AppSchema.modelTypes.map { String(describing: $0) }
        check("no model is listed twice in the schema", Set(schemaNames).count == schemaNames.count)
        let unclassified = schemaNames.filter { models[$0] == nil }
        check("every model is classified as backed up or rebuildable", unclassified.isEmpty,
              "not classified: \(unclassified.joined(separator: ", ")). Decide whether it holds something you created: if so add a record to the backup (NativeBackup.swift), else say why it can be rebuilt")
        let stale = models.keys.filter { !schemaNames.contains($0) }
        check("every classification names a model that exists", stale.isEmpty, "no such model: \(stale.sorted().joined(separator: ", "))")

        do {
            let container = try ModelContainer(for: Schema(AppSchema.modelTypes), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            let document = try NativeBackupEngine.makeDocument(context: container.mainContext)
            let archive = try NativeBackupEngine.inspect(document: document).0
            let fields = Set(Mirror(reflecting: archive).children.compactMap(\.label))
            var claimed = otherFields
            var missing: [String] = []
            for (name, coverage) in models {
                if case .backedUp(let names) = coverage {
                    for field in names { claimed.insert(field); if !fields.contains(field) { missing.append("\(name) → \(field)") } }
                }
            }
            check("every backed-up model's field exists in the archive", missing.isEmpty, missing.sorted().joined(separator: ", "))
            let unaccounted = fields.subtracting(claimed)
            check("every field of the archive belongs to a model or is part of the header", unaccounted.isEmpty, "no model claims: \(unaccounted.sorted().joined(separator: ", "))")
            let encoded = try JSONSerialization.jsonObject(with: document.data) as? [String: Any] ?? [:]
            let kept = ["albums", "tracks", "flaggedTracks", "toolFilters", "autoPlaylists", "releaseYearDecisions", "albumEditionMatches", "lovedAuditDecisions", "tagRules"]
            check("a backup of an empty database still writes the lists the restore replaces", kept.allSatisfy { encoded[$0] != nil }, kept.filter { encoded[$0] == nil }.joined(separator: ", "))
        } catch {
            check("an empty database can be backed up", false, "\(error)")
        }

        print(failures == 0 ? "ALL BACKUP COVERAGE CHECKS PASSED (\(schemaNames.count) models)" : "\(failures) CHECK(S) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
#endif
