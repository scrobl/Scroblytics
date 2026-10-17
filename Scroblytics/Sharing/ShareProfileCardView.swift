import AppKit
import SwiftUI

/// The card for one artist, album or track: its picture, name, the page's numbers as tiles, rank-by-year and milestone chips, and the
/// trend line. Same dark design as the list card; everything it draws is handed in.
struct ShareProfileCardView: View {
    let card: ShareCard
    let options: ShareOptions
    let identity: ShareIdentity
    let images: [String: NSImage]

    private var profile: ShareProfile { card.profile ?? ShareProfile(kind: "", subtitle: "", heroImageURL: nil, stats: [], chips: [], trend: []) }
    private var size: CGSize { options.size.points }
    private var isWide: Bool { options.size == .wide }
    private let margin: CGFloat = 64
    private var gold: Color { ShareCardStyle.gold }
    private var stats: [ShareStat] { card.visibleStats(for: options) }

    var body: some View {
        ZStack {
            ShareCardBackground(size: size, imageURL: profile.heroImageURL, images: images)
            VStack(alignment: .leading, spacing: 0) {
                if isWide { wideBody } else { narrowBody }
                if ShareCardFooter.isShown(identity) {
                    ShareCardFooter(identity: identity).padding(.top, 20)
                }
            }
            .padding(margin)
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Layouts

    private var narrowBody: some View {
        let square = options.size == .square
        return VStack(alignment: .leading, spacing: square ? 26 : 32) {
            kickerRow
            HStack(alignment: .center, spacing: 36) {
                hero(side: square ? 250 : 320)
                titleBlock(titleSize: square ? 62 : 66)
            }
            statGrid(columns: 3, valueSize: square ? 40 : 44)
            chips
            trend(min: square ? 110 : 190, max: square ? 170 : 420)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var wideBody: some View {
        HStack(alignment: .top, spacing: 64) {
            VStack(alignment: .leading, spacing: 0) {
                hero(side: 640)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 30) {
                kickerRow
                titleBlock(titleSize: 84)
                statGrid(columns: 4, valueSize: 40)
                chips
                trend(min: 170, max: 360)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: Pieces

    private var kickerRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(profile.kind) · \(card.period)".uppercased())
                .font(.system(size: 26, weight: .bold))
                .tracking(3)
                .foregroundStyle(gold)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Spacer(minLength: 16)
            if options.showDate {
                Text(card.generatedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.62))
                    .lineLimit(1)
            }
        }
    }

    private func titleBlock(titleSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(card.title)
                .font(.system(size: titleSize, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(3)
                .minimumScaleFactor(0.5)
            if !profile.subtitle.isEmpty {
                Text(profile.subtitle)
                    .font(.system(size: titleSize * 0.46, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.68))
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func hero(side: CGFloat) -> some View {
        Group {
            if let url = profile.heroImageURL, let image = images[url] {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.white.opacity(0.10)
                    Image(systemName: profile.kind == "Artist" ? "person.fill" : "music.note")
                        .font(.system(size: side * 0.34))
                        .foregroundStyle(Color.white.opacity(0.35))
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.06, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
    }

    private func statGrid(columns: Int, valueSize: CGFloat) -> some View {
        let tiles = stats
        let rows = stride(from: 0, to: tiles.count, by: columns).map { Array(tiles[$0..<min($0 + columns, tiles.count)]) }
        return VStack(spacing: 14) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 14) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, stat in tile(stat, valueSize: valueSize) }
                    // A short last row keeps its tiles the same width as the rest.
                    ForEach(0..<(columns - row.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 0) }
                }
            }
        }
    }

    private func tile(_ stat: ShareStat, valueSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(stat.label.uppercased())
                .font(.system(size: 18, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(Color.white.opacity(0.55))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(stat.value)
                .font(.system(size: valueSize, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.45)
                .frame(height: valueSize * 1.25, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private var chips: some View {
        if !profile.chips.isEmpty {
            TagFlowLayout(spacing: 12) {
                ForEach(Array(profile.chips.prefix(8).enumerated()), id: \.offset) { _, chip in
                    HStack(spacing: 8) {
                        Image(systemName: chip.kind == .rank ? "medal.fill" : "trophy.fill")
                            .font(.system(size: 22, weight: .semibold))
                        Text(chip.text)
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                    }
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .foregroundStyle(chip.kind == .rank ? Color(red: 0.78, green: 0.62, blue: 1.0) : gold)
                    .background((chip.kind == .rank ? Color(red: 0.55, green: 0.38, blue: 0.90) : gold).opacity(0.20), in: Capsule())
                }
            }
        }
    }

    @ViewBuilder
    private func trend(min: CGFloat, max: CGFloat) -> some View {
        if profile.trend.count >= 2 {
            ShareTrendLine(values: profile.trend)
                .frame(minHeight: min, maxHeight: max)
        }
    }
}

/// A filled line of plays over the period, drawn by hand (no chart framework) so it renders the same everywhere.
struct ShareTrendLine: View {
    let values: [Int]

    var body: some View {
        GeometryReader { proxy in
            let points = Self.points(values, in: proxy.size)
            ZStack {
                Path { path in
                    guard let first = points.first, let last = points.last else { return }
                    path.move(to: CGPoint(x: first.x, y: proxy.size.height))
                    points.forEach { path.addLine(to: $0) }
                    path.addLine(to: CGPoint(x: last.x, y: proxy.size.height))
                    path.closeSubpath()
                }
                .fill(LinearGradient(colors: [ShareCardStyle.gold.opacity(0.38), ShareCardStyle.gold.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    points.dropFirst().forEach { path.addLine(to: $0) }
                }
                .stroke(ShareCardStyle.gold, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
        }
    }

    /// The line's points: oldest at the left edge, the busiest bucket at the top.
    static func points(_ values: [Int], in size: CGSize) -> [CGPoint] {
        guard values.count >= 2 else { return [] }
        let peak = Double(max(values.max() ?? 1, 1))
        let inset: CGFloat = 4
        let height = max(size.height - inset * 2, 1)
        return values.enumerated().map { index, value in
            CGPoint(
                x: size.width * CGFloat(index) / CGFloat(values.count - 1),
                y: inset + height * (1 - CGFloat(Double(max(value, 0)) / peak))
            )
        }
    }
}
