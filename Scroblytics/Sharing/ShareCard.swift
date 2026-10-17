import Foundation

/// What a Share button turns into an image or text: plain values, built from what a screen already shows, so a card always equals
/// what the person sees and the builders can be checked without a window.
struct ShareCard: Sendable, Equatable {
    /// "Top Artists", "Wilco"…
    var title: String
    /// The period it covers: "Year to date".
    var period: String
    /// How it is measured: "Ranked by scrobbles".
    var measure: String
    var rows: [ShareRow]
    /// What the value column is called in text ("Plays", "Time").
    var valueLabel: String
    /// Whether the rows carry movement against an earlier period (so the movement switch means something).
    var hasMovement: Bool
    /// What the movement is measured against, to follow "Movement ": "since Oct 10, 2026" (against the chart as it stood then). Each
    /// screen words it for its own kind of comparison.
    var movementNote: String? = nil
    /// When the card was made, shown as its date.
    var generatedAt = Date()
    /// Stable per kind of card; the remembered options are stored under it.
    var kindID: String
}

struct ShareRow: Sendable, Equatable {
    var rank: Int
    var title: String
    /// The artist, for an album or track.
    var subtitle: String?
    /// "1,204" or "3d 4h 12m".
    var value: String
    var change: ShareChange
    var imageURL: String?
}

enum ShareChange: Sendable, Equatable {
    /// No comparison period exists.
    case none
    case same
    case up(Int)
    case down(Int)
    case new
}

enum ShareSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case square, portrait, wide

    var id: String { rawValue }
    var label: String {
        switch self {
        case .square: "Square"
        case .portrait: "Portrait"
        case .wide: "Wide"
        }
    }
    /// The card's design size in points; the PNG is this at the render scale (2x by default).
    var points: CGSize {
        switch self {
        case .square: CGSize(width: 1080, height: 1080)
        case .portrait: CGSize(width: 1080, height: 1350)
        case .wide: CGSize(width: 1920, height: 1080)
        }
    }
    /// Columns of rows on the card: a wide card splits its list in two.
    var columns: Int { self == .wide ? 2 : 1 }
}

/// What the person chose on the popover. Remembered per kind of card (`ShareSettings`).
struct ShareOptions: Codable, Equatable, Sendable {
    var size = ShareSize.square
    var rowCount = 10
    var showValues = true
    var showMovement = true
    var showDate = true

    static let rowCounts = [5, 10, 15, 20]
}

/// The two optional lines about the person, both off unless turned on.
struct ShareIdentity: Equatable, Sendable {
    /// Their Last.fm name when they chose to show it.
    var name: String?
    var showsFooter = false

    static let anonymous = ShareIdentity(name: nil, showsFooter: false)
}

extension ShareCard {
    /// The rows a card shows for these options: the first `rowCount`, never more than exist.
    func visibleRows(for options: ShareOptions) -> [ShareRow] {
        Array(rows.prefix(max(1, options.rowCount)))
    }
}
