import Foundation
import SwiftData

/// What the Release Year Audit changes, and only ever in Scroblytics: an album's own release date and its tracks' own dates (the
/// overrides the date editors set), and the decisions that remember what you chose. Nothing here touches Music or Last.fm.
@MainActor
enum ReleaseYearAuditActions {
    struct Result: Equatable {
        /// Albums whose date was set.
        var applied = 0
        /// Albums left alone, and why (no year in Music, or no album row to put a date on).
        var skipped = 0
        /// Albums left alone because Music's tracks span several years, so its single year is a guess (bulk only).
        var skippedVaries = 0
        /// Tracks whose own date was set along with their album's (an album whose tracks span years, chosen alone).
        var tracksSet = 0
    }

    struct TrackResult: Equatable {
        /// Tracks whose own date was set, and the albums they are on.
        var tracksSet = 0
        var albums = 0
        /// Tracks left alone because you had given them a date of your own.
        var skippedOwnDate = 0
        /// Tracks on more than one of the albums changed together: set once, for the first of them.
        var skippedShared = 0
        /// Tracks left alone because Scroblytics has no row for them (never played), or none that matches Music's spelling.
        var skippedNoTrack = 0
    }

    private enum AlbumChange {
        case none
        /// The album's own date was set; what it was before (nil: it had none).
        case changed(previous: String?)
    }

    private static func decision(forKey key: String, context: ModelContext) -> ReleaseYearDecision? {
        var descriptor = FetchDescriptor<ReleaseYearDecision>(predicate: #Predicate { $0.albumKey == key })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Records "keep Scroblytics" for an album, replacing an earlier decision about it.
    private static func recordKeep(_ row: ReleaseYearAudit.AlbumRow, scroblyticsYear: Int, musicYear: Int, context: ModelContext, now: Date) {
        if let existing = decision(forKey: row.albumKey, context: context) { context.delete(existing) }
        context.insert(ReleaseYearDecision(
            albumKey: row.albumKey, artist: row.scroblytics.artist, album: row.scroblytics.title,
            verdict: ReleaseYearAudit.Decision.Verdict.keepMine.rawValue, scroblyticsYear: scroblyticsYear, musicYear: musicYear,
            previousOverride: nil, decidedAt: now, tracksSignature: ReleaseYearAudit.tracksSignature(row.trackDifferences)
        ))
    }

    /// Records that Music's year was used for an album's own date, for some of its tracks, or both. An earlier "used" record about the same
    /// album is added to, not replaced, so undoing it puts back everything that was changed, in whichever order it was done.
    private static func recordUsed(
        _ row: ReleaseYearAudit.AlbumRow, scroblyticsYear: Int, musicYear: Int, album: AlbumChange,
        tracks: [ReleaseYearAudit.TrackChange], context: ModelContext, now: Date
    ) {
        var albumChanged = false
        var previous: String?
        var year = scroblyticsYear
        var changes = tracks
        if case .changed(let before) = album { albumChanged = true; previous = before }
        if let existing = decision(forKey: row.albumKey, context: context) {
            if existing.verdict == ReleaseYearAudit.Decision.Verdict.usedApple.rawValue {
                // Keep what the earlier change replaced: that is what undoing has to restore.
                if existing.albumChanged != false { albumChanged = true; previous = existing.previousOverride; year = existing.scroblyticsYear }
                let earlier = existing.trackChangesJSON.flatMap { try? JSONDecoder().decode([ReleaseYearAudit.TrackChange].self, from: $0) } ?? []
                let known = Set(earlier.map(\.key))
                changes = earlier + tracks.filter { !known.contains($0.key) }
                for change in tracks where known.contains(change.key) {
                    if let i = changes.firstIndex(where: { $0.key == change.key }) { changes[i] = .init(key: change.key, previous: changes[i].previous, applied: change.applied) }
                }
            }
            context.delete(existing)
        }
        context.insert(ReleaseYearDecision(
            albumKey: row.albumKey, artist: row.scroblytics.artist, album: row.scroblytics.title,
            verdict: ReleaseYearAudit.Decision.Verdict.usedApple.rawValue, scroblyticsYear: year, musicYear: musicYear,
            previousOverride: albumChanged ? previous : nil, decidedAt: now, albumChanged: albumChanged,
            trackChangesJSON: changes.isEmpty ? nil : try? JSONEncoder().encode(changes)
        ))
    }

    /// Sets each album's own date to Music's year (the most common among its tracks), remembering what it was. With
    /// `skipVaries`, an album whose Music tracks span several years is left alone: for those the single year is a guess. With
    /// `tracksOfVaried`, such an album is changed too and each of its tracks is also set to its own year in Music (one decision, one undo),
    /// because for it the album's single year says little and the tracks are what Music actually holds.
    @discardableResult
    static func useAppleYear(
        _ rows: [ReleaseYearAudit.AlbumRow], skipVaries: Bool = false, tracksOfVaried: Bool = false, context: ModelContext, now: Date = Date()
    ) throws -> Result {
        var result = Result()
        var setThisRun = Set<String>()
        for row in rows {
            guard let musicYear = row.musicYear, let year = row.scroblytics.year,
                  let album = ReleaseDateEngine.albumRow(context: context, artist: row.scroblytics.artist, album: row.scroblytics.title) else {
                result.skipped += 1
                continue
            }
            if skipVaries, row.musicVaries { result.skippedVaries += 1; continue }
            let before = album.releaseDateOverride
            album.releaseDateOverride = String(musicYear)
            var changes: [ReleaseYearAudit.TrackChange] = []
            if tracksOfVaried, row.musicVaries {
                var trackResult = TrackResult()
                changes = setTracks(ReleaseYearAudit.trackChanges(for: row, albumYear: musicYear), setThisRun: &setThisRun, result: &trackResult, context: context)
                result.tracksSet += changes.count
            }
            recordUsed(row, scroblyticsYear: year, musicYear: musicYear, album: .changed(previous: before), tracks: changes, context: context, now: now)
            result.applied += 1
        }
        try context.save()
        return result
    }

    /// Sets the own date of each listed track to Music's year, skipping a track you gave a date of your own and a song already set in this
    /// batch; returns what was set, with each track's earlier date.
    private static func setTracks(
        _ differences: [ReleaseYearAudit.TrackDifference], setThisRun: inout Set<String>, result: inout TrackResult, context: ModelContext
    ) -> [ReleaseYearAudit.TrackChange] {
        var changes: [ReleaseYearAudit.TrackChange] = []
        for difference in differences {
            if difference.ownDate { result.skippedOwnDate += 1; continue }
            guard let track = trackRow(artist: difference.artist, name: difference.name, context: context) else { result.skippedNoTrack += 1; continue }
            // The same song on another album of this batch was set a moment ago; a date of its own under a spelling the comparison didn't
            // see is still yours.
            if setThisRun.contains(track.identityKey) { result.skippedShared += 1; continue }
            if let own = track.releaseDateOverride, !own.isEmpty { result.skippedOwnDate += 1; continue }
            let applied = String(difference.musicYear)
            changes.append(.init(key: track.identityKey, previous: nil, applied: applied))
            track.releaseDateOverride = applied
            setThisRun.insert(track.identityKey)
        }
        return changes
    }

    /// The track's row in the store: by the key it is saved under, else by artist and normalized title (Music and Last.fm may spell a
    /// title with a different apostrophe or "Remastered" suffix).
    private static func trackRow(artist: String, name: String, context: ModelContext) -> Track? {
        let key = TextNormalization.lovedKey(artist: artist, track: name)
        var descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.identityKey == key })
        descriptor.fetchLimit = 1
        if let exact = try? context.fetch(descriptor).first { return exact }
        let normalized = TextNormalization.normalizeTrackTitle(name)
        let artistKey = TextNormalization.artistIdentityKey(artist)
        let candidates = (try? context.fetch(FetchDescriptor<Track>(predicate: #Predicate { $0.normalizedTitle == normalized }))) ?? []
        return candidates.first { $0.artist.map { TextNormalization.artistIdentityKey($0.name) } == artistKey }
    }

    /// Sets each track's own date to the year Music holds for it, for the tracks of these albums that now show their album's date. A track
    /// you gave a date of your own is never changed, and neither is one with no row here. Each change is remembered so it can be undone.
    @discardableResult
    static func useAppleYearsForTracks(_ rows: [ReleaseYearAudit.AlbumRow], context: ModelContext, now: Date = Date()) throws -> TrackResult {
        var result = TrackResult()
        var setThisRun = Set<String>()
        for row in rows {
            let changes = setTracks(row.trackDifferences, setThisRun: &setThisRun, result: &result, context: context)
            guard !changes.isEmpty else { continue }
            recordUsed(
                row, scroblyticsYear: row.scroblytics.year ?? row.musicYear ?? 0, musicYear: row.musicYear ?? 0, album: .none,
                tracks: changes, context: context, now: now
            )
            result.tracksSet += changes.count
            result.albums += 1
        }
        try context.save()
        return result
    }

    /// "Keep Scroblytics": the album is settled for as long as both years, and which of its tracks differ, stay as they are.
    @discardableResult
    static func keepMine(_ rows: [ReleaseYearAudit.AlbumRow], context: ModelContext, now: Date = Date()) throws -> Result {
        var result = Result()
        for row in rows {
            guard let musicYear = row.musicYear, let year = row.scroblytics.year else { result.skipped += 1; continue }
            recordKeep(row, scroblyticsYear: year, musicYear: musicYear, context: context, now: now)
            result.applied += 1
        }
        try context.save()
        return result
    }

    /// Takes a decision back. "Keep Scroblytics": the album is asked about again. "Used Apple Music's": the album's date and each track's
    /// own date go back to what they were, but only where they still are what was set (one you have changed since is left alone).
    static func undo(_ decision: ReleaseYearDecision, context: ModelContext) throws {
        if decision.verdict == ReleaseYearAudit.Decision.Verdict.usedApple.rawValue {
            if decision.albumChanged != false,
               let album = ReleaseDateEngine.albumRow(context: context, artist: decision.artist, album: decision.album),
               album.releaseDateOverride == String(decision.musicYear) {
                album.releaseDateOverride = decision.previousOverride
            }
            let changes = decision.trackChangesJSON.flatMap { try? JSONDecoder().decode([ReleaseYearAudit.TrackChange].self, from: $0) } ?? []
            for change in changes {
                let key = change.key
                var descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.identityKey == key })
                descriptor.fetchLimit = 1
                if let track = try? context.fetch(descriptor).first, track.releaseDateOverride == change.applied { track.releaseDateOverride = change.previous }
            }
        }
        context.delete(decision)
        try context.save()
    }

    /// What a decision changed, in words for the Decisions list.
    static func summary(of decision: ReleaseYearDecision) -> String {
        guard decision.verdict == ReleaseYearAudit.Decision.Verdict.usedApple.rawValue else {
            return "Kept Scroblytics’ \(String(decision.scroblyticsYear)); Apple Music has \(String(decision.musicYear))"
        }
        let tracks = decision.trackChangesJSON.flatMap { try? JSONDecoder().decode([ReleaseYearAudit.TrackChange].self, from: $0) }?.count ?? 0
        let tracksText = tracks == 1 ? "1 track’s year" : "\(tracks) tracks’ years"
        if decision.albumChanged == false { return "Used Apple Music’s years for \(tracksText)" }
        return "Used Apple Music’s \(String(decision.musicYear)) (was \(String(decision.scroblyticsYear)))" + (tracks > 0 ? " and \(tracksText)" : "")
    }
}
