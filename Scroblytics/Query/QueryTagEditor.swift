import SwiftUI

/// Picks tags for a tag condition: chosen tags as removable chips, plus a search box that
/// suggests tags that actually exist in the library (with how many items carry each). Only real
/// tags can be added — a made-up one would silently match nothing.
struct QueryTagOperandEditor: View {
    @Binding var tags: [String]
    let vocabulary: [QueryTagSuggestion]

    @State private var text = ""
    @FocusState private var isFocused: Bool

    private var query: String { LastfmTagNormalization.normalize(text) }

    /// Real tags matching the text — prefix matches first, then anywhere — excluding chosen ones.
    private var suggestions: [QueryTagSuggestion] {
        let chosen = Set(tags)
        let pool = vocabulary.filter { !chosen.contains($0.tag) }
        guard !query.isEmpty else { return Array(pool.prefix(8)) }
        let prefix = pool.filter { $0.tag.hasPrefix(query) }
        let inside = pool.filter { !$0.tag.hasPrefix(query) && $0.tag.contains(query) }
        return Array((prefix + inside).prefix(8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !tags.isEmpty {
                QueryWrapLayout(spacing: 4) {
                    ForEach(tags, id: \.self) { tag in
                        Button { tags.removeAll { $0 == tag } } label: {
                            HStack(spacing: 3) { Text(tag); Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(.tint.opacity(0.25), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Remove “\(tag)”")
                    }
                }
            }
            TextField("Add a tag…", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit { if let first = suggestions.first { add(first.tag) } }
            if isFocused || !query.isEmpty {
                if suggestions.isEmpty {
                    Text(query.isEmpty ? "No more tags." : "No tag like “\(query)” in your library.")
                        .font(AppTypography.supportingDense).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(suggestions) { suggestion in
                            Button { add(suggestion.tag) } label: {
                                HStack {
                                    Text(suggestion.tag)
                                    Spacer()
                                    Text("\(suggestion.items) item\(suggestion.items == 1 ? "" : "s")").foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                                .padding(.horizontal, 6).padding(.vertical, 3)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private func add(_ tag: String) {
        if !tags.contains(tag) { tags.append(tag) }
        text = ""
    }
}

/// Lays chips out left to right, wrapping onto new lines.
struct QueryWrapLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let laidOut = arrange(width: bounds.width, subviews: subviews)
        for (subview, origin) in zip(subviews, laidOut.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}
