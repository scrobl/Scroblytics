import Foundation
import Observation
import SwiftData

/// Sync only ever ADDS `Album`/`Track` rows — it never removes one when its scrobbles go away. When a scrobble is
/// corrected on Last.fm (album retitled, artist credit changed, track renamed), the corrected scrobbles get their own
/// new rows, and everything saved against the OLD row — an album-match decision, a release-date/duration/BPM override,
/// a custom image — stays stranded on a row nothing plays under anymore. It also lingers in search as a phantom
/// duplicate.
///
/// This finds those stranded rows and proposes moving their saved data to the row that replaced them. It never
/// writes anything itself: it returns a plan, and every change happens only when the user applies it.
enum StaleRecordReconciler {
    struct Backing: Sendable {
        /// `Album.identityKey` → plays, for every album the scrobbles currently produce.
        var albumPlays: [String: Int] = [:]
        /// `Track.identityKey` (`lovedKey`) → plays.
        var trackPlays: [String: Int] = [:]
    }

    /// Which identity keys the current scrobbles actually produce — computed with the same key functions the sync
    /// uses to create rows (`resolveAlbum` / `resolveTrack`), so "backed" means exactly "sync would land on this row".
    nonisolated static func backing(snapshots: [ScrobbleSnapshot], artistNames: [String: String]) -> Backing {
        struct Pair: Hashable { let artist: String; let name: String }
        var albumPairs: [Pair: Int] = [:]
        var trackPairs: [Pair: Int] = [:]
        for s in snapshots {
            if !s.albumName.isEmpty { albumPairs[Pair(artist: s.artistName, name: s.albumName), default: 0] += 1 }
            trackPairs[Pair(artist: s.artistName, name: s.trackName), default: 0] += 1
        }
        var result = Backing()
        for (pair, plays) in albumPairs {
            // The album row is keyed under the Artist row's stored spelling, not the scrobble's raw one.
            guard let artistName = artistNames[TextNormalization.artistIdentityKey(pair.artist)] else { continue }
            result.albumPlays[TextNormalization.albumIdentityKey(artist: artistName, album: pair.name), default: 0] += plays
        }
        for (pair, plays) in trackPairs {
            result.trackPlays[TextNormalization.lovedKey(artist: pair.artist, track: pair.name), default: 0] += plays
        }
        return result
    }

    // MARK: - Matching

    private nonisolated static func tokens(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private nonisolated static func containsRun(_ needle: [String], in haystack: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count) where Array(haystack[start..<(start + needle.count)]) == needle { return true }
        return false
    }

    /// The same artist, or one credit that contains the other as whole words — "Courtney Barnett" vs
    /// "Courtney Barnett & Kurt Vile" is the case that motivated this.
    nonisolated static func artistsCompatible(_ a: String, _ b: String) -> Bool {
        artistKeysCompatible(TextNormalization.artistIdentityKey(a), TextNormalization.artistIdentityKey(b))
    }

    /// `artistsCompatible` on keys already run through `artistIdentityKey` — for callers comparing one artist
    /// against many, who shouldn't pay the normalization on every pair.
    nonisolated static func artistKeysCompatible(_ ka: String, _ kb: String) -> Bool {
        if ka == kb { return true }
        let ta = tokens(ka), tb = tokens(kb)
        return containsRun(ta, in: tb) || containsRun(tb, in: ta)
    }

    /// 3 = same after normalization, 2 = the app's own "same album, different edition" similarity, 1 = one title
    /// contains the other as whole words ("Blue Album" / "Artist (Blue Album)"), 0 = unrelated.
    nonisolated static func titleScore(_ a: String, _ b: String) -> Int {
        let na = a.lowercased(), nb = b.lowercased()
        guard !na.isEmpty, !nb.isEmpty else { return 0 }
        if na == nb { return 3 }
        if TextNormalization.albumNamesSimilar(na, nb) { return 2 }
        let ta = tokens(na), tb = tokens(nb)
        let (short, long) = ta.count <= tb.count ? (ta, tb) : (tb, ta)
        guard short.count >= 2 || (short.first?.count ?? 0) >= 5 else { return 0 }
        return containsRun(short, in: long) ? 1 : 0
    }
}

/// One proposed fix: a stranded row, the rows that could take over its saved data, and how to do it.
struct StaleRecordItem: Identifiable {
    struct Candidate: Identifiable {
        let id = UUID()
        let artist: String
        let title: String
        let plays: Int
        /// What would be copied onto this row (it doesn't already have its own).
        let moves: [String]
        /// What this row already has, so the old value is dropped rather than overwriting the newer one.
        let superseded: [String]
    }

    enum Kind { case album, track }

    let id = UUID()
    let kind: Kind
    let staleKey: String
    let staleArtist: String
    let staleTitle: String
    /// Everything the stranded row holds.
    let holds: [String]
    let candidates: [Candidate]
    var chosen = 0
    var approved = true
    /// Moves what's missing onto candidate `index`, then deletes the stranded row.
    let perform: (Int, ModelContext) -> Void
}

struct StaleRecordPlan {
    var items: [StaleRecordItem] = []
    /// Stranded rows that hold nothing at all — safe to remove, listed for the confirmation.
    var unusedLabels: [String] = []
    var deleteUnused: (ModelContext) -> Void = { _ in }
    /// Stranded rows that DO hold saved data but have no plausible replacement — left alone.
    var leftAlone: [String] = []

    var isEmpty: Bool { items.isEmpty && unusedLabels.isEmpty }
    /// Changes when the set of proposed moves changes, so a dismissed review doesn't reappear until there's
    /// something new in it.
    var signature: String {
        items.map { "\($0.staleKey)>\($0.candidates.first?.title ?? "")" }.sorted().joined(separator: "|")
    }
}

@MainActor @Observable
final class StaleRecordReviewModel {
    var plan = StaleRecordPlan()
    var removeUnused = true
    private(set) var isRefreshing = false
    private(set) var hasLoaded = false
    var errorMessage: String?

    private static let dismissedKey = "staleRecords.dismissedSignature"

    /// True when there are moves to propose that the user hasn't already dismissed.
    var shouldAutoPresent: Bool {
        !plan.items.isEmpty && UserDefaults.standard.string(forKey: Self.dismissedKey) != plan.signature
    }

    func markDismissed() {
        UserDefaults.standard.set(plan.signature, forKey: Self.dismissedKey)
    }

    func refresh(container: ModelContainer) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false; hasLoaded = true }
        errorMessage = nil
        do {
            let snapshots = try await ScrobbleHistoryCache.shared.snapshots(container: container)
            let context = container.mainContext
            var artistNames: [String: String] = [:]
            for artist in try context.fetch(FetchDescriptor<Artist>()) { artistNames[artist.normalizedName] = artist.name }
            let backing = await Task.detached(priority: .utility) {
                StaleRecordReconciler.backing(snapshots: snapshots, artistNames: artistNames)
            }.value
            plan = try buildPlan(backing: backing, context: context)
        } catch {
            errorMessage = "\(error)"
        }
    }

    func apply(container: ModelContainer) {
        let context = container.mainContext
        for item in plan.items where item.approved && item.candidates.indices.contains(item.chosen) {
            item.perform(item.chosen, context)
        }
        if removeUnused { plan.deleteUnused(context) }
        do { try context.save() } catch {
            context.rollback()
            errorMessage = "Couldn't save: \(error)"
            return
        }
        plan = StaleRecordPlan()
    }

    // MARK: - Plan

    private func buildPlan(backing: StaleRecordReconciler.Backing, context: ModelContext) throws -> StaleRecordPlan {
        var plan = StaleRecordPlan()
        var unusedAlbums: [Album] = []
        var unusedTracks: [Track] = []

        let albums = try context.fetch(FetchDescriptor<Album>())
        let liveAlbums = albums.filter { backing.albumPlays[$0.identityKey] != nil }
        for album in albums where backing.albumPlays[album.identityKey] == nil {
            let holds = Self.holds(album)
            guard !holds.isEmpty else { unusedAlbums.append(album); continue }
            let artist = album.artist?.name ?? ""
            let candidates = liveAlbums.compactMap { live -> (Album, Int)? in
                guard live !== album, let liveArtist = live.artist?.name,
                      StaleRecordReconciler.artistsCompatible(artist, liveArtist) else { return nil }
                let score = StaleRecordReconciler.titleScore(album.normalizedTitle, live.normalizedTitle)
                return score > 0 ? (live, score) : nil
            }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                return (backing.albumPlays[a.0.identityKey] ?? 0) > (backing.albumPlays[b.0.identityKey] ?? 0)
            }
            .prefix(5)
            guard !candidates.isEmpty else { plan.leftAlone.append("\(artist) — \(album.title) (\(holds.joined(separator: ", ")))"); continue }
            let live = candidates.map(\.0)
            plan.items.append(StaleRecordItem(
                kind: .album, staleKey: album.identityKey, staleArtist: artist, staleTitle: album.title, holds: holds,
                candidates: live.map { candidate in
                    let (moves, superseded) = Self.albumTransfer(from: album, to: candidate)
                    return .init(artist: candidate.artist?.name ?? "", title: candidate.title, plays: backing.albumPlays[candidate.identityKey] ?? 0, moves: moves, superseded: superseded)
                },
                perform: { index, context in
                    Self.moveAlbum(from: album, to: live[index])
                    context.delete(album)
                }
            ))
        }

        let tracks = try context.fetch(FetchDescriptor<Track>())
        let liveTracks = tracks.filter { backing.trackPlays[$0.identityKey] != nil }
        for track in tracks where backing.trackPlays[track.identityKey] == nil {
            let holds = Self.holds(track)
            guard !holds.isEmpty else { unusedTracks.append(track); continue }
            let artist = track.artist?.name ?? ""
            let staleTitle = TextNormalization.normalizeTrackTitle(track.title)
            let candidates = liveTracks.compactMap { live -> (Track, Int)? in
                guard live !== track, let liveArtist = live.artist?.name,
                      StaleRecordReconciler.artistsCompatible(artist, liveArtist) else { return nil }
                let score = StaleRecordReconciler.titleScore(staleTitle, TextNormalization.normalizeTrackTitle(live.title))
                return score > 0 ? (live, score) : nil
            }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                return (backing.trackPlays[a.0.identityKey] ?? 0) > (backing.trackPlays[b.0.identityKey] ?? 0)
            }
            .prefix(5)
            guard !candidates.isEmpty else { plan.leftAlone.append("\(artist) — \(track.title) (\(holds.joined(separator: ", ")))"); continue }
            let live = candidates.map(\.0)
            plan.items.append(StaleRecordItem(
                kind: .track, staleKey: track.identityKey, staleArtist: artist, staleTitle: track.title, holds: holds,
                candidates: live.map { candidate in
                    let (moves, superseded) = Self.trackTransfer(from: track, to: candidate)
                    return .init(artist: candidate.artist?.name ?? "", title: candidate.title, plays: backing.trackPlays[candidate.identityKey] ?? 0, moves: moves, superseded: superseded)
                },
                perform: { index, context in
                    Self.moveTrack(from: track, to: live[index])
                    context.delete(track)
                }
            ))
        }

        plan.items.sort { ($0.staleArtist, $0.staleTitle) < ($1.staleArtist, $1.staleTitle) }
        plan.unusedLabels = unusedAlbums.map { "\($0.artist?.name ?? "") — \($0.title)" }.sorted()
            + unusedTracks.map { "\($0.artist?.name ?? "") — \($0.title) (track)" }.sorted()
        plan.deleteUnused = { context in
            for album in unusedAlbums { context.delete(album) }
            for track in unusedTracks { context.delete(track) }
        }
        return plan
    }

    // MARK: - What a row holds, and what would move

    private static func holds(_ album: Album) -> [String] {
        var out: [String] = []
        if album.matchResolutionMode != nil { out.append("album match decision") }
        if album.releaseDateOverride != nil { out.append("release date") }
        if album.customImageFilename != nil { out.append("custom image") }
        return out
    }

    private static func holds(_ track: Track) -> [String] {
        var out: [String] = []
        if track.durationOverrideSeconds != nil { out.append("duration") }
        if track.bpmOverride != nil { out.append("BPM") }
        if track.releaseDateOverride != nil { out.append("release date") }
        if track.customImageFilename != nil { out.append("custom image") }
        return out
    }

    private static func albumTransfer(from old: Album, to new: Album) -> (moves: [String], superseded: [String]) {
        var moves: [String] = [], superseded: [String] = []
        func consider(_ label: String, _ has: Bool, _ newHas: Bool) {
            guard has else { return }
            if newHas { superseded.append(label) } else { moves.append(label) }
        }
        consider("album match decision", old.matchResolutionMode != nil, new.matchResolutionMode != nil)
        consider("release date", old.releaseDateOverride != nil, new.releaseDateOverride != nil)
        consider("custom image", old.customImageFilename != nil, new.customImageFilename != nil)
        return (moves, superseded)
    }

    private static func moveAlbum(from old: Album, to new: Album) {
        if new.matchResolutionMode == nil, old.matchResolutionMode != nil {
            new.matchResolutionMode = old.matchResolutionMode
            new.canonicalArtist = old.canonicalArtist
            new.canonicalAlbum = old.canonicalAlbum
            new.manualTracklist = old.manualTracklist
        }
        if new.releaseDateOverride == nil { new.releaseDateOverride = old.releaseDateOverride }
        if new.customImageFilename == nil { new.customImageFilename = old.customImageFilename }
    }

    private static func trackTransfer(from old: Track, to new: Track) -> (moves: [String], superseded: [String]) {
        var moves: [String] = [], superseded: [String] = []
        func consider(_ label: String, _ has: Bool, _ newHas: Bool) {
            guard has else { return }
            if newHas { superseded.append(label) } else { moves.append(label) }
        }
        consider("duration", old.durationOverrideSeconds != nil, new.durationOverrideSeconds != nil)
        consider("BPM", old.bpmOverride != nil, new.bpmOverride != nil)
        consider("release date", old.releaseDateOverride != nil, new.releaseDateOverride != nil)
        consider("custom image", old.customImageFilename != nil, new.customImageFilename != nil)
        return (moves, superseded)
    }

    private static func moveTrack(from old: Track, to new: Track) {
        if new.durationOverrideSeconds == nil { new.durationOverrideSeconds = old.durationOverrideSeconds }
        if new.bpmOverride == nil { new.bpmOverride = old.bpmOverride }
        if new.releaseDateOverride == nil { new.releaseDateOverride = old.releaseDateOverride }
        if new.customImageFilename == nil { new.customImageFilename = old.customImageFilename }
    }
}

#if DEBUG
/// Verification hook: with `SCROBLYTICS_STALE_DUMP=/path/out.txt` set, analyzes the store at launch and writes the
/// plan (and, with `SCROBLYTICS_STALE_APPLY=1`, applies every proposed move to THAT store and re-analyzes), then quits.
enum StaleRecordDebugEval {
    @MainActor
    static func runHeadlessIfRequested(container: ModelContainer) {
        guard let path = ProcessInfo.processInfo.environment["SCROBLYTICS_STALE_DUMP"] else { return }
        Task { @MainActor in
            let model = StaleRecordReviewModel()
            var out: [String] = []
            @MainActor func dump(_ label: String) {
                out.append("== \(label)")
                for item in model.plan.items {
                    out.append("MOVE [\(item.kind)] \(item.staleArtist) — \(item.staleTitle) | holds: \(item.holds.joined(separator: ","))")
                    for (i, c) in item.candidates.enumerated() {
                        out.append("   \(i == item.chosen ? "*" : " ") \(c.artist) — \(c.title) (\(c.plays) plays) moves=\(c.moves) superseded=\(c.superseded)")
                    }
                }
                out.append("UNUSED (\(model.plan.unusedLabels.count)): \(model.plan.unusedLabels.joined(separator: "; "))")
                out.append("LEFT ALONE: \(model.plan.leftAlone.joined(separator: "; "))")
            }
            await model.refresh(container: container)
            dump("before")
            if ProcessInfo.processInfo.environment["SCROBLYTICS_STALE_APPLY"] == "1" {
                model.apply(container: container)
                await model.refresh(container: container)
                dump("after apply")
            }
            try? out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            exit(0)
        }
    }
}
#endif
