import Foundation
import SwiftData

/// What the Release Year Audit changes, and only ever in Scroblytics: an album's own release date (the override the date editor
/// sets), and the decisions that remember what you chose. Nothing here touches Music or Last.fm.
@MainActor
enum ReleaseYearAuditActions {
    struct Result: Equatable {
        /// Albums whose date was set.
        var applied = 0
        /// Albums left alone, and why (no year in Music, or no album row to put a date on).
        var skipped = 0
        /// Albums left alone because Music's tracks span several years, so its single year is a guess (bulk only).
        var skippedVaries = 0
    }

    private static func decision(forKey key: String, context: ModelContext) -> ReleaseYearDecision? {
        var descriptor = FetchDescriptor<ReleaseYearDecision>(predicate: #Predicate { $0.albumKey == key })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Records a decision, replacing an earlier one about the same album.
    private static func record(
        _ row: ReleaseYearAudit.AlbumRow, verdict: ReleaseYearAudit.Decision.Verdict, scroblyticsYear: Int, musicYear: Int,
        previousOverride: String?, context: ModelContext, now: Date
    ) {
        if let existing = decision(forKey: row.albumKey, context: context) { context.delete(existing) }
        context.insert(ReleaseYearDecision(
            albumKey: row.albumKey, artist: row.scroblytics.artist, album: row.scroblytics.title, verdict: verdict.rawValue,
            scroblyticsYear: scroblyticsYear, musicYear: musicYear, previousOverride: previousOverride, decidedAt: now
        ))
    }

    /// Sets each album's own date to Music's year (the most common among its tracks), remembering what it was. With
    /// `skipVaries`, an album whose Music tracks span several years is left alone: for those the single year is a guess.
    @discardableResult
    static func useAppleYear(_ rows: [ReleaseYearAudit.AlbumRow], skipVaries: Bool = false, context: ModelContext, now: Date = Date()) throws -> Result {
        var result = Result()
        for row in rows {
            guard let musicYear = row.musicYear, let year = row.scroblytics.year,
                  let album = ReleaseDateEngine.albumRow(context: context, artist: row.scroblytics.artist, album: row.scroblytics.title) else {
                result.skipped += 1
                continue
            }
            if skipVaries, row.musicVaries { result.skippedVaries += 1; continue }
            let before = album.releaseDateOverride
            album.releaseDateOverride = String(musicYear)
            record(row, verdict: .usedApple, scroblyticsYear: year, musicYear: musicYear, previousOverride: before, context: context, now: now)
            result.applied += 1
        }
        try context.save()
        return result
    }

    /// "Keep Scroblytics": the album is settled for as long as both years stay as they are.
    @discardableResult
    static func keepMine(_ rows: [ReleaseYearAudit.AlbumRow], context: ModelContext, now: Date = Date()) throws -> Result {
        var result = Result()
        for row in rows {
            guard let musicYear = row.musicYear, let year = row.scroblytics.year else { result.skipped += 1; continue }
            record(row, verdict: .keepMine, scroblyticsYear: year, musicYear: musicYear, previousOverride: nil, context: context, now: now)
            result.applied += 1
        }
        try context.save()
        return result
    }

    /// Takes a decision back. "Keep Scroblytics": the album is asked about again. "Used Apple Music's": the album's date goes back to what it was, but
    /// only if it still is the one this set (a date you have changed since is left alone).
    static func undo(_ decision: ReleaseYearDecision, context: ModelContext) throws {
        if decision.verdict == ReleaseYearAudit.Decision.Verdict.usedApple.rawValue,
           let album = ReleaseDateEngine.albumRow(context: context, artist: decision.artist, album: decision.album),
           album.releaseDateOverride == String(decision.musicYear) {
            album.releaseDateOverride = decision.previousOverride
        }
        context.delete(decision)
        try context.save()
    }
}
