import AppKit
import SwiftUI

/// The space a natively drawn chart has on its card, in the units the chart is laid out in. The card draws the chart at `logical` size
/// and scales it up by `zoom`, so its text and marks are as large on the card as the card needs while the chart still lays itself out
/// as the screen does (columns, labels, key).
struct ShareNativeLayout: Sendable {
    var logical: CGSize
    var zoom: CGFloat
    var shape: ShareSize

    var isWide: Bool { shape == .wide }
}

/// One thing a person can include, exclude or choose on a natively drawn chart card, shown as a control in the share preview and stored
/// in `ShareOptions` under its id.
struct ShareNativeControl: Identifiable, Sendable {
    enum Kind: Sendable {
        case toggle(defaultValue: Bool)
        case count(range: ClosedRange<Int>, defaultValue: Int)
        case choice([String], defaultValue: String)
    }

    let id: String
    let label: String
    let kind: Kind
}

/// A chart drawn for a card instead of photographed from the window: the card holds how to draw it at the card's own size from the numbers
/// the chart has already worked out, a sentence about what it shows, the options that make sense for it, and the text to copy.
/// Equal only to itself (a new one is made each time the Share button is pressed).
final class ShareNativeChart: @unchecked Sendable, Equatable {
    let id: String
    /// The sentence the card prints about the chart ("Rain is your music weather: +23% against an average day"); the person can retype it.
    let caption: String
    /// The same sentence with the comparison against the previous period in it, used only when the person includes the comparison.
    let comparisonCaption: String?
    /// How the numbers were worked out, in a line the person can leave off.
    let footnote: String?
    /// The shape the chart looks best in; the preview opens on it.
    let preferredSize: ShareSize
    let controls: [ShareNativeControl]
    /// The pictures the chart draws (artwork), loaded before it is drawn.
    let imageURLs: [String?]
    /// Plain lines for Copy as Text and Markdown.
    let textLines: [String]
    /// How much larger than on screen the chart is drawn on a card of each shape.
    let zoomForShape: @Sendable (ShareSize) -> CGFloat
    let make: @MainActor @Sendable (ShareNativeLayout, ShareOptions, [String: NSImage]) -> AnyView
    /// A card that draws the whole card itself (its own header, figures and chart) instead of the common frame around `make`'s chart. It
    /// still has the caption, controls and text of any chart card; it is handed the card, the options, who is on it and the pictures.
    let fullCard: (@MainActor @Sendable (ShareCard, ShareOptions, ShareIdentity, [String: NSImage]) -> AnyView)?
    /// Switches a full card starts with in another state than the usual ("caption" is on, "footnote" off, for every chart card).
    let defaultFlags: [String: Bool]

    init(
        id: String, caption: String, comparisonCaption: String? = nil, footnote: String? = nil, preferredSize: ShareSize = .wide, controls: [ShareNativeControl] = [],
        imageURLs: [String?] = [], textLines: [String] = [], zoomForShape: @escaping @Sendable (ShareSize) -> CGFloat = ShareNativeChart.defaultZoom,
        defaultFlags: [String: Bool] = [:],
        fullCard: (@MainActor @Sendable (ShareCard, ShareOptions, ShareIdentity, [String: NSImage]) -> AnyView)? = nil,
        make: @escaping @MainActor @Sendable (ShareNativeLayout, ShareOptions, [String: NSImage]) -> AnyView
    ) {
        self.fullCard = fullCard
        self.defaultFlags = defaultFlags
        self.id = id
        self.caption = caption
        self.comparisonCaption = comparisonCaption
        self.footnote = footnote
        self.preferredSize = preferredSize
        self.controls = controls
        self.imageURLs = imageURLs
        self.textLines = textLines
        self.zoomForShape = zoomForShape
        self.make = make
    }

    static func == (a: ShareNativeChart, b: ShareNativeChart) -> Bool { a === b }

    /// Roughly twice the screen's size on a square or portrait card (a 1,080-point card holds a chart about 500 points wide), a little less on a wide one.
    static let defaultZoom: @Sendable (ShareSize) -> CGFloat = { shape in shape == .wide ? 1.7 : 1.9 }

    /// The caption the card prints: the person's own, or the written one.
    func displayCaption(for options: ShareOptions) -> String {
        let typed = options.customCaption.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        return options.includesComparison ? (comparisonCaption ?? caption) : caption
    }
}

/// Reading a control's value out of the options, with the control's own default when the person hasn't touched it.
extension ShareOptions {
    func flag(_ id: String, _ defaultValue: Bool) -> Bool { flags[id] ?? defaultValue }
    func number(_ id: String, _ defaultValue: Int) -> Int { numbers[id] ?? defaultValue }
    func pick(_ id: String, _ defaultValue: String) -> String { picks[id] ?? defaultValue }

    /// What the card shows for the two things every natively drawn chart card can leave out.
    var showsCaption: Bool { flag("caption", true) }
    var showsFootnote: Bool { flag("footnote", false) }
    /// Whether a chart card includes its comparison with the previous period (off unless chosen): the second line, grid or river, the
    /// change figures, the comparison in the sentence and the "Compared with…" line under the title.
    var includesComparison: Bool { flag("compare", false) }
}

/// The card around a natively drawn chart: the header (period, title, subtitle, date), the caption, the chart in a panel that takes the rest
/// of the space, the method line and the footer. The chart is laid out at `logical` size and scaled up to fill the panel.
struct ShareNativeChartCardView: View {
    let card: ShareCard
    let native: ShareNativeChart
    let options: ShareOptions
    let identity: ShareIdentity
    let images: [String: NSImage]

    private var size: CGSize { options.size.points }
    private let margin: CGFloat = 64
    private let panelInset: CGFloat = 22

    var body: some View {
        if let full = native.fullCard {
            full(card, options, identity, images)
        } else {
            framed
        }
    }

    private var framed: some View {
        ZStack {
            ShareCardBackground(size: size, imageURL: nil, images: [:])
            VStack(alignment: .leading, spacing: 0) {
                ShareListHeader(card: card, options: options)
                    .padding(.bottom, 14)
                if options.showsCaption, !native.displayCaption(for: options).isEmpty {
                    Text(native.displayCaption(for: options))
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .lineLimit(3)
                        .minimumScaleFactor(0.7)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 16)
                }
                GeometryReader { geometry in
                    let zoom = native.zoomForShape(options.size)
                    let inner = CGSize(width: max(40, geometry.size.width - panelInset * 2), height: max(40, geometry.size.height - panelInset * 2))
                    let logical = CGSize(width: inner.width / zoom, height: inner.height / zoom)
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color.white.opacity(0.06))
                        RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1)
                        native.make(ShareNativeLayout(logical: logical, zoom: zoom, shape: options.size), options, images)
                            .frame(width: logical.width, height: logical.height, alignment: .topLeading)
                            .scaleEffect(zoom, anchor: .topLeading)
                            .frame(width: inner.width, height: inner.height, alignment: .topLeading)
                            .clipped()
                            .padding(panelInset)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if options.showsFootnote, let footnote = native.footnote, !footnote.isEmpty {
                    Text(footnote)
                        .font(.system(size: 21, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.62))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 14)
                }
                if ShareCardFooter.isShown(identity) { ShareCardFooter(identity: identity).padding(.top, 18) }
            }
            .padding(margin)
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .dark)
    }
}
