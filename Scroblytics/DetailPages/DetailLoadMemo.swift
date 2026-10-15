import Foundation

/// What a detail page last finished loading, and when. The pages start their loads from `.task`, which SwiftUI runs again every
/// time a tab's content reappears, so switching back to a tab used to blank each page in its Tools or Library stack and load all
/// of it again (seconds of main-thread work for a stack of a few pages). A page that is only reappearing, for the same item and
/// within `freshFor`, keeps what it has; anything that changes the data (a sync, a correction, a new range) reloads it by its own
/// handlers, as before.
struct DetailLoadMemo {
    /// Long enough to cover going away and coming back, short enough that a stale page can't outlive a missed update.
    static let freshFor: TimeInterval = 600

    private var id: String?
    private var loadedAt: Date?

    func isFresh(for id: String, now: Date = Date()) -> Bool {
        guard self.id == id, let loadedAt else { return false }
        return now.timeIntervalSince(loadedAt) < Self.freshFor
    }

    mutating func record(_ id: String, now: Date = Date()) {
        self.id = id
        loadedAt = now
    }

    /// Forget it, so the next appearance loads again.
    mutating func reset() {
        id = nil
        loadedAt = nil
    }
}
