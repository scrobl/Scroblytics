import Foundation
import SwiftData

extension Notification {
    /// The names of the kinds of record (`Scrobble`, `Album`…) that a `ModelContext.didSave` notification says were inserted, updated
    /// or deleted; empty for any other notification.
    ///
    /// The lists of changed records sit under the plain strings "inserted", "updated" and "deleted" in `userInfo`. Looking them up with a
    /// `ModelContext.NotificationKey` finds nothing (a Swift enum is not equal to a string key once boxed as a dictionary key), so they
    /// are read here. The automatic playlists use this. Top Charts, Library and the artist track list still decide from a save with the
    /// typed lookup, which never matches, so their "ignore unrelated saves" filters have not been doing anything; switching them to this
    /// would make them reload on every save of plays, artists, albums or tracks (every page of a sync), which needs looking at first.
    /// A key given as a `NotificationKey` is accepted too, in case another system version stores them that way.
    var savedEntityNames: Set<String> {
        let changeKeys: Set<String> = [
            ModelContext.NotificationKey.insertedIdentifiers.rawValue,
            ModelContext.NotificationKey.updatedIdentifiers.rawValue,
            ModelContext.NotificationKey.deletedIdentifiers.rawValue,
        ]
        var names: Set<String> = []
        for (key, value) in userInfo ?? [:] {
            guard let name = (key.base as? String) ?? (key.base as? ModelContext.NotificationKey)?.rawValue, changeKeys.contains(name),
                  let identifiers = value as? [PersistentIdentifier] else { continue }
            for identifier in identifiers { names.insert(identifier.entityName) }
        }
        return names
    }

    /// Whether a `ModelContext.didSave` notification touched any of the given kinds of record.
    func savedAnyEntity(in entityNames: Set<String>) -> Bool {
        !savedEntityNames.isDisjoint(with: entityNames)
    }
}
