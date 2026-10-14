import SwiftUI

/// One labelled value on a detail page: "Released 12 Sep 2018", "Length 3:44", "Tempo 118 BPM". A fact is always one tile, in one
/// of three states, so the layout doesn't shift when a late lookup (tempo, turnover) arrives.
struct DetailFact: Identifiable {
    enum Value: Equatable {
        /// Still being looked up.
        case loading
        /// Looked up and not found.
        case unknown
        case text(String)
    }

    let id: String
    let label: String
    var value: Value
    /// A second, smaller line (a tempo's time signature and key, an album's turnover cycle).
    var detail: String? = nil
    /// "(corrected)": the value is the person's own correction.
    var corrected = false
    var systemImage: String? = nil
    /// What a tile says while its value is on the way: a lookup says "Checking…", a number that is simply loading a dash.
    var loadingText = "Checking…"
    var help: String? = nil
    /// Adds a pencil that opens the editor for this value.
    var onEdit: (() -> Void)? = nil

    var hasValue: Bool {
        if case .text = value { return true }
        return false
    }

    /// The text a tile shows for its state.
    var displayText: String {
        switch value {
        case .loading: loadingText
        case .unknown: "Unknown"
        case .text(let text): text
        }
    }
}

/// A wrapping grid of fact tiles: as many per row as fit (never more than there are tiles), spread evenly across the width, down to one
/// in a narrow window.
struct DetailFactGrid: View {
    let facts: [DetailFact]
    var minimumTileWidth: CGFloat = 138

    var body: some View {
        EvenGridLayout(minimumWidth: minimumTileWidth, spacing: 10) {
            ForEach(facts) { fact in
                DetailFactTile(fact: fact)
            }
        }
    }
}

/// Lays children out in rows of equal-width cells. The column count is the most that keep every cell at least `minimumWidth`, and no
/// more than the number of children, so a short row fills the width instead of leaving a gap.
struct EvenGridLayout: Layout {
    var minimumWidth: CGFloat
    var spacing: CGFloat

    /// The most columns that fit, stepping down to one that leaves no lonely last row (four tiles are two and two, not three and one).
    static func columnCount(width: CGFloat, count: Int, minimumWidth: CGFloat, spacing: CGFloat) -> Int {
        guard count > 0 else { return 1 }
        guard width.isFinite else { return count }
        let fit = max(1, min(count, Int((width + spacing) / (minimumWidth + spacing))))
        for columns in stride(from: fit, through: 1, by: -1) {
            let lastRow = count % columns
            if lastRow == 0 || lastRow >= (columns + 1) / 2 { return columns }
        }
        return 1
    }

    private func columns(for width: CGFloat, count: Int) -> Int {
        Self.columnCount(width: width, count: count, minimumWidth: minimumWidth, spacing: spacing)
    }

    private struct Arrangement {
        var columns: Int
        var cellWidth: CGFloat
        var rowHeights: [CGFloat]
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> Arrangement {
        let columns = columns(for: width, count: subviews.count)
        let cellWidth = width.isFinite ? (width - spacing * CGFloat(columns - 1)) / CGFloat(columns) : minimumWidth
        var rowHeights: [CGFloat] = []
        for (index, subview) in subviews.enumerated() {
            let height = subview.sizeThatFits(ProposedViewSize(width: cellWidth, height: nil)).height
            if index % columns == 0 { rowHeights.append(height) } else { rowHeights[rowHeights.count - 1] = max(rowHeights[rowHeights.count - 1], height) }
        }
        return Arrangement(columns: columns, cellWidth: cellWidth, rowHeights: rowHeights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minimumWidth * CGFloat(max(1, subviews.count))
        let arrangement = arrange(width: width, subviews: subviews)
        let height = arrangement.rowHeights.reduce(0, +) + spacing * CGFloat(max(0, arrangement.rowHeights.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for (row, rowHeight) in arrangement.rowHeights.enumerated() {
            for column in 0..<arrangement.columns {
                let index = row * arrangement.columns + column
                guard index < subviews.count else { break }
                let x = bounds.minX + CGFloat(column) * (arrangement.cellWidth + spacing)
                subviews[index].place(
                    at: CGPoint(x: x, y: y), anchor: .topLeading,
                    proposal: ProposedViewSize(width: arrangement.cellWidth, height: rowHeight)
                )
            }
            y += rowHeight + spacing
        }
    }
}

struct DetailFactTile: View {
    let fact: DetailFact

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if let systemImage = fact.systemImage {
                    Image(systemName: systemImage).font(AppTypography.supportingDense).foregroundStyle(.secondary)
                }
                Text(fact.label).font(AppTypography.statLabel).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                if let onEdit = fact.onEdit {
                    Button(action: onEdit) {
                        Image(systemName: "pencil").font(AppTypography.supportingDense)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Edit \(fact.label.lowercased())")
                    .accessibilityLabel("Edit \(fact.label.lowercased())")
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(fact.displayText)
                    .font(AppTypography.statValue)
                    .foregroundStyle(fact.hasValue ? .primary : .tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if fact.corrected {
                    Text("corrected").font(AppTypography.supportingDense).foregroundStyle(.secondary)
                }
            }
            // The second line is always laid out when there is one, so a tile does not change height when a value arrives.
            if let detail = fact.detail {
                Text(detail).font(AppTypography.supportingDense).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help(fact.help ?? "")
        .accessibilityElement(children: .combine)
    }
}
