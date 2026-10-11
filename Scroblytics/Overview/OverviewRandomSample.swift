import Foundation

/// Several Overview cards deliberately show a random
/// 3 from their full qualifying candidate pool on every load, not a fixed
/// top-N: "a nostalgic surprise" for On This Day, and matching intent for
/// Climbing/Fading Favorites/Milestones/Album Turnover/Most Recent-Most Often.
/// Applied once per explicit reload (not on every SwiftUI body re-evaluation)
/// by calling this from `OverviewView.reload()` rather than re-rolling on every render.
enum OverviewRandomSample {
    static func pickThree<T>(from items: [T]) -> [T] {
        guard items.count > 3 else { return items }
        return Array(items.shuffled().prefix(3))
    }
}
