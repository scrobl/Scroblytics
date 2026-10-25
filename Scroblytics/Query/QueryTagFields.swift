import Foundation

/// Tag fields, wrapping the tag caches `EntityTagsEngine` keeps (artist community tags, album/track
/// community tags, and the user's own tags), read through `EntityTagsSnapshot` — whose resolution
/// rules are:
/// - **community tags** are the entity's own when it has any, otherwise its artist's;
/// - **personal tags** are the user's tags on the entity, its album and its artist;
/// - **Tags** is the two combined; **My tags** is just the personal part.
extension QueryFieldRegistry {
    private static func tagKind(_ target: QueryTarget) -> TopChartsEntity {
        switch target {
        case .artist: .artist
        case .album: .album
        case .track, .scrobble, .session: .track
        }
    }

    /// Both fields' per-entity inputs, so they resolve entities identically. `community` is nil while
    /// the lookup it needs hasn't happened; `personal` is nil until personal tags have been synced.
    private static func tagInputs(
        _ run: QueryRun, _ entity: QueryEntity
    ) -> (community: [String]?, personal: [String]?) {
        let snapshot = run.snapshots.entityTags
        let kind = tagKind(entity.target)
        let name: String? = kind == .artist ? nil : entity.name
        return (
            snapshot.communityTags(kind: kind, artist: entity.artist, name: name),
            snapshot.personalTags(kind: kind, artist: entity.artist, name: name, album: run.universe.aggregates[entity.id]?.album)
        )
    }

    private static func tagCell(_ tags: [String]) -> QueryCell {
        // No tags at all is absent, not "has zero tags to match".
        tags.isEmpty ? .missing : .value(.tags(normalizing: tags))
    }

    static let tagFields: [QueryField] = [
        QueryField(
            id: "tags", name: "Tags", group: .tags, type: .tags, targets: [.artist, .album, .track],
            column: .standard(for: .tags, width: 240),
            help: "Last.fm community tags plus your own. An album or track uses its own community tags, or its artist’s when it has none; your tags count from the item itself, its album and its artist. Needs those tags looked up first: an item not looked up yet matches neither a tag test nor “is missing”.",
            isBackgroundResolved: true, resolver: .tags
        ) { run, _, entities in
            Dictionary(uniqueKeysWithValues: entities.map { entity in
                let (community, personal) = tagInputs(run, entity)
                guard let community, let personal else { return (entity.id, .pending) }
                return (entity.id, tagCell(community + personal))
            })
        },
        QueryField(
            id: "myTags", name: "My tags", group: .tags, type: .tags, targets: [.artist, .album, .track],
            column: .standard(for: .tags, width: 200),
            help: "Only the tags you’ve put on it, its album or its artist on Last.fm — not community tags. Needs your tags synced first.",
            isBackgroundResolved: true, resolver: .tags
        ) { run, _, entities in
            Dictionary(uniqueKeysWithValues: entities.map { entity in
                guard let personal = tagInputs(run, entity).personal else { return (entity.id, .pending) }
                return (entity.id, tagCell(personal))
            })
        },
    ]
}
