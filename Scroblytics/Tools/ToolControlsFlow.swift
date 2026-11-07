import SwiftUI

private struct ToolControlsTrailing: LayoutValueKey {
    static let defaultValue = false
}

extension View {
    /// Marks a control (usually a group of buttons) to sit at the right end of its row in a `ToolControlsFlow` when it shares the row with
    /// others; on a row of its own it stays at the left.
    func toolControlsTrailing() -> some View { layoutValue(key: ToolControlsTrailing.self, value: true) }
}

/// Lays a tool's header controls out left to right across the whole width, and wraps them onto further rows as the width shrinks, so a
/// wide window uses its width and a narrow one stacks the controls. Each control keeps its own natural size; controls in a row are
/// centred on each other, since pickers, checkboxes and buttons differ in height.
struct ToolControlsFlow: Layout {
    var spacing: CGFloat = 16
    var rowSpacing: CGFloat = 10

    private struct Arrangement {
        var frames: [CGRect]
        var size: CGSize
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(width: bounds.width, subviews: subviews)
        for (index, frame) in arrangement.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width proposed: CGFloat?, subviews: Subviews) -> Arrangement {
        let limit = proposed ?? .infinity
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var rows: [[Int]] = [[]]
        var x: CGFloat = 0
        for index in subviews.indices {
            let width = sizes[index].width
            if !rows[rows.count - 1].isEmpty, x + width > limit {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append(index)
            x += width + spacing
        }
        var frames = [CGRect](repeating: .zero, count: subviews.count)
        var y: CGFloat = 0
        var widest: CGFloat = 0
        var usedRows = 0
        for row in rows where !row.isEmpty {
            let height = row.map { sizes[$0].height }.max() ?? 0
            var cursor: CGFloat = 0
            for index in row {
                let size = sizes[index]
                var originX = cursor
                if subviews[index][ToolControlsTrailing.self], row.count > 1, limit.isFinite { originX = max(cursor, limit - size.width) }
                frames[index] = CGRect(x: originX, y: y + (height - size.height) / 2, width: size.width, height: size.height)
                cursor = originX + size.width + spacing
                widest = max(widest, originX + size.width)
            }
            y += height + rowSpacing
            usedRows += 1
        }
        let width = (proposed?.isFinite == true) ? proposed! : widest
        return Arrangement(frames: frames, size: CGSize(width: width, height: usedRows == 0 ? 0 : y - rowSpacing))
    }
}
