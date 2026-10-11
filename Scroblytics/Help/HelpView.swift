import SwiftUI

/// The Help window: a searchable table of contents on the left, the selected article on the right.
struct HelpView: View {
    @State private var navigator = HelpNavigator.shared

    var body: some View {
        @Bindable var nav = navigator
        NavigationSplitView {
            VStack(spacing: 0) {
                searchField(text: $nav.query)
                // The same list structure (sections of single-line rows) whether or not a search is active: swapping
                // between two different row layouts made the underlying outline view crash while it re-laid itself out.
                List(selection: $nav.selectedID) {
                    ForEach(displayedSections(for: nav.query)) { section in
                        Section(section.title) {
                            ForEach(section.articles) { article in
                                Text(article.title).tag(article.id)
                            }
                        }
                    }
                }
                .overlay {
                    if displayedSections(for: nav.query).isEmpty {
                        Text("No matches").foregroundStyle(.secondary)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            if let article = HelpContent.article(nav.selectedID) {
                HelpArticleView(article: article)
                    .id(article.id)
            } else {
                ContentUnavailableView("Choose a topic", systemImage: "questionmark.circle")
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "help", let id = url.host else { return .systemAction }
            navigator.show(id)
            return .handled
        })
        .frame(minWidth: 760, minHeight: 480)
    }

    /// All sections, or — while searching — only the sections that still have a matching article.
    private func displayedSections(for query: String) -> [HelpSection] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return HelpContent.sections }
        let matching = Set(HelpContent.search(query).map(\.id))
        return HelpContent.sections.compactMap { section in
            let kept = section.articles.filter { matching.contains($0.id) }
            return kept.isEmpty ? nil : HelpSection(id: section.id, title: section.title, articles: kept)
        }
    }

    private func searchField(text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search Help", text: text).textFieldStyle(.plain)
            if !text.wrappedValue.isEmpty {
                Button { text.wrappedValue = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .padding([.horizontal, .top], 10).padding(.bottom, 6)
    }
}

private struct HelpArticleView: View {
    let article: HelpArticle

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(article.title).font(AppTypography.pageTitle)
                Text(article.summary).font(AppTypography.entitySubtitle).foregroundStyle(.secondary)
                ForEach(Array(article.blocks.enumerated()), id: \.offset) { _, block in
                    HelpBlockView(block: block)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }
}

/// Inline Markdown (bold, code, links) as styled text.
private func markdown(_ text: String) -> Text {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    if let attributed = try? AttributedString(markdown: text, options: options) {
        return Text(attributed)
    }
    return Text(text)
}

private struct HelpBlockView: View {
    let block: HelpBlock

    var body: some View {
        switch block {
        case .heading(let text):
            Text(text).font(AppTypography.sectionTitle).padding(.top, 8)
        case .paragraph(let text):
            markdown(text).fixedSize(horizontal: false, vertical: true)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                        markdown(item).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .steps(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                        markdown(item).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .callout(let kind, let text):
            HelpCallout(kind: kind, text: text)
        case .table(let headers, let rows):
            HelpTable(headers: headers, rows: rows)
        case .definitions(let defs):
            VStack(alignment: .leading, spacing: 10) {
                ForEach(defs, id: \.self) { def in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(def.term).font(AppTypography.contentTitle)
                        markdown(def.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .fieldGroup(let group):
            HelpFieldGroupView(group: group)
        }
    }
}

private struct HelpCallout: View {
    let kind: HelpCalloutKind
    let text: String

    private var symbol: String {
        switch kind {
        case .note: "info.circle.fill"
        case .tip: "lightbulb.fill"
        case .warning: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch kind {
        case .note: .blue
        case .tip: .green
        case .warning: .orange
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            markdown(text).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct HelpTable: View {
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 8) {
            GridRow {
                ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                    Text(header).font(AppTypography.tableHeading)
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        markdown(cell).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

/// Field entries come from the Field Registry (name, what it applies to, type, parameters) plus the hand-written
/// definition, so the reference cannot list a field that doesn't exist.
private struct HelpFieldGroupView: View {
    let group: QueryFieldGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(HelpFields.fields(in: group), id: \.id) { field in
                VStack(alignment: .leading, spacing: 4) {
                    Text(field.name).font(AppTypography.contentTitle)
                    Text(facts(for: field)).font(AppTypography.supporting).foregroundStyle(.secondary)
                    markdown(HelpFieldDefinitions.definition(for: field.id) ?? field.help)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(field.parameters, id: \.id) { parameter in
                        let options = parameter.options.map(parameter.display).joined(separator: ", ")
                        Text("Setting — \(parameter.label): \(options) (default \(parameter.display(parameter.defaultValue)))")
                            .font(AppTypography.supporting).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func facts(for field: QueryField) -> String {
        var parts: [String] = []
        let order: [QueryTarget] = [.artist, .album, .track]
        parts.append(order.filter { field.targets.contains($0) }.map { $0.rawValue.capitalized }.joined(separator: ", "))
        switch field.type {
        case .numeric: parts.append("number")
        case .text: parts.append("text")
        case .boolean: parts.append("yes/no")
        case .date: parts.append("date")
        case .tags: parts.append("tag list")
        }
        if let unit = field.inputUnit { parts.append("typed in \(unit.label)") }
        if field.comparesPeriods { parts.append("compares two periods") } else if field.supportsScope { parts.append("can use its own date range") }
        if field.isBackgroundResolved { parts.append("filled in by a background lookup") }
        return parts.joined(separator: " · ")
    }
}
