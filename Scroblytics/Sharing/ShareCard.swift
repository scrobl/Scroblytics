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
    /// Whether the rows are a ranking, so each shows its number. A list of milestones or months is in time order, not ranked.
    var numbered = true
    /// Whether an item with no picture of its own (the library's total) can show a trophy or the Last.fm logo, chosen in the preview.
    var iconChoice = false
    /// Set for a card about one artist, album or track (numbers, rank chips, trend) instead of a ranked list.
    var profile: ShareProfile? = nil
}

/// What a card about a single artist, album or track carries beyond its title: the page's own numbers, rank chips and trend line.
struct ShareProfile: Sendable, Equatable {
    /// "Artist", "Album" or "Track".
    var kind: String
    /// The artist (and album) under the title; empty on an artist page.
    var subtitle: String
    var heroImageURL: String?
    /// One big line under the title, for a card that is about a single figure ("1,000 plays" for a milestone).
    var headline: String? = nil
    /// When the headline is a milestone: its tier, for the colour.
    var headlineTier: Int? = nil
    /// The headline numbers and the page's facts, as tiles.
    var stats: [ShareStat]
    var chips: [ShareChip]
    /// The picks a recap card is about (a month's top artist, album and track). When there are any, the card is a recap: no single hero
    /// picture, the picks in its place.
    var highlights: [ShareHighlight] = []
    /// Plays per bucket over the period, oldest first; fewer than two points draws no line.
    var trend: [Int]
}

struct ShareHighlight: Sendable, Equatable {
    /// "Top Artist", "Top Album", "Top Track".
    var role: String
    var title: String
    var subtitle: String?
    /// "123 plays" or "3d 4h 12m".
    var value: String
    var imageURL: String?
}

struct ShareStat: Sendable, Equatable {
    var label: String
    var value: String
}

struct ShareChip: Sendable, Equatable {
    enum Kind: Sendable, Equatable { case rank, milestone }
    var kind: Kind
    var text: String
    /// A milestone chip: its tier (100, 250, 1000…), which picks the colour as the app draws it, and what follows the number.
    var tier: Int? = nil
    var detail: String? = nil
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
    /// A milestone row: the value is drawn as a coloured pill for the tier, with the date beside it.
    var milestone: ShareMilestone? = nil
}

struct ShareMilestone: Sendable, Equatable {
    /// 100, 250, 1000… (picks the pill's colour).
    var tier: Int
    /// When it was reached, as shown.
    var date: String
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
    /// How many stat tiles a profile card has room for.
    var statLimit: Int {
        switch self {
        case .square: 6
        case .portrait: 9
        case .wide: 8
        }
    }
}

/// The picture for an item that has none of its own (the library's total): a trophy or the Last.fm logo.
enum ShareIcon: String, Codable, CaseIterable, Identifiable, Sendable {
    case trophy, lastfm

    var id: String { rawValue }
    var label: String { self == .trophy ? "Trophy" : "Last.fm" }
}

/// What the person chose on the popover. Remembered per kind of card (`ShareSettings`).
struct ShareOptions: Codable, Equatable, Sendable {
    var size = ShareSize.square
    var rowCount = 10
    var showValues = true
    var showMovement = true
    var showDate = true
    var icon = ShareIcon.trophy

    init(size: ShareSize = .square, rowCount: Int = 10, showValues: Bool = true, showMovement: Bool = true, showDate: Bool = true, icon: ShareIcon = .trophy) {
        self.size = size
        self.rowCount = rowCount
        self.showValues = showValues
        self.showMovement = showMovement
        self.showDate = showDate
        self.icon = icon
    }

    /// Options remembered by earlier versions lack newer keys; each missing one takes its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        size = try c.decodeIfPresent(ShareSize.self, forKey: .size) ?? .square
        rowCount = try c.decodeIfPresent(Int.self, forKey: .rowCount) ?? 10
        showValues = try c.decodeIfPresent(Bool.self, forKey: .showValues) ?? true
        showMovement = try c.decodeIfPresent(Bool.self, forKey: .showMovement) ?? true
        showDate = try c.decodeIfPresent(Bool.self, forKey: .showDate) ?? true
        icon = try c.decodeIfPresent(ShareIcon.self, forKey: .icon) ?? .trophy
    }

    static let rowCounts = [5, 10, 15, 20]
}

/// The two optional lines about the person, both off unless turned on.
struct ShareIdentity: Equatable, Sendable {
    /// Their Last.fm name when they chose to show it.
    var name: String?
    var showsFooter = false
    /// The mark in front of the name.
    var logo = LastfmLogoStyle.circle

    static let anonymous = ShareIdentity(name: nil, showsFooter: false)
}

extension ShareCard {
    /// The rows a card shows for these options: the first `rowCount`, never more than exist.
    func visibleRows(for options: ShareOptions) -> [ShareRow] {
        Array(rows.prefix(max(1, options.rowCount)))
    }

    /// The stat tiles a profile card shows at this size.
    func visibleStats(for options: ShareOptions) -> [ShareStat] {
        Array((profile?.stats ?? []).prefix(options.size.statLimit))
    }

    /// The pictures a card with these options draws, for the renderer to load first: a list's visible rows (the first one is also the
    /// background), a profile's one hero picture.
    func pictureURLs(for options: ShareOptions) -> [String?] {
        if let profile { return [profile.heroImageURL] + profile.highlights.map(\.imageURL) }
        return visibleRows(for: options).map(\.imageURL)
    }

    /// Whether the Rows and values options mean anything for this card.
    var isList: Bool { profile == nil }
}
