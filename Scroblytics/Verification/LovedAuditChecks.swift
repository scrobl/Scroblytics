import Foundation
import SwiftData

#if DEBUG
/// `SCROBLYTICS_LOVEDAUDIT_CHECK=1` (with `SCROBLYTICS_STORE_PATH` on a scratch path): the Loved Status Audit's decisions
/// and its "loved, no scrobbles" count, on made-up data. Each kind of Uncertain row is resolved by "same track" and by
/// "different tracks", the decisions don't touch unrelated tracks, and decisions survive a backup round trip.
enum LovedAuditChecks {
    @MainActor
    static func runHeadlessIfRequested(container: ModelContainer) {
        guard ProcessInfo.processInfo.environment["SCROBLYTICS_LOVEDAUDIT_CHECK"] != nil else { return }
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty || ok ? "" : "  [\(detail)]"))
            if !ok { failures += 1 }
        }
        typealias E = LovedStatusAuditEngine.Entry
        typealias D = LovedStatusAuditEngine.Decision
        func track(_ artist: String, _ name: String) -> AppleMusicSnapshot.Track { .init(name: name, artist: artist, album: "") }

        // One made-up library with every kind of uncertain row in it.
        //  A: loved on both, spelled "Sunhouse" on Last.fm and "Sun House" in Apple Music (the Limehouse case).
        //  B: loved on Last.fm; the library only has a longer title, not favorited.
        //  C: favorited in Apple Music; Last.fm history only has a longer title, not loved.
        //  D: favorited "Chorus" with "Chorus I" and "Chorus II" both in Last.fm history (two equally near candidates).
        //  E: loved on both, spelled the same, scrobbled (a plain agreement).
        let loved = [E(artist: "Artist A", track: "Sunhouse"), E(artist: "Artist B", track: "Moonlit Road"), E(artist: "Artist E", track: "Plain")]
        let history = [
            E(artist: "Artist A", track: "Sun House"), E(artist: "Artist B", track: "Moonlit Road"),
            E(artist: "Artist C", track: "Act One II"), E(artist: "Artist D", track: "Chorus I"), E(artist: "Artist D", track: "Chorus II"),
            E(artist: "Artist E", track: "Plain"),
        ]
        let apple = AppleMusicSnapshot(
            favorites: [track("Artist A", "Sun House"), track("Artist C", "Act One"), track("Artist D", "Chorus"), track("Artist E", "Plain")],
            library: [track("Artist A", "Sun House"), track("Artist B", "Moonlit Road Pt 2"), track("Artist C", "Act One"), track("Artist D", "Chorus"), track("Artist E", "Plain")],
            source: .favoritesPlaylist, readSeconds: 0
        )
        func run(_ decisions: [D] = []) -> LovedAudit { LovedStatusAuditEngine.audit(lovedOnLastfm: loved, history: history, apple: apple, decisions: decisions) }
        func rows(_ audit: LovedAudit, artist: String) -> [LovedAuditRow] { audit.rows.filter { $0.artist == artist } }

        let base = run()
        check("undecided: the four spelling cases are Uncertain, the plain one agrees", base.uncertainCount == 4 && base.agreeCount == 1, "uncertain=\(base.uncertainCount) agree=\(base.agreeCount)")

        // The orientation a decision is recorded in.
        let aRow = rows(base, artist: "Artist A").first, cRow = rows(base, artist: "Artist C").first
        check("a loved-on-both row's own names are Last.fm's, the near match Apple's",
              aRow?.decisionPair.map { $0.lastfm == E(artist: "Artist A", track: "Sunhouse") && $0.apple == E(artist: "Artist A", track: "Sun House") } == true)
        check("an Apple-only row's own names are Apple's, the near match Last.fm's",
              cRow?.decisionPair.map { $0.apple == E(artist: "Artist C", track: "Act One") && $0.lastfm == E(artist: "Artist C", track: "Act One II") } == true)

        // A: same track -> agrees; different -> one row each side.
        let a = (lf: E(artist: "Artist A", track: "Sunhouse"), ap: E(artist: "Artist A", track: "Sun House"))
        let aSame = run([D(lastfm: a.lf, apple: a.ap, sameTrack: true)])
        check("A, same track: it agrees and is no longer Uncertain", rows(aSame, artist: "Artist A").count == 1 && rows(aSame, artist: "Artist A")[0].agrees)
        let aDiff = run([D(lastfm: a.lf, apple: a.ap, sameTrack: false)])
        let aDiffRows = rows(aDiff, artist: "Artist A")
        check("A, different tracks: one Last.fm-only and one Apple-only row, neither Uncertain",
              aDiffRows.count == 2 && aDiffRows.allSatisfy { $0.uncertainty == nil }
              && aDiffRows.contains { $0.lastfm == .loved && $0.appleMusic != .loved } && aDiffRows.contains { $0.appleMusic == .loved && $0.lastfm != .loved },
              "\(aDiffRows.map { "\($0.track) LF=\($0.lastfm) AM=\($0.appleMusic) u=\($0.uncertainty != nil)" })")

        // B: Last.fm love with only a near name in the library.
        let b = (lf: E(artist: "Artist B", track: "Moonlit Road"), ap: E(artist: "Artist B", track: "Moonlit Road Pt 2"))
        let bSame = rows(run([D(lastfm: b.lf, apple: b.ap, sameTrack: true)]), artist: "Artist B")
        check("B, same track: confirmed Only on Last.fm (the library track isn't favorited)",
              bSame.count == 1 && bSame[0].uncertainty == nil && bSame[0].lastfm == .loved && bSame[0].appleMusic == .notLoved, "\(bSame.map { "\($0.appleMusic)" })")
        let bDiff = rows(run([D(lastfm: b.lf, apple: b.ap, sameTrack: false)]), artist: "Artist B")
        check("B, different tracks: not in Apple Music at all, no suggestion",
              bDiff.count == 1 && bDiff[0].uncertainty == nil && bDiff[0].appleMusic == .notPresent)

        // C: Apple favorite with only a near name in Last.fm.
        let c = (lf: E(artist: "Artist C", track: "Act One II"), ap: E(artist: "Artist C", track: "Act One"))
        let cSame = rows(run([D(lastfm: c.lf, apple: c.ap, sameTrack: true)]), artist: "Artist C")
        check("C, same track: confirmed Only on Apple Music (it is in Last.fm, just not loved)",
              cSame.count == 1 && cSame[0].uncertainty == nil && cSame[0].appleMusic == .loved && cSame[0].lastfm == .notLoved, "\(cSame.map { "\($0.lastfm)" })")
        let cDiff = rows(run([D(lastfm: c.lf, apple: c.ap, sameTrack: false)]), artist: "Artist C")
        check("C, different tracks: Apple Music only, Last.fm has nothing like it",
              cDiff.count == 1 && cDiff[0].uncertainty == nil && cDiff[0].lastfm == .notPresent)

        // D: two equally near candidates. Rejecting the suggestion moves on to the other; rejecting both ends it.
        let dApple = E(artist: "Artist D", track: "Chorus")
        let firstSuggestion = rows(base, artist: "Artist D").first?.uncertainty
        let firstName = firstSuggestion?.track ?? ""
        let afterFirst = rows(run([D(lastfm: E(artist: "Artist D", track: firstName), apple: dApple, sameTrack: false)]), artist: "Artist D").first?.uncertainty
        check("D: rejecting one suggestion offers the other", afterFirst != nil && afterFirst?.track != firstName, "first=\(firstName) then=\(afterFirst?.track ?? "nil")")
        let both = rows(run([D(lastfm: E(artist: "Artist D", track: "Chorus I"), apple: dApple, sameTrack: false), D(lastfm: E(artist: "Artist D", track: "Chorus II"), apple: dApple, sameTrack: false)]), artist: "Artist D")
        check("D: rejecting both leaves a confirmed Apple-only row", both.count == 1 && both[0].uncertainty == nil && both[0].lastfm == .notPresent)

        // Decisions about one track don't touch the others.
        let unrelated = rows(aSame, artist: "Artist B") + rows(aSame, artist: "Artist C") + rows(aSame, artist: "Artist D") + rows(aSame, artist: "Artist E")
        let baseline = rows(base, artist: "Artist B") + rows(base, artist: "Artist C") + rows(base, artist: "Artist D") + rows(base, artist: "Artist E")
        check("a decision on A leaves B, C, D and E exactly as they were",
              unrelated.map { "\($0.id)|\($0.uncertainty?.detail ?? "")|\($0.lastfm)|\($0.appleMusic)" } == baseline.map { "\($0.id)|\($0.uncertainty?.detail ?? "")|\($0.lastfm)|\($0.appleMusic)" })

        // Loved, no scrobbles: the engine's count against an independent set difference.
        func key(_ e: E) -> String { AppleMusicMatcher.durationMatchKey(artist: e.artist, track: e.track) }
        let scrobbled = Set(history.map(key))
        let expected = Set(loved.filter { !scrobbled.contains(key($0)) }.map(\.track))
        let found = Set(base.rows.filter(\.isLovedWithoutScrobbles).map(\.track))
        check("loved, no scrobbles equals loved names minus scrobbled names", found == expected && base.lovedWithoutScrobblesCount == expected.count, "\(found) vs \(expected)")
        check("…and it names Sunhouse (scrobbled only as “Sun House”), not the ones with plays", found == ["Sunhouse"])
        check("…the same after a “same track” decision (the Last.fm name still has no plays)", Set(aSame.rows.filter(\.isLovedWithoutScrobbles).map(\.track)) == ["Sunhouse"])

        // Tidy-up: a decision whose tracks no longer exist on one side can go; one that still applies stays.
        do {
            let sea = (lf: E(artist: "Artist F", track: "Sealegs"), ap: E(artist: "Artist F", track: "Sea Legs"))
            let decision = D(lastfm: sea.lf, apple: sea.ap, sameTrack: false)
            func obsolete(_ ds: [D], loved: [E], history: [E], apple: AppleMusicSnapshot) -> [D] {
                LovedStatusAuditEngine.obsoleteDecisions(ds, lovedOnLastfm: loved, history: history, apple: apple)
            }
            let before = AppleMusicSnapshot(favorites: [track("Artist F", "Sea Legs")], library: [track("Artist F", "Sea Legs")], source: .favoritesPlaylist, readSeconds: 0)
            check("tidy-up: both spellings still exist, so the decision stays",
                  obsolete([decision], loved: [sea.lf], history: [E(artist: "Artist F", track: "Sea Legs")],
                           apple: AppleMusicSnapshot(favorites: [track("Artist F", "Sea Legs")], library: [track("Artist F", "Sealegs"), track("Artist F", "Sea Legs")], source: .favoritesPlaylist, readSeconds: 0)).isEmpty)
            check("tidy-up: the Last.fm love was removed and re-made correctly, so the decision goes",
                  obsolete([decision], loved: [sea.ap], history: [E(artist: "Artist F", track: "Sea Legs")], apple: before) == [decision])
            check("tidy-up: the Apple Music track was renamed to match, so a “same track” decision goes too",
                  obsolete([D(lastfm: sea.ap, apple: sea.lf, sameTrack: true)], loved: [sea.ap], history: [sea.ap], apple: before) == [D(lastfm: sea.ap, apple: sea.lf, sameTrack: true)])
            check("tidy-up: a Last.fm name that is only in the scrobbles (not loved) still counts as existing",
                  obsolete([decision], loved: [], history: [sea.lf], apple: AppleMusicSnapshot(favorites: [], library: [track("Artist F", "Sealegs"), track("Artist F", "Sea Legs")], source: .favoritesPlaylist, readSeconds: 0)).isEmpty)
            check("tidy-up: only the stale decision in a mixed set is reported",
                  obsolete([decision, D(lastfm: a.lf, apple: a.ap, sameTrack: true)], loved: loved, history: history, apple: apple) == [decision])
            check("tidy-up: an empty library read removes nothing",
                  obsolete([decision], loved: loved, history: history, apple: AppleMusicSnapshot(favorites: [], library: [], source: .favoritesPlaylist, readSeconds: 0)).isEmpty)
            check("tidy-up: no loves and no scrobbles at all removes nothing",
                  obsolete([decision], loved: [], history: [], apple: apple).isEmpty)
        }

        // Favorites that aren't library tracks (made-up IDs): a catalogue favorite, a leftover entry, and a normal one.
        do {
            func withID(_ artist: String, _ name: String, _ id: Int?, cloud: String = "") -> AppleMusicSnapshot.Track {
                .init(name: name, artist: artist, album: "", cloudStatus: cloud, databaseID: id)
            }
            let favorites = [
                withID("Artist G", "Streamed Song", 99, cloud: "subscription"),
                withID("Artist G", "Old Entry", 98, cloud: "matched"),
                withID("Artist G", "Own Song", 2, cloud: "uploaded"),
            ]
            let library = [withID("Artist G", "Own Song", 2, cloud: "uploaded"), withID("Artist G", "Other Song", 3, cloud: "matched")]
            let snapshot = AppleMusicSnapshot(favorites: favorites, library: library, source: .favoritesPlaylist, readSeconds: 0)
            let audit = LovedStatusAuditEngine.audit(lovedOnLastfm: [], history: [], apple: snapshot)
            let flagged = audit.rows.filter { $0.appleNotInLibrary != nil }
            check("a favorite whose ID is not in the library is flagged; one that is, is not", flagged.map(\.track).sorted() == ["Old Entry", "Streamed Song"], "\(flagged.map(\.track))")
            check("a streaming favorite is a catalogue favorite", flagged.first { $0.track == "Streamed Song" }?.appleNotInLibrary?.origin == .catalogue)
            check("any other kind is a leftover entry", flagged.first { $0.track == "Old Entry" }?.appleNotInLibrary?.origin == .leftover)
            check("the flag carries the ID, name and artist a removal must find",
                  flagged.first { $0.track == "Old Entry" }?.appleNotInLibrary == AppleFavoriteNotInLibrary(origin: .leftover, databaseID: 98, name: "Old Entry", artist: "Artist G"))
            check("the headline count equals the flagged rows", audit.notInLibraryCount == 2)
            let removalTargets = audit.rows.compactMap { row in row.appleNotInLibrary.map { AppleMusicFavoritesWriter.Target(id: $0.databaseID, name: $0.name, artist: $0.artist) } }
            check("removal targets come only from flagged rows", Set(removalTargets.map(\.id)) == [98, 99])
            let noIDs = AppleMusicSnapshot(favorites: favorites.map { withID($0.artist, $0.name, nil, cloud: $0.cloudStatus) }, library: library.map { withID($0.artist, $0.name, nil) }, source: .favoritesPlaylist, readSeconds: 0)
            check("without IDs (older read, or the favorited-flag fallback) nothing is flagged",
                  LovedStatusAuditEngine.audit(lovedOnLastfm: [], history: [], apple: noIDs).notInLibraryCount == 0)
            // A flagged favorite that is also loved on Last.fm is still flagged (the row agrees, but the entry is a leftover).
            let lovedBoth = LovedStatusAuditEngine.audit(lovedOnLastfm: [E(artist: "Artist G", track: "Old Entry")], history: [E(artist: "Artist G", track: "Old Entry")], apple: snapshot)
            check("an agreeing row can still carry the flag", lovedBoth.rows.first { $0.track == "Old Entry" }.map { $0.agrees && $0.appleNotInLibrary != nil } == true)
        }
        // The writer's reading of the script's reply.
        check("writer: replies map to outcomes",
              AppleMusicFavoritesWriter.parse("REMOVED\n") == .removed && AppleMusicFavoritesWriter.parse("WOULD REMOVE") == .wouldRemove
              && AppleMusicFavoritesWriter.parse("NOT FOUND") == .notFound && AppleMusicFavoritesWriter.parse("MISMATCH Other / Someone") == .mismatch("Other / Someone")
              && AppleMusicFavoritesWriter.parse("") == .failed("Music gave no answer"))
        check("writer: only a real removal or a dry run counts as success",
              AppleMusicFavoritesWriter.Outcome.removed.succeeded && AppleMusicFavoritesWriter.Outcome.wouldRemove.succeeded
              && !AppleMusicFavoritesWriter.Outcome.notFound.succeeded && !AppleMusicFavoritesWriter.Outcome.mismatch("x").succeeded && !AppleMusicFavoritesWriter.Outcome.musicNotRunning.succeeded)

        // Decisions in a backup.
        let context = container.mainContext
        do {
            for item in try context.fetch(FetchDescriptor<LovedAuditDecision>()) { context.delete(item) }
            func save(_ lf: E, _ ap: E, _ same: Bool) {
                context.insert(LovedAuditDecision(
                    pairKey: LovedStatusAuditEngine.pairKey(lastfm: lf, apple: ap), lastfmArtist: lf.artist, lastfmTrack: lf.track,
                    appleArtist: ap.artist, appleTrack: ap.track, sameTrack: same, decidedAt: .now
                ))
            }
            save(a.lf, a.ap, true); save(c.lf, c.ap, false)
            try context.save()
            check("a stored pair key has no NUL (SQLite would cut it)", !LovedStatusAuditEngine.pairKey(lastfm: a.lf, apple: a.ap).contains("\u{0}"))
            let document = try NativeBackupEngine.makeDocument(context: context)
            let (archive, summary) = try NativeBackupEngine.inspect(document: document)
            check("the backup holds both decisions and says so", archive.lovedAuditDecisions?.count == 2 && summary.description.contains("2 loved-audit decisions"), summary.description)
            for item in try context.fetch(FetchDescriptor<LovedAuditDecision>()) { context.delete(item) }
            try context.save()
            try NativeBackupEngine.restoreLovedAuditDecisions(archive.lovedAuditDecisions, context: context)
            let restored = try context.fetch(FetchDescriptor<LovedAuditDecision>())
            check("restoring brings both back with their verdicts", restored.count == 2 && restored.filter(\.sameTrack).count == 1)
            try NativeBackupEngine.restoreLovedAuditDecisions(nil, context: context)
            check("an older backup (no field) leaves decisions alone", try context.fetch(FetchDescriptor<LovedAuditDecision>()).count == 2)
            if var json = try JSONSerialization.jsonObject(with: document.data) as? [String: Any] {
                json.removeValue(forKey: "lovedAuditDecisions")
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                let old = try decoder.decode(NativeBackupFormat.Archive.self, from: try JSONSerialization.data(withJSONObject: json))
                check("a backup without the field decodes", old.lovedAuditDecisions == nil)
            }
            try NativeBackupEngine.restoreLovedAuditDecisions([], context: context)
            check("a backup with none clears them", try context.fetch(FetchDescriptor<LovedAuditDecision>()).isEmpty)
        } catch {
            check("backup round trip", false, "\(error)")
        }

        print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
#endif
