import AppKit
import SwiftUI

/// A Rabbit Hole path as a tree: the track taken at each step down a spine, with the other tracks that were on offer at that step
/// hanging off the line above it, dimmed. Same dark design as the others; everything it draws is handed in.
struct ShareTreeCardView: View {
    let card: ShareCard
    let options: ShareOptions
    let identity: ShareIdentity
    let images: [String: NSImage]

    private var size: CGSize { options.size.points }
    private let margin: CGFloat = 64
    private var gold: Color { ShareCardStyle.gold }
    private var steps: [ShareTree.Step] { Array((card.tree?.steps ?? []).prefix(max(1, options.rowCount))) }

    var body: some View {
        ZStack {
            ShareCardBackground(size: size, imageURL: steps.first?.chosen.imageURL, images: images)
            VStack(alignment: .leading, spacing: 0) {
                ShareListHeader(card: card, options: options)
                    .padding(.bottom, 24)
                treeBody
                if ShareCardFooter.isShown(identity) { ShareCardFooter(identity: identity).padding(.top, 20) }
            }
            .padding(margin)
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .dark)
    }

    private var treeBody: some View {
        GeometryReader { proxy in
            let count = max(steps.count, 1)
            let rowHeight = min(proxy.size.height / CGFloat(count), 150)
            let width = proxy.size.width
            let dot = min(rowHeight * 0.5, 36)
            let spineX = dot / 2
            let chosenX = dot + 22
            let free = width - chosenX
            let gap: CGFloat = 18
            // Narrower cards give the track taken a little more of the row, since the two offers beside it are short.
            let wide = options.size == .wide
            let chosenWidth = free * (wide ? 0.44 : 0.48)
            let altWidth = free * (wide ? 0.24 : 0.22)
            ZStack(alignment: .topLeading) {
                // The spine, then the branches, under the tiles.
                Path { path in
                    guard steps.count > 1 else { return }
                    path.move(to: CGPoint(x: spineX, y: rowHeight / 2))
                    path.addLine(to: CGPoint(x: spineX, y: rowHeight * (CGFloat(steps.count) - 0.5)))
                }
                .stroke(Color.white.opacity(0.28), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    let top = CGFloat(index) * rowHeight
                    if !step.others.isEmpty {
                        Path { path in
                            let busY = top + rowHeight * 0.05
                            let lastX = chosenX + chosenWidth + gap + CGFloat(step.others.count - 1) * (altWidth + gap) + altWidth * 0.12
                            path.move(to: CGPoint(x: spineX, y: busY))
                            path.addLine(to: CGPoint(x: lastX, y: busY))
                            for k in step.others.indices {
                                let x = chosenX + chosenWidth + gap + CGFloat(k) * (altWidth + gap) + altWidth * 0.12
                                path.move(to: CGPoint(x: x, y: busY))
                                path.addLine(to: CGPoint(x: x, y: top + rowHeight * 0.18))
                            }
                        }
                        .stroke(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    }
                }
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    let top = CGFloat(index) * rowHeight
                    ZStack(alignment: .topLeading) {
                        node(number: index + 1, isStart: index == 0, diameter: dot)
                            .position(x: spineX, y: top + rowHeight / 2)
                        chosen(step.chosen, height: rowHeight)
                            .frame(width: chosenWidth, height: rowHeight, alignment: .leading)
                            .offset(x: chosenX, y: top)
                        ForEach(Array(step.others.enumerated()), id: \.offset) { k, other in
                            alternative(other, height: rowHeight, withPicture: altWidth >= 260)
                                .frame(width: altWidth, height: rowHeight, alignment: .leading)
                                .offset(x: chosenX + chosenWidth + gap + CGFloat(k) * (altWidth + gap), y: top)
                        }
                    }
                }
            }
            .frame(width: width, height: proxy.size.height, alignment: .topLeading)
        }
    }

    private func node(number: Int, isStart: Bool, diameter: CGFloat) -> some View {
        ZStack {
            Circle().fill(isStart ? gold : Color(white: 0.16))
            Circle().stroke(isStart ? gold : Color.white.opacity(0.5), lineWidth: 3)
            Text("\(number)")
                .font(.system(size: diameter * 0.52, weight: .heavy, design: .rounded))
                .foregroundStyle(isStart ? Color.black.opacity(0.8) : Color.white)
        }
        .frame(width: diameter, height: diameter)
    }

    private func picture(_ url: String?, side: CGFloat) -> some View {
        Group {
            if let url, let image = images[url] {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.white.opacity(0.10)
                    Image(systemName: "music.note").font(.system(size: side * 0.4)).foregroundStyle(Color.white.opacity(0.35))
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.12, style: .continuous))
    }

    /// The track taken at a step.
    private func chosen(_ pick: ShareTree.Pick, height: CGFloat) -> some View {
        let side = height * 0.8
        let titleSize = min(max(height * 0.3, 16), 34) * (card.compactTitles ? 0.84 : 1)
        return HStack(spacing: height * 0.14) {
            picture(pick.imageURL, side: side)
            VStack(alignment: .leading, spacing: 1) {
                Text(pick.title)
                    .font(.system(size: titleSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(pick.artist)
                    .font(.system(size: titleSize * 0.7))
                    .foregroundStyle(Color.white.opacity(0.62))
                    .lineLimit(1)
            }
        }
    }

    /// A track that was on offer and not taken: smaller and dimmer.
    private func alternative(_ pick: ShareTree.Pick, height: CGFloat, withPicture: Bool) -> some View {
        let side = height * 0.56
        let titleSize = min(max(height * 0.2, 12), 24)
        return HStack(spacing: height * 0.1) {
            // Where the row is too narrow for a picture and readable names, the names win.
            if withPicture { picture(pick.imageURL, side: side) }
            VStack(alignment: .leading, spacing: 0) {
                Text(pick.title)
                    .font(.system(size: titleSize, weight: .medium))
                    .lineLimit(withPicture ? 1 : 2)
                Text(pick.artist)
                    .font(.system(size: titleSize * 0.8))
                    .lineLimit(1)
                    .opacity(0.7)
            }
        }
        .foregroundStyle(Color.white.opacity(0.5))
        .padding(.top, height * 0.12)
    }
}
