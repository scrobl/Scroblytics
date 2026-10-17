import AppKit
import SwiftUI

/// What every card shares: the gold accent, the blurred-artwork background and the optional identity footer.
enum ShareCardStyle {
    static let gold = Color(red: 1.0, green: 0.82, blue: 0.32)
}

extension ShareCardStyle {
    /// A milestone tier's colour on a dark card: the app's tier colours, gold for the prestige tiers (which the app marks with its accent).
    static func milestoneColor(_ tier: Int) -> Color {
        MilestoneFormatting.isPrestigeMilestone(tier) ? gold : MilestoneFormatting.milestoneColor(tier)
    }
}

/// What stands in for the picture of something that has none (the library's total): a trophy on a gold tile, or the Last.fm logo.
struct SharePlaceholderIcon: View {
    let icon: ShareIcon
    let side: CGFloat

    var body: some View {
        switch icon {
        case .trophy:
            ZStack {
                RoundedRectangle(cornerRadius: side * 0.12, style: .continuous).fill(ShareCardStyle.gold.opacity(0.18))
                Image(systemName: "trophy.fill")
                    .font(.system(size: side * 0.5))
                    .foregroundStyle(ShareCardStyle.gold)
            }
            .frame(width: side, height: side)
        case .lastfm:
            LastfmMark(size: side, style: .circle)
        }
    }
}

struct ShareCardBackground: View {
    let size: CGSize
    /// The picture to blur behind everything.
    let imageURL: String?
    let images: [String: NSImage]

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.05, green: 0.05, blue: 0.07), Color(red: 0.10, green: 0.09, blue: 0.13)], startPoint: .top, endPoint: .bottom)
            if let imageURL, let image = images[imageURL] {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .blur(radius: 70)
                    .opacity(0.34)
                    .clipped()
            }
            Rectangle().fill(Color.black.opacity(0.35))
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}

struct ShareCardFooter: View {
    let identity: ShareIdentity

    static func isShown(_ identity: ShareIdentity) -> Bool { identity.showsFooter || !(identity.name ?? "").isEmpty }

    var body: some View {
        HStack {
            if let name = identity.name, !name.isEmpty {
                HStack(spacing: 12) {
                    LastfmMark(size: 34, style: identity.logo)
                    Text(name)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.75))
                        .lineLimit(1)
                }
            }
            Spacer()
            if identity.showsFooter {
                Text("Scroblytics")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
        }
    }
}

/// The card for whatever a Share button made: a list for a chart, a profile for one artist, album or track.
struct ShareCardView: View {
    let card: ShareCard
    let options: ShareOptions
    let identity: ShareIdentity
    let images: [String: NSImage]

    var body: some View {
        if card.drawsTree(for: options) {
            ShareTreeCardView(card: card, options: options, identity: identity, images: images)
        } else if card.profile?.highlights.isEmpty == false {
            ShareRecapCardView(card: card, options: options, identity: identity, images: images)
        } else if card.profile != nil {
            ShareProfileCardView(card: card, options: options, identity: identity, images: images)
        } else {
            ShareTopListCardView(card: card, options: options, identity: identity, images: images)
        }
    }
}

/// The top of a list card: the kind and date line, the title (the person's own when they typed one), the measure, and the movement note.
struct ShareListHeader: View {
    let card: ShareCard
    let options: ShareOptions

    private var gold: Color { ShareCardStyle.gold }
    private var showsMovementCaption: Bool { options.showMovement && card.hasMovement }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                if !card.period.isEmpty {
                    Text(card.period.uppercased())
                        .font(.system(size: 26, weight: .bold))
                        .tracking(3)
                        .foregroundStyle(gold)
                        .lineLimit(1)
                }
                Spacer(minLength: 16)
                if options.showDate {
                    Text(card.generatedAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.62))
                        .lineLimit(1)
                }
            }
            // A sentence (a question put to Ask) is longer than "Top Albums": smaller, on up to two lines.
            let shownTitle = card.displayTitle(for: options)
            let longTitle = shownTitle.count > 24
            Text(shownTitle)
                .font(.system(size: longTitle ? 56 : 76, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(longTitle ? 2 : 1)
                .minimumScaleFactor(0.5)
            if !card.measure.isEmpty {
                Text(card.measure)
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.68))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            if showsMovementCaption, let note = card.movementNote {
                HStack(spacing: 8) {
                    Text("▲▼")
                        .font(.system(size: 22, weight: .bold))
                    Text("Movement \(note)")
                        .font(.system(size: 24, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .foregroundStyle(Color.white.opacity(0.5))
                .padding(.top, 2)
            }
        }
    }
}

/// The one dark card design. Sizes are in points (see `ShareSize.points`); the renderer scales to pixels. Everything it draws is handed
/// in (pictures already loaded), because an image renderer draws one frame and waits for nothing.
struct ShareTopListCardView: View {
    let card: ShareCard
    let options: ShareOptions
    let identity: ShareIdentity
    let images: [String: NSImage]

    private var rows: [ShareRow] { card.visibleRows(for: options) }
    private var size: CGSize { options.size.points }
    private var columns: Int { options.size.columns }
    private let margin: CGFloat = 64
    private var gold: Color { ShareCardStyle.gold }

    var body: some View {
        ZStack {
            background
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.bottom, 28)
                list
                if hasFooter { ShareCardFooter(identity: identity).padding(.top, 20) }
            }
            .padding(margin)
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .dark)
    }

    private var hasFooter: Bool { ShareCardFooter.isShown(identity) }

    // MARK: Background

    private var background: some View {
        ShareCardBackground(size: size, imageURL: rows.first?.imageURL, images: images)
    }

    private var header: some View { ShareListHeader(card: card, options: options) }

    private var showsColumnLabel: Bool { !card.valueColumns.isEmpty && options.showValues }

    // MARK: Rows

    private var list: some View {
        GeometryReader { proxy in
            let perColumn = max(1, Int((Double(rows.count) / Double(columns)).rounded(.up)))
            let gap: CGFloat = columns > 1 ? 56 : 0
            let columnWidth = (proxy.size.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
            // A query card says which column its numbers are, since "377" alone doesn't.
            let labelHeight: CGFloat = showsColumnLabel ? 36 : 0
            let rowHeight = min((proxy.size.height - labelHeight) / CGFloat(perColumn), 190)
            HStack(alignment: .top, spacing: gap) {
                ForEach(0..<columns, id: \.self) { column in
                    VStack(spacing: 0) {
                        if showsColumnLabel {
                            HStack {
                                Spacer(minLength: 0)
                                Text(card.valueName(for: options).uppercased())
                                    .font(.system(size: 22, weight: .bold))
                                    .tracking(2)
                                    .foregroundStyle(gold)
                                    .lineLimit(1)
                            }
                            .frame(height: labelHeight)
                        }
                        ForEach(Array(rows.enumerated()).filter { $0.offset / perColumn == column }, id: \.offset) { _, row in
                            rowView(row, height: rowHeight, width: columnWidth)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(width: columnWidth)
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: ShareRow, height: CGFloat, width: CGFloat) -> some View {
        let art = height - 14
        let titleSize = min(max(height * 0.33, 20), 40) * (card.compactTitles ? 0.84 : 1)
        HStack(spacing: height * 0.16) {
            if card.numbered {
                Text("\(row.rank)")
                    .font(.system(size: min(max(height * 0.40, 22), 48), weight: .heavy, design: .rounded))
                    .foregroundStyle(row.rank == 1 ? gold : Color.white.opacity(0.8))
                    .frame(width: height * 0.62, alignment: .center)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            }
            artwork(row, side: art)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.system(size: titleSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let subtitle = card.detailLine(row, options: options) {
                    // A line that carries why a track was chosen is longer than an artist's name: smaller, on up to two lines.
                    let withNote = options.showNotes && row.note != nil
                    Text(subtitle)
                        .font(.system(size: titleSize * (withNote ? 0.56 : 0.72), weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.62))
                        .lineLimit(withNote ? 2 : 1)
                }
            }
            Spacer(minLength: 8)
            if options.showMovement, card.hasMovement { changeBadge(row.change, size: titleSize * 0.62) }
            if options.showValues {
                if let milestone = row.milestone {
                    milestonePill(milestone, size: titleSize)
                } else {
                    Text(card.valueText(row, options: options))
                        .font(.system(size: titleSize * 0.8, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Color.white.opacity(0.85))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
        .frame(width: width, height: height)
    }

    /// A milestone as the Milestones page draws it: a trophy and the tier's number in the tier's colour, with the date beside it.
    private func milestonePill(_ milestone: ShareMilestone, size: CGFloat) -> some View {
        let color = ShareCardStyle.milestoneColor(milestone.tier)
        return HStack(spacing: size * 0.4) {
            HStack(spacing: size * 0.18) {
                Image(systemName: "trophy.fill").font(.system(size: size * 0.55, weight: .semibold))
                Text(MilestoneFormatting.formatMilestone(milestone.tier))
                    .font(.system(size: size * 0.7, weight: .bold, design: .rounded).monospacedDigit())
            }
            .fixedSize()
            .padding(.horizontal, size * 0.45).padding(.vertical, size * 0.18)
            .foregroundStyle(color)
            .background(color.opacity(0.22), in: Capsule())
            .overlay(Capsule().stroke(MilestoneFormatting.isPrestigeMilestone(milestone.tier) ? ShareCardStyle.gold : .clear, lineWidth: 2))
            .frame(width: size * 3.7, alignment: .trailing)
            Text(milestone.date)
                .font(.system(size: size * 0.62, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.7))
                .frame(width: size * 4.4, alignment: .leading)
        }
        .lineLimit(1)
        .fixedSize()
    }

    @ViewBuilder
    private func artwork(_ row: ShareRow, side: CGFloat) -> some View {
        Group {
            if let url = row.imageURL, let image = images[url] {
                Image(nsImage: image).resizable().scaledToFill()
            } else if card.iconChoice {
                SharePlaceholderIcon(icon: options.icon, side: side)
            } else {
                ZStack {
                    Color.white.opacity(0.10)
                    Image(systemName: "music.note")
                        .font(.system(size: side * 0.36))
                        .foregroundStyle(Color.white.opacity(0.35))
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.12, style: .continuous))
    }

    @ViewBuilder
    private func changeBadge(_ change: ShareChange, size: CGFloat) -> some View {
        switch change {
        case .none:
            EmptyView()
        case .same:
            badge("–", color: Color.white.opacity(0.18), foreground: Color.white.opacity(0.7), size: size)
        case .up(let n):
            badge("▲\(n)", color: Color(red: 0.20, green: 0.70, blue: 0.40), foreground: .white, size: size)
        case .down(let n):
            badge("▼\(n)", color: Color(red: 0.85, green: 0.28, blue: 0.30), foreground: .white, size: size)
        case .new:
            badge("NEW", color: Color(red: 0.55, green: 0.38, blue: 0.90), foreground: .white, size: size)
        }
    }

    private func badge(_ text: String, color: Color, foreground: Color, size: CGFloat) -> some View {
        Text(text)
            .font(.system(size: max(size, 14), weight: .bold, design: .rounded))
            .foregroundStyle(foreground)
            .padding(.horizontal, size * 0.55)
            .padding(.vertical, size * 0.22)
            .background(color, in: Capsule())
            .fixedSize()
    }
}
