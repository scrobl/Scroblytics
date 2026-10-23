import AppKit
import SwiftUI

/// The card for a period (a Timeline month): its totals, the top artist, album and track with their pictures, and the milestones
/// reached. Same dark design as the others; everything it draws is handed in.
struct ShareRecapCardView: View {
    let card: ShareCard
    let options: ShareOptions
    let identity: ShareIdentity
    let images: [String: NSImage]

    private var profile: ShareProfile { card.profile ?? ShareProfile(kind: "", subtitle: "", heroImageURL: nil, stats: [], chips: [], trend: []) }
    private var size: CGSize { options.size.points }
    private var isWide: Bool { options.size == .wide }
    private let margin: CGFloat = 64
    private var gold: Color { ShareCardStyle.gold }

    /// The picture behind everything: the first pick that has one (the album, for a month).
    private var backgroundURL: String? {
        (profile.highlights.first { $0.role.contains("Album") } ?? profile.highlights.first { $0.imageURL != nil })?.imageURL
    }

    var body: some View {
        ZStack {
            ShareCardBackground(size: size, imageURL: backgroundURL, images: images)
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

    private var narrowBody: some View {
        let square = options.size == .square
        return VStack(alignment: .leading, spacing: square ? 22 : 28) {
            kickerRow
            Text(card.displayTitle(for: options))
                .font(.system(size: 84, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            ShareStatGrid(stats: card.visibleStats(for: options), columns: 4, valueSize: 40)
            VStack(spacing: 18) {
                ForEach(Array(profile.highlights.enumerated()), id: \.offset) { _, pick in
                    highlight(pick, side: square ? 130 : 190)
                }
            }
            ShareChipFlow(chips: profile.chips, maxRows: square ? 2 : 3)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var wideBody: some View {
        HStack(alignment: .top, spacing: 64) {
            VStack(spacing: 24) {
                ForEach(Array(profile.highlights.enumerated()), id: \.offset) { _, pick in
                    highlight(pick, side: 220)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 30) {
                kickerRow
                Text(card.displayTitle(for: options))
                    .font(.system(size: 96, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                ShareStatGrid(stats: card.visibleStats(for: options), columns: 2, valueSize: 46)
                ShareChipFlow(chips: profile.chips, maxRows: 4)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// The date alone, top right (the month's name is the title, so there is no label above it); nothing when the date is switched off.
    @ViewBuilder
    private var kickerRow: some View {
        if options.showDate {
            HStack {
                Spacer(minLength: 0)
                Text(card.generatedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.62))
                    .lineLimit(1)
            }
        }
    }

    private func highlight(_ pick: ShareHighlight, side: CGFloat) -> some View {
        HStack(spacing: 28) {
            Group {
                if let url = pick.imageURL, let image = images[url] {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    ZStack {
                        Color.white.opacity(0.10)
                        Image(systemName: pick.role.contains("Artist") ? "person.fill" : "music.note")
                            .font(.system(size: side * 0.34))
                            .foregroundStyle(Color.white.opacity(0.35))
                    }
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: side * 0.08, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
            VStack(alignment: .leading, spacing: 4) {
                Text(pick.role.uppercased())
                    .font(.system(size: 20, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(gold)
                Text(pick.title)
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                if let subtitle = pick.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.65))
                        .lineLimit(1)
                }
                if options.showValues {
                    Text(pick.value)
                        .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Color.white.opacity(0.8))
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
