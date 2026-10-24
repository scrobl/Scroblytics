import AppKit
import SwiftUI

/// A card around a picture of a chart: the period and the chart's name as the header, the chart as large as it fits, the footer.
struct ShareChartCardView: View {
    let card: ShareCard
    let snapshot: ShareSnapshot
    let options: ShareOptions
    let identity: ShareIdentity

    private var fitted: Bool { card.fitsChart(for: options) }
    private var size: CGSize { fitted ? CGSize(width: card.fittedWidth, height: 0) : options.size.points }
    private let margin: CGFloat = 64

    var body: some View {
        if fitted {
            content
                .background { GeometryReader { proxy in ShareCardBackground(size: proxy.size, imageURL: nil, images: [:]) } }
                .frame(width: size.width)
                .environment(\.colorScheme, .dark)
        } else {
            content
                .background { ShareCardBackground(size: size, imageURL: nil, images: [:]) }
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, .dark)
        }
    }

    private var content: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                ShareListHeader(card: card, options: options)
                    .padding(.bottom, card.chartSummary == nil ? 28 : 18)
                if let summary = card.chartSummary { summaryView(summary).padding(.bottom, 10) }
                // The picture keeps its proportions and takes whatever room the header and footer leave, centred in it.
                ZStack {
                    Image(nsImage: snapshot.image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
                }
                .frame(maxWidth: .infinity, maxHeight: fitted ? nil : .infinity)
                if ShareCardFooter.isShown(identity) { ShareCardFooter(identity: identity).padding(.top, 20) }
            }
            .padding(margin)
        }
    }

    /// The headline number, with how it compares in green or red.
    private func summaryView(_ summary: ShareChartSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !summary.headline.isEmpty {
                Text(summary.headline)
                    .font(.system(size: 58, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            if let detail = summary.detail {
                Text(detail)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .lineLimit(2)
            }
            if !summary.legend.isEmpty {
                TagFlowLayout(spacing: 22) {
                    ForEach(Array(summary.legend.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 8) {
                            if item.isLine {
                                RoundedRectangle(cornerRadius: 1).fill(item.color).frame(width: 26, height: 4)
                            } else {
                                Circle().fill(item.color).frame(width: 16, height: 16)
                            }
                            Text(item.label)
                                .font(.system(size: 24, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.7))
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.top, 4)
            }
            if let change = summary.change {
                Text(change)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(summary.isUp ? Color(red: 0.30, green: 0.80, blue: 0.45) : Color(red: 0.95, green: 0.38, blue: 0.38))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
    }
}
