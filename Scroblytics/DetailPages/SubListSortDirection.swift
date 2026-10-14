import Foundation

/// Which way each of the sub-list's sorts runs to begin with, and how to say the other way: used by the sort-direction
/// button. (The album table has its own copy of the same rules for its own sorts.)
extension SubListSort {
    /// A to Z and first to last read upward; the others start with the most, newest or latest first.
    var startsAscending: Bool {
        switch self {
        case .alphabetical, .trackOrder: true
        case .mostPlayed, .recentlyPlayed, .releaseYear: false
        }
    }

    func directionLabel(ascending: Bool) -> String {
        switch self {
        case .alphabetical: ascending ? "A to Z" : "Z to A"
        case .trackOrder: ascending ? "First to last" : "Last to first"
        case .mostPlayed: ascending ? "Fewest first" : "Most first"
        case .recentlyPlayed, .releaseYear: ascending ? "Oldest first" : "Newest first"
        }
    }
}
