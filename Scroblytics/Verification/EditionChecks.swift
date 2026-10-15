import Foundation
import SwiftData

#if DEBUG
/// `SCROBLYTICS_EDITION_CHECK=1` (with `SCROBLYTICS_STORE_PATH` on a scratch path): an album edition counted on its own
/// (`AlbumEditionMatch`) — on made-up plays, how album groups split and merge, which group `findAlbumGroup` returns, which
/// match decision and Last.fm lookup each group uses, that each group's cycles count only its own plays, and that the choices
/// survive a backup. Exits 0 on success.
enum EditionChecks {
    @MainActor
    static func runHeadlessIfRequested(container: ModelContainer) {
        guard ProcessInfo.processInfo.environment["SCROBLYTICS_EDITION_CHECK"] != nil else { return }
        Task { @MainActor in
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: String = "") {
                print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty || ok ? "" : "  [\(detail)]"))
                if !ok { failures += 1 }
            }
            let context = container.mainContext
            let artist = "Artist A"
            let standard = "Album One"
            let deluxe = "Album One (25th Anniversary Edition)"
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)
            var clock = 0
            func play(_ album: String, _ track: String, artist: String = artist) -> ScrobbleSnapshot {
                clock += 1
                return ScrobbleSnapshot(artistName: artist, albumName: album, trackName: track, imageURL: nil, playedAt: t0.addingTimeInterval(Double(clock) * 60))
            }
            let core = ["T1", "T2", "T3", "T4"]
            let bonus = ["B1", "B2", "B3", "B4"]

            // The standard album is played through twice and the anniversary edition once, bonus tracks included.
            var plays: [ScrobbleSnapshot] = []
            for _ in 0..<2 { for t in core { plays.append(play(standard, t)) } }
            for t in core + bonus { plays.append(play(deluxe, t)) }
            let deluxeKey = TextNormalization.editionIdentityKey(artist: artist, album: deluxe)

            // MARK: Keys
            check("an edition's key keeps its edition words, and ignores case and spacing",
                  deluxeKey != TextNormalization.editionIdentityKey(artist: artist, album: standard)
                  && deluxeKey == TextNormalization.editionIdentityKey(artist: "ARTIST a", album: "  album one  (25TH Anniversary   Edition) "))
            check("the shared album key still treats the two as one album",
                  TextNormalization.albumIdentityKey(artist: artist, album: standard) == TextNormalization.albumIdentityKey(artist: artist, album: deluxe))

            // MARK: Groups
            let merged = AlbumTurnoverEngine.buildAlbumGroups(from: plays)
            check("by default the two editions are one album group of every play", merged.count == 1 && merged[0].scrobbles.count == 16 && merged[0].variants.count == 2 && merged[0].editionKey == nil)
            let explicitEmpty = AlbumTurnoverEngine.buildAlbumGroups(from: plays, separateEditions: [])
            check("an empty split set changes nothing", explicitEmpty.count == 1 && explicitEmpty[0].scrobbles.count == merged[0].scrobbles.count && explicitEmpty[0].displayName == merged[0].displayName && explicitEmpty[0].normalizedName == merged[0].normalizedName)

            let split = AlbumTurnoverEngine.buildAlbumGroups(from: plays, separateEditions: [deluxeKey])
            let standardGroup = split.first { $0.editionKey == nil }
            let deluxeGroup = split.first { $0.editionKey == deluxeKey }
            check("counting the anniversary edition on its own gives two groups", split.count == 2 && standardGroup != nil && deluxeGroup != nil)
            check("the standard album keeps its own 8 plays and only its own name", standardGroup?.scrobbles.count == 8 && standardGroup?.variants == [standard] && standardGroup?.displayName == standard)
            check("the edition has its own 8 plays under its exact name", deluxeGroup?.scrobbles.count == 8 && deluxeGroup?.variants == [deluxe] && deluxeGroup?.displayName == deluxe)
            check("together the two groups hold exactly the plays of the merged one", (standardGroup?.scrobbles.count ?? 0) + (deluxeGroup?.scrobbles.count ?? 0) == merged[0].scrobbles.count)
            check("each group's plays stay in time order", [standardGroup, deluxeGroup].allSatisfy { g in
                guard let g else { return false }
                return zip(g.scrobbles, g.scrobbles.dropFirst()).allSatisfy { $0.playedAt <= $1.playedAt }
            })
            if let standardGroup, let deluxeGroup {
                check("the two groups never share a cache key",
                      AlbumTurnoverEngine.groupKey(for: standardGroup) != AlbumTurnoverEngine.groupKey(for: deluxeGroup)
                      && AlbumTurnoverEngine.groupKey(for: standardGroup) == AlbumTurnoverEngine.groupKey(artist: artist, displayName: standard))
            }
            check("another album of the artist is left alone", {
                let other = plays + [play("Album Two", "X1"), play("Album Two", "X2")]
                let groups = AlbumTurnoverEngine.buildAlbumGroups(from: other, separateEditions: [deluxeKey])
                return groups.count == 3 && groups.first { $0.displayName == "Album Two" }?.editionKey == nil
            }())
            check("naming an edition that has no plays changes nothing", AlbumTurnoverEngine.buildAlbumGroups(from: plays, separateEditions: [TextNormalization.editionIdentityKey(artist: artist, album: "Elsewhere (Deluxe Edition)")]).count == 1)

            // Spelling variants of the one edition (case, spacing) stay together as that edition.
            let respelled = plays + [play("album one (25th ANNIVERSARY edition)", "T1"), play("Album One  (25th Anniversary Edition)", "T2")]
            let respelledSplit = AlbumTurnoverEngine.buildAlbumGroups(from: respelled, separateEditions: [deluxeKey])
            check("spelling variants of the separated edition join its group", respelledSplit.count == 2 && respelledSplit.first { $0.editionKey == deluxeKey }?.scrobbles.count == 10 && respelledSplit.first { $0.editionKey == deluxeKey }?.variants.count == 3, "\(respelledSplit.map { ($0.displayName, $0.scrobbles.count) })")

            // An edition scrobbled under no other name still becomes a group of its own.
            let onlyDeluxe = plays.filter { $0.albumName == deluxe }
            let lone = AlbumTurnoverEngine.buildAlbumGroups(from: onlyDeluxe, separateEditions: [deluxeKey])
            check("an edition with no sibling name is its own group, marked as separate", lone.count == 1 && lone[0].editionKey == deluxeKey && lone[0].scrobbles.count == 8)

            // MARK: Finding a group
            check("merged: either name finds the one group", {
                let a = AlbumTurnoverEngine.findAlbumGroup(merged, album: standard), b = AlbumTurnoverEngine.findAlbumGroup(merged, album: deluxe)
                return a != nil && b != nil && a?.scrobbles.count == 16 && b?.scrobbles.count == 16
            }())
            check("split: each exact name finds its own group", {
                let a = AlbumTurnoverEngine.findAlbumGroup(split, album: standard), b = AlbumTurnoverEngine.findAlbumGroup(split, album: deluxe)
                return a?.editionKey == nil && a?.displayName == standard && b?.editionKey == deluxeKey
            }())
            check("split: a respelled edition name still finds the edition", AlbumTurnoverEngine.findAlbumGroup(split, album: " ALBUM ONE (25th  anniversary edition)")?.editionKey == deluxeKey)
            check("split: an unrelated name finds nothing", AlbumTurnoverEngine.findAlbumGroup(split, album: "Nope") == nil)

            // MARK: Which tracklist each group asks Last.fm for
            if let standardGroup, let deluxeGroup {
                let standardAsk = AlbumTurnoverEngine.tracklistRequest(group: standardGroup, resolution: nil)
                let deluxeAsk = AlbumTurnoverEngine.tracklistRequest(group: deluxeGroup, resolution: nil)
                check("an automatic standard album asks for its plain title", standardAsk?.album == standard)
                check("an automatic separate edition asks for its exact title, edition words kept", deluxeAsk?.album == deluxe, deluxeAsk?.album ?? "nil")
                check("a merged group still asks for the plain release (edition words dropped)", AlbumTurnoverEngine.tracklistRequest(group: merged[0], resolution: nil)?.album == "Album One" || AlbumTurnoverEngine.tracklistRequest(group: merged[0], resolution: nil)?.album == TextNormalization.stripEditionSuffix(merged[0].displayName))
                check("a confirmed Last.fm album is used as saved, whatever the group", AlbumTurnoverEngine.tracklistRequest(group: deluxeGroup, resolution: .canonical(canonicalArtist: "C", canonicalAlbum: "D"))?.album == "D")

                // MARK: Cycles count only the group's own plays against its own list
                let standardList = AlbumTracklist(album: standard, artist: artist, tracks: core)
                let deluxeList = AlbumTracklist(album: deluxe, artist: artist, tracks: core + bonus)
                var snapshot = AlbumTurnoverEngine.Snapshot()
                snapshot.separateEditions = [deluxeKey]
                snapshot.tracklists[AlbumTurnoverEngine.tracklistCacheKey(artist: artist, album: standard)] = .found(standardList)
                snapshot.tracklists[AlbumTurnoverEngine.tracklistCacheKey(artist: artist, album: deluxe)] = .found(deluxeList)
                var standardTurnover: AlbumTurnoverEngine.AlbumTurnover?
                var deluxeTurnover: AlbumTurnoverEngine.AlbumTurnover?
                if case .value(let t) = snapshot.lookup(for: standardGroup) { standardTurnover = t }
                if case .value(let t) = snapshot.lookup(for: deluxeGroup) { deluxeTurnover = t }
                check("the standard album: its 4-track list, two full cycles", standardTurnover?.trackCount == 4 && standardTurnover?.cyclesCompleted == 2, "\(String(describing: standardTurnover?.trackCount)) / \(String(describing: standardTurnover?.cyclesCompleted))")
                check("the edition: its 8-track list, one full cycle, a fresh one started", deluxeTurnover?.trackCount == 8 && deluxeTurnover?.cyclesCompleted == 1 && deluxeTurnover?.inProgressHeard == 0, "\(String(describing: deluxeTurnover?.trackCount)) / \(String(describing: deluxeTurnover?.cyclesCompleted))")
                check("each group's result carries its own cache key", standardTurnover?.groupKey != deluxeTurnover?.groupKey)
                // Merged, the bonus tracks and the shorter list disagree: the old behaviour this replaces for an edition set apart.
                var mergedSnapshot = AlbumTurnoverEngine.Snapshot()
                mergedSnapshot.tracklists[AlbumTurnoverEngine.tracklistCacheKey(artist: artist, album: "Album One")] = .found(AlbumTracklist(album: "Album One", artist: artist, tracks: core))
                if case .value(let t) = mergedSnapshot.lookup(for: merged[0]) {
                    check("merged (unchanged): the 4-track list does not fit the 8 tracks played, so the match is uncertain", t.ambiguous && t.basis == .observed && t.trackCount == 8, "\(t.ambiguous) / \(t.basis) / \(t.trackCount)")
                } else {
                    check("merged (unchanged): the 4-track list does not fit the 8 tracks played, so the match is uncertain", false, "no turnover")
                }
                check("the snapshot's decision for an edition ignores the shared album's", {
                    var s = snapshot
                    s.resolutions[TextNormalization.albumIdentityKey(artist: artist, album: standard)] = .observed
                    s.editionResolutions[deluxeKey] = .manual(tracks: ["B1", "B2"])
                    if case .observed? = s.resolution(for: standardGroup), case .manual(let tracks)? = s.resolution(for: deluxeGroup) { return tracks == ["B1", "B2"] }
                    return false
                }())
                check("an edition with no saved decision of its own has none (it never borrows the shared one)", {
                    var s = snapshot
                    s.resolutions[TextNormalization.albumIdentityKey(artist: artist, album: standard)] = .observed
                    return s.resolution(for: deluxeGroup) == nil && s.resolution(for: standardGroup) != nil
                }())
            }

            // MARK: Saved decisions, through the real store
            let albumKey = TextNormalization.albumIdentityKey(artist: artist, album: standard)
            func cleanUp() {
                for item in (try? context.fetch(FetchDescriptor<AlbumEditionMatch>())) ?? [] { context.delete(item) }
                for item in (try? context.fetch(FetchDescriptor<Album>(predicate: #Predicate { $0.identityKey == albumKey }))) ?? [] { context.delete(item) }
                try? context.save()
            }
            cleanUp()
            let album = Album(identityKey: albumKey, title: standard, normalizedTitle: TextNormalization.normalizeAlbumName(standard), artist: nil)
            album.matchResolutionMode = .canonical
            album.canonicalArtist = "Artist A"
            album.canonicalAlbum = "Album One"
            context.insert(album)
            let edition = AlbumEditionMatch(editionKey: deluxeKey, artist: artist, title: deluxe)
            context.insert(edition)
            try? context.save()
            if let standardGroup, let deluxeGroup {
                if case .canonical(_, let name)? = AlbumTurnoverEngine.storedResolution(context: context, group: standardGroup) { check("the standard album reads the shared decision", name == "Album One") } else { check("the standard album reads the shared decision", false) }
                check("the edition does NOT read the shared decision (its own is automatic)", AlbumTurnoverEngine.storedResolution(context: context, group: deluxeGroup) == nil)
                edition.matchResolutionMode = .manual
                edition.manualTracklist = core + bonus
                try? context.save()
                if case .manual(let tracks)? = AlbumTurnoverEngine.storedResolution(context: context, group: deluxeGroup) { check("the edition reads its own saved tracklist", tracks.count == 8) } else { check("the edition reads its own saved tracklist", false) }
                check("the edition's saved decision leaves the standard album's alone", { if case .canonical? = AlbumTurnoverEngine.storedResolution(context: context, group: standardGroup) { return true } else { return false } }())
                // A merged group never sees the edition's row.
                if case .canonical? = AlbumTurnoverEngine.storedResolution(context: context, group: merged[0]) { check("a merged group reads only the shared decision", true) } else { check("a merged group reads only the shared decision", false) }
            }
            check("the separated-edition keys come from the store", AlbumTurnoverEngine.separateEditionKeys(context: context) == [deluxeKey])
            let loaded = AlbumTurnoverEngine.loadSnapshot(context: context)
            check("the cache snapshot carries the keys and the edition's decision", loaded.separateEditions == [deluxeKey] && { if case .manual? = loaded.editionResolutions[deluxeKey] { return true } else { return false } }())
            check("the group cache follows the split set", {
                let cache = TurnoverGroupCache()
                let before = cache.groups(for: plays)[artist]?.count
                let after = cache.groups(for: plays, separating: [deluxeKey])[artist]?.count
                let back = cache.groups(for: plays)[artist]?.count
                return before == 1 && after == 2 && back == 1
            }())

            // MARK: Backup
            if let document = try? NativeBackupEngine.makeDocument(context: context), let (archive, summary) = try? NativeBackupEngine.inspect(document: document) {
                check("a backup carries the edition and its decision", archive.albumEditionMatches?.count == 1 && archive.albumEditionMatches?.first?.matchMode == "manual" && archive.albumEditionMatches?.first?.manualTracklist?.count == 8)
                check("and its summary says so", summary.description.contains("1 editions counted separately"), summary.description)
                for item in (try? context.fetch(FetchDescriptor<AlbumEditionMatch>())) ?? [] { context.delete(item) }
                try? context.save()
                try? NativeBackupEngine.restoreAlbumEditionMatches(archive.albumEditionMatches, context: context)
                let restored = (try? context.fetch(FetchDescriptor<AlbumEditionMatch>())) ?? []
                check("restoring brings the edition back with its decision", restored.count == 1 && restored.first?.editionKey == deluxeKey && restored.first?.matchResolutionMode == .manual && restored.first?.manualTracklist == core + bonus)
                try? NativeBackupEngine.restoreAlbumEditionMatches(nil, context: context)
                check("an older backup (no field) leaves the editions alone", ((try? context.fetch(FetchDescriptor<AlbumEditionMatch>())) ?? []).count == 1)
                try? NativeBackupEngine.restoreAlbumEditionMatches([], context: context)
                check("a backup with none clears them", ((try? context.fetch(FetchDescriptor<AlbumEditionMatch>())) ?? []).isEmpty)
                check("and with the row gone the two editions merge again", AlbumTurnoverEngine.buildAlbumGroups(from: plays, separateEditions: AlbumTurnoverEngine.separateEditionKeys(context: context)).count == 1)
            } else {
                check("a backup can be made and read back", false)
            }

            // MARK: The Fix album match engine
            cleanUp()
            let shared = Album(identityKey: albumKey, title: standard, normalizedTitle: TextNormalization.normalizeAlbumName(standard), artist: nil)
            context.insert(shared)
            context.insert(AlbumTurnoverCompletionCache(computedForSyncAt: nil, computedAt: Date(), completionsJSON: Data()))
            try? context.save()
            if let mergedGroup = merged.first, let standardGroup, let deluxeGroup {
                // Counting the edition on its own: a row, no change to the shared album, the cached completions dropped.
                let key = try? AlbumMatchFixEngine.separateEdition(context: context, artist: artist, album: deluxe)
                check("separating an edition stores its row under the exact-name key", key == deluxeKey && AlbumTurnoverEngine.separateEditionKeys(context: context) == [deluxeKey])
                check("it is idempotent", ((try? AlbumMatchFixEngine.separateEdition(context: context, artist: artist, album: deluxe)) == deluxeKey) && ((try? context.fetch(FetchDescriptor<AlbumEditionMatch>()))?.count == 1))
                check("it drops the cached completion dates, so Overview follows the new grouping", ((try? context.fetch(FetchDescriptor<AlbumTurnoverCompletionCache>()))?.isEmpty) == true)
                check("the shared album is untouched", shared.matchResolutionMode == nil)

                // A decision on the edition's group goes to its own row; one on the standard group goes to the shared album.
                try? AlbumMatchFixEngine.applyCanonical(context: context, group: deluxeGroup, canonicalArtist: artist, canonicalAlbum: deluxe)
                let editionRow = try? AlbumMatchFixEngine.findEdition(context: context, key: deluxeKey)
                check("a match chosen for the edition lands on its row only", editionRow?.matchResolutionMode == .canonical && editionRow?.canonicalAlbum == deluxe && shared.matchResolutionMode == nil)
                try? AlbumMatchFixEngine.applyManual(context: context, group: standardGroup, tracks: core)
                check("a match chosen for the standard album lands on the shared album only", shared.matchResolutionMode == .manual && shared.manualTracklist == core && editionRow?.matchResolutionMode == .canonical)
                try? AlbumMatchFixEngine.applyObserved(context: context, group: deluxeGroup)
                check("observed tracks for the edition clear its other fields", editionRow?.matchResolutionMode == .observed && editionRow?.canonicalAlbum == nil && editionRow?.manualTracklist == nil)
                try? AlbumMatchFixEngine.resetToAutomatic(context: context, group: deluxeGroup)
                check("resetting the edition keeps it separate, with an automatic match", editionRow?.matchResolutionMode == nil && ((try? AlbumMatchFixEngine.findEdition(context: context, key: deluxeKey)) ?? nil) != nil && shared.matchResolutionMode == .manual)
                try? AlbumMatchFixEngine.applyObserved(context: context, group: deluxeGroup)
                // Merged group (never separate) still writes to the shared album as before.
                try? AlbumMatchFixEngine.resetToAutomatic(context: context, group: mergedGroup)
                check("resetting the merged album clears the shared decision and leaves the edition's own", shared.matchResolutionMode == nil && editionRow?.matchResolutionMode == .observed)
                // Merging it back deletes the row and its decision.
                try? AlbumMatchFixEngine.rejoinEdition(context: context, key: deluxeKey)
                check("merging the edition back stops counting it separately, drops its decision, and keeps it on record as reviewed", AlbumTurnoverEngine.separateEditionKeys(context: context).isEmpty
                      && AlbumTurnoverEngine.loadSnapshot(context: context).reviewedEditions == [deluxeKey] && editionRow?.matchResolutionMode == nil)
                check("and the two editions are one album again", AlbumTurnoverEngine.buildAlbumGroups(from: plays, separateEditions: AlbumTurnoverEngine.separateEditionKeys(context: context)).count == 1)
                check("writing to an edition that isn't set apart is refused", { () -> Bool in
                    do { try AlbumMatchFixEngine.applyObserved(context: context, group: deluxeGroup); return false } catch { return true }
                }())
            }
            cleanUp()
            for item in (try? context.fetch(FetchDescriptor<AlbumTurnoverCompletionCache>())) ?? [] { context.delete(item) }
            try? context.save()

            cleanUp()
            print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }
}
#endif
