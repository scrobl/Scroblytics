import SwiftUI

/// The one generic results table — the pinned identity column plus one
/// independent, header-labelled, drag-reorderable column per selected field,
/// each drawn from the registry's column spec. Built once; every surface that
/// shows query results uses it.
///
/// - The identity column (artwork + name + context) is always first, never
///   reorderable, and stays put while the other columns scroll horizontally.
///   The stickiness is a render-time `visualEffect` offset, not observed state,
///   so it can't lag behind the scroll.
/// - Numeric columns right-align, text/date left-align, boolean/icon center.
/// - Order is changed by dragging a header onto another header.
struct QueryResultsTable: View {
    let rows: [QueryDisplayRow]
    let columns: [ResolvedField]
    let identityTitle: String
    let onMoveColumn: (_ moving: String, _ before: String) -> Void
    let onOpen: (QueryDisplayRow) -> Void

    private static let baseIdentityWidth: CGFloat = 300
    /// The year column, when the results are broken down by year.
    private static let yearWidth: CGFloat = 56
    private var hasYears: Bool { rows.first?.period != nil }
    private var identityWidth: CGFloat { Self.baseIdentityWidth + (hasYears ? Self.yearWidth : 0) }
    private static let rowHeight = AppArtworkSizing.thumbnail + 8
    private static let headerHeight: CGFloat = 30

    private var contentWidth: CGFloat {
        identityWidth + columns.reduce(0) { $0 + Self.width(of: $1) }
    }

    /// The spec's width, widened when needed so a header never truncates its title.
    private static func width(of column: ResolvedField) -> CGFloat {
        max(CGFloat(column.field.column.width), CGFloat(column.title.count) * 7.6 + 30)
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(rows) { row in
                        rowView(row)
                        Divider()
                    }
                } header: {
                    headerRow
                }
            }
            .frame(width: contentWidth, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Header

    private var headerRow: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(identityTitle)
                    .padding(.horizontal, 12)
                    .frame(width: identityWidth, height: Self.headerHeight, alignment: .leading)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .overlay(alignment: .trailing) { Divider() }
                    .stickyLeading()
                    .zIndex(1)
                ForEach(columns, id: \.cacheKey) { column in
                    Text(column.title)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(width: Self.width(of: column), height: Self.headerHeight, alignment: Self.alignment(column.field.column.alignment))
                        .contentShape(Rectangle())
                        .overlay { HeaderToolTip(text: column.field.help) }
                        .draggable(column.cacheKey)
                        .dropDestination(for: String.self) { items, _ in
                            guard let moving = items.first else { return false }
                            onMoveColumn(moving, column.cacheKey)
                            return true
                        }
                }
            }
            .font(AppTypography.tableHeading)
            .foregroundStyle(.secondary)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
        }
    }

    // MARK: Rows

    private func rowView(_ row: QueryDisplayRow) -> some View {
        Button {
            onOpen(row)
        } label: {
            HStack(spacing: 0) {
                identityCell(row)
                    .frame(width: identityWidth, height: Self.rowHeight, alignment: .leading)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .overlay(alignment: .trailing) { Divider() }
                    .stickyLeading()
                    .zIndex(1)
                ForEach(columns, id: \.cacheKey) { column in
                    QueryCellView(cell: row.row.cells[column.cacheKey] ?? .missing, column: column, entity: row.entity)
                        .padding(.horizontal, 10)
                        .frame(width: Self.width(of: column), height: Self.rowHeight, alignment: Self.alignment(column.field.column.alignment))
                }
            }
        }
        .drillDownHighlight()
        .entityContextMenu(
            target: imageTarget(for: row.entity),
            currentImageURL: row.imageURL,
            onOpen: { onOpen(row) }
        )
    }

    private func identityCell(_ row: QueryDisplayRow) -> some View {
        HStack(spacing: 10) {
            if let period = row.period {
                Text(String(period))
                    .font(AppTypography.tableRank)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: Self.yearWidth - 14, alignment: .leading)
            }
            EntityThumbnail(url: row.imageURL, entity: entityKind(row.entity.target))
                .frame(width: AppArtworkSizing.thumbnail, height: AppArtworkSizing.thumbnail)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(row.entity.name).font(AppTypography.contentTitle).lineLimit(1)
                    TrackLovedIndicator(
                        artist: row.entity.artist,
                        track: row.entity.name,
                        initialValue: false,
                        font: AppTypography.compactMetadata,
                        enabled: row.entity.target == .track
                    )
                }
                if let subtitle = row.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(AppTypography.compactMetadata).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private func entityKind(_ target: QueryTarget) -> TopChartsEntity {
        switch target {
        case .artist: .artist
        case .album: .album
        case .track: .track
        }
    }

    private func imageTarget(for entity: QueryEntity) -> ImageTarget {
        switch entity.target {
        case .artist:
            ImageTarget(kind: .artist, artist: entity.name, album: nil, track: nil)
        case .album:
            ImageTarget(kind: .album, artist: entity.artist, album: entity.name, track: nil)
        case .track:
            ImageTarget(kind: .track, artist: entity.artist, album: nil, track: entity.name)
        }
    }

    fileprivate static func alignment(_ a: QueryAlignment) -> Alignment {
        switch a {
        case .leading: .leading
        case .trailing: .trailing
        case .center: .center
        }
    }
}

private extension View {
    /// Keeps a view pinned to the scroll view's leading edge while the content
    /// scrolls horizontally underneath it.
    func stickyLeading() -> some View {
        visualEffect { content, proxy in
            content.offset(x: max(0, -proxy.frame(in: .scrollView).minX))
        }
    }
}

/// Draws one cell from its column spec. A `custom` style resolves here, in the
/// one place a tool's distinctive visual lives — never by forking the table.
struct QueryCellView: View {
    let cell: QueryCell
    let column: ResolvedField
    let entity: QueryEntity

    var body: some View {
        switch cell {
        case .pending: Text("…").foregroundStyle(.tertiary).help("Still being resolved in the background")
        case .missing: Text("—").foregroundStyle(.tertiary)
        case .value(let value): rendered(value).font(AppTypography.metadata)
        }
    }

    @ViewBuilder
    private func rendered(_ value: QueryValue) -> some View {
        switch (column.field.column.style, value) {
        case (.custom("peakBadge"), .number(let n)):
            OverviewValueChip(text: "\(Int(n)) at peak")
        case (.custom("popularityDiamond"), .bool(let popular)):
            if popular { PopularityMarker(lookup: lookup, font: .system(size: 12)) } else { Text("—").foregroundStyle(.tertiary) }
        case (.custom("lovedHeart"), .bool(let loved)):
            if loved { Image(systemName: "heart.fill").foregroundStyle(.red).help("Loved") } else { Text("—").foregroundStyle(.tertiary) }
        case (.custom("flaggedFlag"), .bool(let flagged)):
            if flagged { Image(systemName: "flag.fill").foregroundStyle(.orange).help("Flagged") } else { Text("—").foregroundStyle(.tertiary) }
        case (.custom("similarScore"), .number(let n)):
            SimilarScoreBar(score: n)
        case (.custom("becauseYouLike"), .text(let seeds)):
            // The seed(s) shown in the cell itself, best match first; the tooltip is only for a name that gets truncated.
            Text(seeds).lineLimit(1).truncationMode(.tail)
                .help("Because you like " + seeds.replacingOccurrences(of: SimilaritySnapshot.sourceSeparator, with: ", "))
        case (.custom(let id), _):
            // Fail loud: an unregistered renderer is visible, not silently flattened to text.
            Label("no renderer “\(id)”", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        case (.listeningTime, _): Text(QueryCellText.string(value, column: column)).monospacedDigit().lineLimit(1)
        case (.integer, _), (.decimal, _), (.year, _), (.runtime, _), (.tempo, _), (.percent, _):
            Text(QueryCellText.string(value, column: column)).monospacedDigit()
        case (.date, .date): Text(QueryCellText.string(value, column: column))
        case (.boolean, .bool(let b)): Image(systemName: b ? "checkmark" : "minus").foregroundStyle(b ? Color.primary : Color.secondary)
        case (_, .text), (_, .tags): Text(QueryCellText.string(value, column: column)).lineLimit(1)
        default: Text(QueryCellText.string(value, column: column)).monospacedDigit()
        }
    }

    private var lookup: PopularityLookup {
        switch entity.target {
        case .artist: .artist(entity.name)
        case .album: .album(artist: entity.artist, name: entity.name)
        case .track: .track(artist: entity.artist, name: entity.name)
        }
    }
}

/// A tooltip drawn by AppKit itself. SwiftUI's `.help` doesn't fire on a pinned `LazyVStack` section
/// header inside a scroll view (its tracking area never follows the pinned position), so the column
/// headers use a plain `NSView.toolTip`, which does. Hit-testing passes through so dragging still works.
private struct HeaderToolTip: NSViewRepresentable {
    let text: String

    final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> PassThroughView { PassThroughView() }
    func updateNSView(_ view: PassThroughView, context: Context) { view.toolTip = text }
}
