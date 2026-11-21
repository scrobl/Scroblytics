import SwiftUI

/// How a typed search narrows a list of fields: every word typed must appear in the field's name or its group's title, ignoring case and
/// accents ("rank" finds Play rank and everything under Rank & momentum; "album plays" finds Album's plays).
enum QueryFieldSearch {
    static func matches(_ field: QueryField, group: QueryFieldGroup, query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return true }
        let haystack = field.name + " " + group.title
        return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// The fields of `target`, by group, that match `query` and pass `filter`; groups with nothing left are left out.
    static func sections(
        registry: QueryFieldRegistry, target: QueryTarget, query: String, filter: (QueryField) -> Bool = { _ in true }
    ) -> [(group: QueryFieldGroup, fields: [QueryField])] {
        QueryFieldGroup.allCases.compactMap { group in
            let fields = registry.fields(for: target, in: group).filter(filter).filter { matches($0, group: group, query: query) }
            return fields.isEmpty ? nil : (group, fields)
        }
    }
}

/// A button that opens a short list of fields with a search box at the top, instead of one long menu. Return picks the first match.
/// `shortcuts` are extra actions listed above the fields (for example "Shuffle (random)"); they hide while a search is typed.
struct QueryFieldPicker<Label: View>: View {
    struct Shortcut {
        let title: String
        var help = ""
        let action: () -> Void
    }

    let registry: QueryFieldRegistry
    let target: QueryTarget
    var filter: (QueryField) -> Bool = { _ in true }
    var shortcuts: [Shortcut] = []
    let onPick: (QueryField) -> Void
    @ViewBuilder let label: () -> Label

    @State private var isPresented = false
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        Button { isPresented = true } label: {
            HStack(spacing: 3) {
                label()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.borderless)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) { content }
        .onChange(of: isPresented) { _, now in if now { search = "" } }
    }

    private var sections: [(group: QueryFieldGroup, fields: [QueryField])] {
        QueryFieldSearch.sections(registry: registry, target: target, query: search, filter: filter)
    }

    private func pick(_ field: QueryField) {
        isPresented = false
        onPick(field)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Find a field", text: $search)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit { if let first = sections.first?.fields.first { pick(first) } }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if search.isEmpty {
                        ForEach(shortcuts.indices, id: \.self) { index in
                            PickerRow(title: shortcuts[index].title, help: shortcuts[index].help) {
                                isPresented = false
                                shortcuts[index].action()
                            }
                        }
                        if !shortcuts.isEmpty { Divider().padding(.vertical, 4) }
                    }
                    ForEach(sections, id: \.group) { section in
                        Text(section.group.title)
                            .font(AppTypography.supportingDense).foregroundStyle(.tertiary)
                            .padding(.top, 6).padding(.bottom, 2)
                        ForEach(section.fields, id: \.id) { field in
                            PickerRow(title: field.name, help: field.help) { pick(field) }
                        }
                    }
                    if sections.isEmpty {
                        Text("No fields match.").font(AppTypography.metadata).foregroundStyle(.secondary).padding(.vertical, 8)
                    }
                }
            }
            .frame(maxHeight: 360)
        }
        .padding(10)
        .frame(width: 300)
        .onAppear { searchFocused = true }
    }

    private struct PickerRow: View {
        let title: String
        let help: String
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(AppTypography.metadata)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4).padding(.horizontal, 6)
                    .background(hovering ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(help)
        }
    }
}
