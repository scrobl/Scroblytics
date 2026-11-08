import Foundation
import Observation
import SwiftData

extension Notification.Name {
    /// The saved read of the Apple Music library changed (a new read finished), so anything showing from it should look again.
    static let appleMusicDetailsDidUpdate = Notification.Name("AppleMusicDetailsDidUpdate")
}

/// Decides when the library is read, and holds what Settings shows about it. Off until the person turns it on, because the first read asks
/// for permission to control Music.
///
/// **When it reads.** Never on its own schedule and never by opening Music. After a sync finishes, and only while Music is already open, it
/// asks Music one cheap question (how many songs the library has). It reads everything (about eight seconds, in the background) when the
/// count has changed, since that is how added or removed songs show up, or when the last read is more than 12 hours old, which is how an edited
/// genre or tempo tag is noticed. Otherwise it does nothing. Turning it on, or **Refresh Now**, reads at once. A song added while Music is
/// closed appears at the first sync after Music is opened.
@MainActor
@Observable
final class AppleMusicDetailsStore {
    static let shared = AppleMusicDetailsStore()

    nonisolated static let enabledKey = "appleMusicDetails.enabled"
    /// How old a read may get before the next sync reads again even though the number of songs hasn't changed.
    nonisolated static let fullRefreshInterval: TimeInterval = 12 * 3600

    private(set) var enabled = UserDefaults.standard.bool(forKey: AppleMusicDetailsStore.enabledKey)
    private(set) var readAt: Date?
    private(set) var songCount = 0
    private(set) var isReading = false
    /// Why the last read couldn't happen, in plain words; nil after a good one.
    private(set) var problem: String?
    /// Last.fm songs the library had several possible partners for, so they were left out; see `AppleMusicDetailsIndex.match`.
    private(set) var unmatched: [AppleMusicDetailsIndex.Unmatched] = []
    private(set) var unmatchedChecked = false

    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: Self.enabledKey)
        refreshSummary()
    }

    /// Starts listening for the end of a sync. Called once by the app window.
    func start(container: ModelContainer) {
        self.container = container
        refreshSummary()
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .scrobbleSyncDidFinish, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh(force: false) }
        }
    }

    func setEnabled(_ on: Bool) {
        guard enabled != on else { return }
        enabled = on
        defaults.set(on, forKey: Self.enabledKey)
        problem = nil
        if on { refresh(force: true) }
    }

    /// Deletes the saved read (Settings › Forget). The matching goes with it; Query and the pages show nothing from Music until the next read.
    func forget() {
        AppleMusicDetailsStorage.delete()
        readAt = nil
        songCount = 0
        unmatched = []
        unmatchedChecked = false
        NotificationCenter.default.post(name: .appleMusicDetailsDidUpdate, object: nil)
    }

    private func refreshSummary() {
        let file = AppleMusicDetailsStorage.load()
        readAt = file?.readAt
        songCount = file?.rows.count ?? 0
    }

    // MARK: Reading

    /// Reads now (`force`) or when due. Does nothing when the feature is off or a read is running; when Music isn't open it says so only for
    /// a read the person asked for.
    func refresh(force: Bool) {
        guard enabled, !isReading, let container else { return }
        guard AppleMusicFavoritesReader.isMusicRunning else {
            if force { problem = "Music isn’t open. Open Music, then try again." }
            return
        }
        isReading = true
        problem = nil
        Task { [weak self] in
            do {
                let saved = AppleMusicDetailsStorage.load()
                var changed = false
                let count = try await AppleMusicFavoritesReader.libraryTrackCount()
                let stale = saved.map { Date().timeIntervalSince($0.readAt) >= Self.fullRefreshInterval || $0.rows.count != count } ?? true
                if force || stale {
                    let rows = try await AppleMusicFavoritesReader.readLibraryDetails()
                    let file = AppleMusicDetailsFile(readAt: Date(), rows: rows)
                    try await offMain { try AppleMusicDetailsStorage.save(file) }
                    changed = true
                }
                self?.refreshSummary()
                if changed { NotificationCenter.default.post(name: .appleMusicDetailsDidUpdate, object: nil) }
                await self?.recomputeUnmatched(container: container)
                self?.isReading = false
            } catch {
                self?.problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self?.isReading = false
            }
        }
    }

    /// Works out which Last.fm songs were skipped for being unclear (the history can change after a sync without the library changing).
    func recomputeUnmatched(container: ModelContainer) async {
        guard let file = AppleMusicDetailsStorage.load() else { unmatched = []; unmatchedChecked = false; return }
        let list = try? await offMain {
            let scrobbles = try await ScrobbleHistoryCache.shared.canonicalSnapshots(container: container)
            return AppleMusicDetailsIndexCache.index(for: file, scrobbles: scrobbles).unmatched()
        }
        unmatched = list ?? []
        unmatchedChecked = list != nil
    }

    /// The status line under the switch.
    var statusText: String {
        if isReading { return "Reading Music…" }
        if let problem { return problem }
        guard let readAt else { return enabled ? "Not read yet. It reads after the next sync while Music is open, or press Refresh Now." : "Off." }
        let when = readAt.formatted(.relative(presentation: .named))
        var text = "Read \(when): \(songCount.formatted()) \(songCount == 1 ? "song" : "songs")."
        if unmatchedChecked, !unmatched.isEmpty {
            text += " \(unmatched.count.formatted()) \(unmatched.count == 1 ? "song" : "songs") couldn’t be matched."
        }
        return text
    }
}

/// What a detail page shows from the saved read, for one song, album or artist.
struct AppleMusicDetailsInfo: Sendable, Equatable {
    var added: Date?
    var genre: String?
    var inLibrary: Bool
    /// For a song matched to a library title spelled differently: that title.
    var matchedTitle: String?
}

enum AppleMusicDetailsLookup {
    /// nil while no read has been saved, so the pages show nothing at all rather than a column of dashes.
    static func track(artist: String, track: String, container: ModelContainer) async -> AppleMusicDetailsInfo? {
        await lookup(container: container) { index in
            let match = index.match(artist: artist, track: track)
            guard case .matched(let indexes, let viaSpelling) = match else { return AppleMusicDetailsInfo(added: nil, genre: nil, inLibrary: false, matchedTitle: nil) }
            let rows = indexes.map { index.rows[$0] }
            return AppleMusicDetailsInfo(
                added: AppleMusicDetailsIndex.earliestAdded(rows), genre: AppleMusicDetailsIndex.commonGenre(rows), inLibrary: true,
                matchedTitle: viaSpelling ? rows.first?.title : nil
            )
        }
    }

    static func album(artist: String, album: String, container: ModelContainer) async -> AppleMusicDetailsInfo? {
        await lookup(container: container) { index in
            let rows = index.rows(artist: artist, album: album)
            return AppleMusicDetailsInfo(added: AppleMusicDetailsIndex.earliestAdded(rows), genre: AppleMusicDetailsIndex.commonGenre(rows), inLibrary: !rows.isEmpty, matchedTitle: nil)
        }
    }

    static func artist(_ artist: String, container: ModelContainer) async -> AppleMusicDetailsInfo? {
        await lookup(container: container) { index in
            let rows = index.rows(artist: artist)
            return AppleMusicDetailsInfo(added: AppleMusicDetailsIndex.earliestAdded(rows), genre: AppleMusicDetailsIndex.commonGenre(rows), inLibrary: !rows.isEmpty, matchedTitle: nil)
        }
    }

    private static func lookup(container: ModelContainer, _ body: @escaping @Sendable (AppleMusicDetailsIndex) -> AppleMusicDetailsInfo) async -> AppleMusicDetailsInfo? {
        guard let file = AppleMusicDetailsStorage.load() else { return nil }
        return try? await offMain {
            let scrobbles = try await ScrobbleHistoryCache.shared.canonicalSnapshots(container: container)
            return body(AppleMusicDetailsIndexCache.index(for: file, scrobbles: scrobbles))
        }
    }

    /// The tiles for a page's fact grid: when it was added to the library and its genre. Nothing before the first read.
    @MainActor
    static func facts(_ info: AppleMusicDetailsInfo?, entity: String) -> [DetailFact] {
        guard let info else { return [] }
        let added: DetailFact.Value = info.added.map { .text($0.formatted(date: .abbreviated, time: .omitted)) } ?? .unknown
        var addedDetail: String?
        if !info.inLibrary { addedDetail = "Not in your library" } else if let title = info.matchedTitle { addedDetail = "As “\(title)”" }
        return [
            DetailFact(
                id: "musicAdded", label: "Added to Music", value: added, detail: addedDetail, mayHaveDetail: true, systemImage: "plus.square",
                help: "When this \(entity) was added to your Apple Music library (the earliest, for an album or artist)."
            ),
            DetailFact(
                id: "musicGenre", label: "Genre", value: info.genre.map { .text($0) } ?? .unknown, systemImage: "guitars",
                help: "The genre Apple Music holds for this \(entity) (the most common one, for an album or artist)."
            ),
        ]
    }
}
