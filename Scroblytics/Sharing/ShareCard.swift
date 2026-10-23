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
    /// A query result's columns (their titles): the image shows one of them, chosen in the preview, and the text copies carry all.
    var valueColumns: [String] = []
    /// Which of `valueColumns` the image shows until the person chooses another (the column the query sorts on).
    var defaultValueColumn = 0
    /// The same path as a tree (only a Rabbit Hole path has one); drawn when the person picks the tree layout.
    var tree: ShareTree? = nil
    /// A picture of a chart taken from the window (a Trends chart); the card is that picture with its title and period around it.
    var snapshot: ShareSnapshot? = nil
    /// The chart's headline numbers, printed above its picture.
    var chartSummary: ShareChartSummary? = nil
    /// Track titles drawn a little smaller, so long ones fit (a path of songs).
    var compactTitles = false
    /// Whether an item with no picture of its own (the library's total) can show a trophy or the Last.fm logo, chosen in the preview.
    var iconChoice = false
    /// Set for a card about one artist, album or track (numbers, rank chips, trend) instead of a ranked list.
    var profile: ShareProfile? = nil
}

/// A path drawn as a tree: each step is the track that was taken, with the other tracks that were on offer at that step hanging beside it.
struct ShareTree: Sendable, Equatable {
    struct Pick: Sendable, Equatable {
        var title: String
        var artist: String
        var imageURL: String?
    }

    struct Step: Sendable, Equatable {
        var chosen: Pick
        /// Offered at this step (or explored) and not taken; the first few.
        var others: [Pick]
    }

    var steps: [Step]
}

/// How a card that can be drawn two ways is laid out.
enum ShareLayout: String, Codable, CaseIterable, Identifiable, Sendable {
    case list, tree

    var id: String { rawValue }
    var label: String { self == .list ? "List" : "Tree" }
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
    /// Every value column of a query result, in the order of the card's `valueColumns`; `value` is the one shown on the image by default.
    var values: [String] = []
    /// Why this row is here, for a path ("Last.fm: similar to …"): shown after the artist when the person wants it.
    var note: String? = nil
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
    /// The most rows of a list that stay readable: a square card has less height than a portrait one, and a wide one splits its list in two.
    var maxRows: Int { self == .square ? 15 : 20 }
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
    /// Whether a row's note (why a track was chosen) is shown after its artist, on the image and in the text.
    var showNotes = true
    /// List or tree, for a card that has both.
    var layout = ShareLayout.list
    /// A title the person typed to replace the card's own (a list card); empty keeps the card's. Not remembered: it belongs to one share.
    var customTitle = ""
    /// Which value column of a query card the image shows. Not remembered: the columns differ from one query to the next.
    var valueColumn: Int? = nil

    private enum CodingKeys: String, CodingKey { case size, rowCount, showValues, showMovement, showDate, icon, showNotes, layout }

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
        showNotes = try c.decodeIfPresent(Bool.self, forKey: .showNotes) ?? true
        layout = try c.decodeIfPresent(ShareLayout.self, forKey: .layout) ?? .list
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
    /// Their Last.fm profile picture, shown in front of the name; only ever set together with `name`.
    var avatar: Data?

    static let anonymous = ShareIdentity(name: nil, showsFooter: false)
}

extension ShareCard {
    /// The rows a card shows for these options: the first `rowCount`, never more than exist.
    func visibleRows(for options: ShareOptions) -> [ShareRow] {
        Array(rows.prefix(max(1, min(options.rowCount, options.size.maxRows))))
    }

    /// The stat tiles a profile card shows at this size.
    func visibleStats(for options: ShareOptions) -> [ShareStat] {
        Array((profile?.stats ?? []).prefix(options.size.statLimit))
    }

    /// The pictures a card with these options draws, for the renderer to load first: a list's visible rows (the first one is also the
    /// background), a profile's one hero picture.
    func pictureURLs(for options: ShareOptions) -> [String?] {
        if snapshot != nil { return [] }
        if let profile { return [profile.heroImageURL] + profile.highlights.map(\.imageURL) }
        if options.layout == .tree, let tree {
            return tree.steps.prefix(max(1, options.rowCount)).flatMap { [$0.chosen.imageURL] + $0.others.map(\.imageURL) }
        }
        return visibleRows(for: options).map(\.imageURL)
    }

    /// The value column the image shows with these options, within the card's columns.
    func valueColumnIndex(for options: ShareOptions) -> Int {
        guard !valueColumns.isEmpty else { return 0 }
        return min(max(options.valueColumn ?? defaultValueColumn, 0), valueColumns.count - 1)
    }

    /// What a row's value reads as on the image: the chosen column's value for a query card, the row's own value otherwise.
    func valueText(_ row: ShareRow, options: ShareOptions) -> String {
        guard !valueColumns.isEmpty else { return row.value }
        let index = valueColumnIndex(for: options)
        return row.values.indices.contains(index) ? row.values[index] : "—"
    }

    /// What the value is called with these options ("Plays", or the chosen column's title).
    func valueName(for options: ShareOptions) -> String {
        valueColumns.isEmpty ? valueLabel : valueColumns[valueColumnIndex(for: options)]
    }

    /// The title the card shows with these options: the person's own when they typed one.
    func displayTitle(for options: ShareOptions) -> String {
        let typed = options.customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty || !isList ? title : typed
    }

    /// Whether this card is drawn as a tree with these options.
    func drawsTree(for options: ShareOptions) -> Bool { options.layout == .tree && tree != nil }

    /// What the preview starts from before the person has chosen anything for this kind of card: a chart is wider than tall, so wide.
    var defaultOptions: ShareOptions {
        var options = ShareOptions()
        if snapshot != nil { options.size = .wide }
        return options
    }

    /// Whether any row says why it is there.
    var hasNotes: Bool { rows.contains { $0.note?.isEmpty == false } }

    /// The line under a row's name: the artist, then (when notes are on) why it is there.
    func detailLine(_ row: ShareRow, options: ShareOptions) -> String? {
        let parts = [row.subtitle, options.showNotes ? row.note : nil].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }

    /// Whether the Rows and values options mean anything for this card.
    var isList: Bool { profile == nil && snapshot == nil }
}
