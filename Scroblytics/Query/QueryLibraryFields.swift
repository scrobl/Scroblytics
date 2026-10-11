import Foundation
import SwiftData

/// A read-only copy of the saved Apple Music library status (`LibraryPresenceEntry`, written by the Library Gaps
/// tool), keyed by `LibraryGapsEngine.key`. A track with NO entry has never been checked — the fields answer
/// "unknown", never "not in the library".
struct LibraryPresenceSnapshot: Sendable {
    struct Entry: Sendable {
        let inLibrary: Bool
        /// Not under this title, but Music has a close variant — counted as in the library by the field.
        let hasNearMatch: Bool
        let lastSeenAt: Date?
    }

    var entries: [String: Entry] = [:]
    var checkedAt: Date?

    static let empty = LibraryPresenceSnapshot()

    static func load(context: ModelContext) -> LibraryPresenceSnapshot {
        var snapshot = LibraryPresenceSnapshot()
        for entry in (try? context.fetch(FetchDescriptor<LibraryPresenceEntry>())) ?? [] {
            snapshot.entries[entry.matchKey] = Entry(inLibrary: entry.inLibrary, hasNearMatch: entry.nearMatch != nil, lastSeenAt: entry.lastSeenAt)
        }
        snapshot.checkedAt = (try? context.fetch(FetchDescriptor<LibraryPresenceCheck>()))?.first?.checkedAt
        return snapshot
    }
}

/// Whether a scrobbled track is in the Apple Music library, as of the last "Check library" run in Library Gaps.
extension QueryFieldRegistry {
    static let libraryFields: [QueryField] = [
        QueryField(
            id: "inAppleLibrary", name: "In Apple Music library", group: .flags, type: .boolean, targets: [.track],
            column: QueryColumnSpec(alignment: .center, style: .boolean, width: 150),
            help: "Whether the track is in your Apple Music library, as of the last check in the Library Gaps tool. A track with a near-identical title or credit in the library counts as in it. Tracks that haven’t been checked have no value."
        ) { run, _, entities in
            let presence = run.snapshots.libraryPresence
            return Dictionary(uniqueKeysWithValues: entities.map { entity in
                guard let entry = presence.entries[LibraryGapsEngine.key(artist: entity.artist, track: entity.name)] else { return (entity.id, .missing) }
                return (entity.id, .value(.bool(entry.inLibrary || entry.hasNearMatch)))
            })
        },
        QueryField(
            id: "removedFromAppleLibrary", name: "Removed from Apple Music library", group: .flags, type: .date, targets: [.track],
            column: .standard(for: .date),
            help: "When the track was last seen in your Apple Music library, for tracks that were there at an earlier check and aren’t now. Empty for tracks that are in the library or were never seen there."
        ) { run, _, entities in
            let presence = run.snapshots.libraryPresence
            return Dictionary(uniqueKeysWithValues: entities.map { entity in
                guard let entry = presence.entries[LibraryGapsEngine.key(artist: entity.artist, track: entity.name)],
                      !entry.inLibrary, !entry.hasNearMatch, let lastSeen = entry.lastSeenAt else { return (entity.id, .missing) }
                return (entity.id, .value(.date(lastSeen)))
            })
        },
    ]
}
