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

            // MARK: The Merged Editions finder (Query fields and the Missing Data field)
            cleanUp()
            do {
                let base = "Disc One", special = "Disc One (Anniversary Edition)"
                let specialKey = TextNormalization.editionIdentityKey(artist: artist, album: special)
                let baseAlbumKey = TextNormalization.albumIdentityKey(artist: artist, album: base)
                func library(extra: Int) -> [ScrobbleSnapshot] {
                    var out: [ScrobbleSnapshot] = []
                    for _ in 0..<2 { for t in core { out.append(play(base, t)) } }
                    for t in core + bonus.prefix(extra) { out.append(play(special, t)) }
                    return out
                }
                /// The turnover snapshot the app would have after "Fix album match…" confirmed the base album's list.
                func snapshot(list: Bool = true, confirmed: Bool = true, separate: Bool = false, reviewed: Bool = false) -> AlbumTurnoverEngine.Snapshot {
                    var snap = AlbumTurnoverEngine.Snapshot()
                    if confirmed { snap.resolutions[baseAlbumKey] = .canonical(canonicalArtist: artist, canonicalAlbum: base) }
                    if list { snap.tracklists[AlbumTurnoverEngine.tracklistCacheKey(artist: artist, album: base)] = .found(AlbumTracklist(album: base, artist: artist, tracks: core)) }
                    if separate {
                        snap.separateEditions = [specialKey]
                        snap.editionResolutions[specialKey] = .canonical(canonicalArtist: artist, canonicalAlbum: special)
                        snap.tracklists[AlbumTurnoverEngine.tracklistCacheKey(artist: artist, album: special)] = .found(AlbumTracklist(album: special, artist: artist, tracks: core + bonus))
                    }
                    if reviewed { snap.reviewedEditions = [specialKey] }
                    return snap
                }
                struct Values { var names: Double?; var off: Double?; var review: Bool?; var offState = ""; var reviewState = "" }
                func evaluate(_ plays: [ScrobbleSnapshot], _ snap: AlbumTurnoverEngine.Snapshot) -> [String: Values] {
                    var spec = QuerySpec(target: .album)
                    spec.columns = [QueryFieldRef("albumEditionNames"), QueryFieldRef("albumOffListTracks"), QueryFieldRef("mergedEditionReview")]
                    guard let validated = try? spec.validate(against: .standard) else { return [:] }
                    let run = QueryRun(target: .album, asOf: Date(), scrobbles: plays, allTimeScrobbles: plays, snapshots: QuerySnapshots(turnover: snap, turnoverGroups: TurnoverGroupCache()))
                    let result = QueryEngine.evaluate(validated, run: run)
                    func key(_ id: String) -> String? { result.columns.first { $0.field.id == id }?.cacheKey }
                    var out: [String: Values] = [:]
                    for row in result.rows {
                        var v = Values()
                        if let k = key("albumEditionNames"), case .value(.number(let n))? = row.cells[k] { v.names = n }
                        if let k = key("albumOffListTracks") {
                            switch row.cells[k] { case .value(.number(let n))?: v.off = n; case .pending?: v.offState = "pending"; default: v.offState = "missing" }
                        }
                        if let k = key("mergedEditionReview") {
                            switch row.cells[k] { case .value(.bool(let b))?: v.review = b; case .pending?: v.reviewState = "pending"; default: v.reviewState = "missing" }
                        }
                        out[row.entity.id.name] = v
                    }
                    return out
                }

                let withBonus = library(extra: 4)
                let merged = evaluate(withBonus, snapshot())
                check("merged: the base name counts 2 edition names, no off-list tracks, not flagged", merged[base]?.names == 2 && merged[base]?.off == 0 && merged[base]?.review == false, "\(String(describing: merged[base]))")
                check("merged: the edition with 4 bonus tracks has 4 off-list tracks and is flagged", merged[special]?.names == 2 && merged[special]?.off == 4 && merged[special]?.review == true, "\(String(describing: merged[special]))")
                check("threshold: 3 off-list tracks flag it", evaluate(library(extra: 3), snapshot())[special]?.review == true)
                check("threshold: 2 off-list tracks do not", evaluate(library(extra: 2), snapshot())[special]?.review == false)
                check("an edition with nothing extra is not flagged", evaluate(library(extra: 0), snapshot())[special]?.review == false)

                let pending = evaluate(withBonus, snapshot(list: false))
                check("tracklist not cached yet: off-list and the flag are pending for both names", pending[base]?.reviewState == "pending" && pending[special]?.reviewState == "pending" && pending[special]?.offState == "pending")
                check("tracklist not cached yet: the edition count still answers", pending[special]?.names == 2)
                let observedOnly = evaluate(withBonus, snapshot(confirmed: false))
                check("no real tracklist (an unconfirmed, uncertain match): no off-list count and not flagged", observedOnly[special]?.off == nil && observedOnly[special]?.review == false, "\(String(describing: observedOnly[special]))")

                let apart = evaluate(withBonus, snapshot(separate: true))
                check("counted on its own: each name counts 1, the edition is not flagged and has none off its own list", apart[special]?.names == 1 && apart[special]?.review == false && apart[special]?.off == 0 && apart[base]?.names == 1, "\(String(describing: apart[special]))")
                let kept = evaluate(withBonus, snapshot(reviewed: true))
                check("kept merged: still counted together, but never flagged", kept[special]?.names == 2 && kept[special]?.review == false && kept[special]?.off == 4)
                let alone = evaluate(Array(withBonus.filter { $0.albumName == base }), snapshot())
                check("an album with one name counts 1 and is never flagged", alone[base]?.names == 1 && alone[base]?.review == false)

                // Missing Data lists exactly the flagged edition names, with a plain reason.
                guard let field = MissingDataField.all.first(where: { $0.id == "mergedEditions" }) else { check("Merged Editions is a Missing Data field", false); print("1 CHECK(S) FAILED"); exit(1) }
                func missing(_ plays: [ScrobbleSnapshot], _ snap: AlbumTurnoverEngine.Snapshot) -> MissingDataResult? {
                    MissingDataEngine.compute(field: field, target: .album, scrobbles: plays, snapshots: QuerySnapshots(turnover: snap, turnoverGroups: TurnoverGroupCache()))
                }
                let list = missing(withBonus, snapshot())
                check("Missing Data lists only the bonus-heavy edition, as confirmed", list?.rows.map(\.name) == [special] && list?.rows.first?.bucket == .missing && list?.universeCount == 2, "\(String(describing: list?.rows.map(\.name)))")
                check("and says why", list?.rows.first?.detail == "4 played tracks aren’t on the album’s tracklist · counted with 1 other edition name", list?.rows.first?.detail ?? "nil")
                check("not yet looked up: both names are listed as not yet checked", Set(missing(withBonus, snapshot(list: false))?.rows.map(\.name) ?? []) == [base, special] && missing(withBonus, snapshot(list: false))?.pendingCount == 2)
                check("counted on its own or kept merged: the list is empty", missing(withBonus, snapshot(separate: true))?.rows.isEmpty == true && missing(withBonus, snapshot(reviewed: true))?.rows.isEmpty == true)
                check("the Advanced hand-off asks for the flag and carries the explaining columns", MissingDataEngine.advancedSpec(field: field, target: .album).columns.map(\.id) == ["mergedEditionReview", "albumOffListTracks", "albumEditionNames"])

                // Remembering the review: through the real store and a backup.
                try? AlbumMatchFixEngine.keepMerged(context: context, artist: artist, album: special)
                check("keep merged records the name as reviewed, not separate", AlbumTurnoverEngine.separateEditionKeys(context: context).isEmpty && AlbumTurnoverEngine.loadSnapshot(context: context).reviewedEditions == [specialKey])
                check("and the loaded snapshot keeps it out of the finder", missing(withBonus, AlbumTurnoverEngine.loadSnapshot(context: context))?.rows.contains { $0.name == special } == false)
                if let document = try? NativeBackupEngine.makeDocument(context: context), let (archive, summary) = try? NativeBackupEngine.inspect(document: document) {
                    check("a backup carries the reviewed edition and does not count it as separate", archive.albumEditionMatches?.first?.countsSeparately == false && !summary.description.contains("editions counted separately"), summary.description)
                    for item in (try? context.fetch(FetchDescriptor<AlbumEditionMatch>())) ?? [] { context.delete(item) }
                    try? context.save()
                    try? NativeBackupEngine.restoreAlbumEditionMatches(archive.albumEditionMatches, context: context)
                    check("restoring brings back the review", AlbumTurnoverEngine.loadSnapshot(context: context).reviewedEditions == [specialKey])
                    let oldStyle = NativeBackupFormat.AlbumEditionMatchRecord(artist: artist, title: special, matchMode: nil, canonicalArtist: nil, canonicalAlbum: nil, manualTracklist: nil)
                    try? NativeBackupEngine.restoreAlbumEditionMatches([oldStyle], context: context)
                    check("a record without the field (an older backup) means counted separately", AlbumTurnoverEngine.separateEditionKeys(context: context) == [specialKey])
                } else {
                    check("a backup can be made and read back", false)
                }
                _ = try? AlbumMatchFixEngine.keepMerged(context: context, artist: artist, album: special)
                _ = try? AlbumMatchFixEngine.separateEdition(context: context, artist: artist, album: special)
                check("choosing to count a reviewed edition on its own turns it back on", AlbumTurnoverEngine.separateEditionKeys(context: context) == [specialKey] && AlbumTurnoverEngine.loadSnapshot(context: context).reviewedEditions.isEmpty)
            }

            cleanUp()
            HeadlessTask.finish(failures)
        }
    }
}
#endif
