import SwiftUI

private struct FirstFlowCellAlignment: AlignmentID {
    static func defaultValue(in dimensions: ViewDimensions) -> CGFloat {
        dimensions[.top]
    }
}

private extension VerticalAlignment {
    static let firstFlowCell = VerticalAlignment(FirstFlowCellAlignment.self)
}

/// What you play right after what. The classic picture for this (arcs between dots on a line) turns into a hairball
/// as soon as a library is big, so it is drawn three plainer ways instead:
///
/// 1. **Strongest hand-offs** — a ranked list, the ten most common "A, then B" pairs, with how they changed.
/// 2. **Who follows whom** — a grid: a row is what came first, a column is what came next, a darker cell is a more common
///    hand-off. Blocks and stripes show clusters, starters and enders at a glance, and nothing overlaps.
/// 3. **One artist's neighbourhood** — click any name: what leads into it on the left, what follows on the right,
///    as two mirrored bar lists.
struct TrendsFlowChart: View {
    struct Inputs: Equatable {
        let scrobbles: [ScrobbleSnapshot]
        let snapshots: QuerySnapshots
        let range: DateRange
        let compareRange: DateRange?
        let version: Int
        static func == (a: Inputs, b: Inputs) -> Bool { a.range == b.range && a.compareRange == b.compareRange && a.version == b.version }
    }

    let inputs: Inputs
    /// Opens an artist's own page (artist view only).
    let openArtist: (String) -> Void
    let openQuery: (QuerySpec, String) -> Void

    @AppStorage("trends.flow.granularity") private var granularityRaw = TrendsFlow.Granularity.artist.rawValue
    @AppStorage("trends.flow.gap") private var gap = 30
    @AppStorage("trends.flow.minTransitions") private var minTransitions = 3
    @AppStorage("trends.flow.showTop") private var showTop = 15
    @AppStorage("trends.flow.gridMode") private var gridModeRaw = GridMode.counts.rawValue
    @State private var data: TrendsFlow?
    @State private var isLoading = true
    @State private var focus: String?
    @State private var hoveredCell: (from: String, to: String)?

    enum GridMode: String, CaseIterable, Identifiable {
        case counts = "Counts", change = "Change"
        var id: String { rawValue }
    }

    private var granularity: TrendsFlow.Granularity { TrendsFlow.Granularity(rawValue: granularityRaw) ?? .artist }
    private var gridMode: GridMode { GridMode(rawValue: gridModeRaw) ?? .counts }
    private var noun: String { granularity == .artist ? "artist" : "genre" }
    private struct ComputeKey: Equatable { let granularity: TrendsFlow.Granularity; let gap: Int; let minTransitions: Int; let inputs: Inputs }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            controls
            if let data {
                if data.nodes.count < 5 || data.edges.count < 3 {
                    ContentUnavailableView("Not enough session data yet", systemImage: "arrow.triangle.branch",
                                           description: Text("Too few back-to-back plays to map. Widen the period, lower the minimum hand-offs, or switch between artists and genres."))
                        .frame(minHeight: 220)
                } else {
                    Text("\(data.sessionCount.formatted()) listening sessions · \(data.totalTransitions.formatted()) hand-offs from one \(noun) to another, with a \(gap >= 60 ? "\(gap / 60) hr" : "\(gap) min") session gap")
                        .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                    Group {
                        if let focus, data.nodes.contains(where: { $0.id == focus }) {
                            neighbourhood(focus, data)
                        } else {
                            overview(data)
                        }
                    }
                    .shareChartArea()
                }
            } else if isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 260)
            } else {
                ContentUnavailableView("No listening in this period", systemImage: "arrow.triangle.branch").frame(minHeight: 200)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator.opacity(0.45), lineWidth: 1) }
        .task(id: ComputeKey(granularity: granularity, gap: gap, minTransitions: minTransitions, inputs: inputs), priority: .utility) { await recompute() }
    }

    // MARK: - Controls

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                primaryControls
                Spacer()
                comparisonControl
            }
            VStack(alignment: .leading, spacing: 10) {
                AskFlowLayout(spacing: 12) {
                    primaryControls
                }
                comparisonControl
            }
        }
    }

    @ViewBuilder
    private var primaryControls: some View {
            Picker("Group by", selection: Binding(get: { granularity }, set: { granularityRaw = $0.rawValue; focus = nil })) {
                ForEach(TrendsFlow.Granularity.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Picker("Session gap", selection: $gap) {
                ForEach([3, 5, 15, 30, 60, 120, 360], id: \.self) { Text($0 < 60 ? "\($0) min gap" : "\($0 / 60) hr gap").tag($0) }
            }
            .fixedSize()
            .help("Plays closer together than this belong to one listening session; a longer silence starts a new one.")
            Picker("Minimum hand-offs", selection: $minTransitions) {
                ForEach([1, 2, 3, 5, 10], id: \.self) { Text($0 == 1 ? "All hand-offs" : "\($0)+ hand-offs").tag($0) }
            }
            .fixedSize()
            .help("Leave out pairs that happened fewer times than this — the noise floor.")
            Picker("Show", selection: $showTop) {
                ForEach([10, 15, 25], id: \.self) { Text("Top \($0) in the grid").tag($0) }
            }
            .fixedSize()
    }

    @ViewBuilder
    private var comparisonControl: some View {
        if data?.comparing == true, focus == nil {
            Picker("Grid", selection: Binding(get: { gridMode }, set: { gridModeRaw = $0.rawValue })) {
                ForEach(GridMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("Counts shows how often each hand-off happened; Change shows how that differs from the previous period.")
        }
    }

    // MARK: - Overview: list and grid

    private func overview(_ data: TrendsFlow) -> some View {
        let shown = Array(data.nodes.prefix(showTop))
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstFlowCell, spacing: 24) {
                grid(shown, data)
                    .layoutPriority(1)
                handoffList(data)
                    .frame(minWidth: 320, maxWidth: 420)
            }
            VStack(alignment: .leading, spacing: 20) {
                handoffList(data)
                ScrollView(.horizontal) {
                    grid(shown, data)
                }
            }
        }
    }

    private func handoffList(_ data: TrendsFlow) -> some View {
        let top = data.edges.filter { $0.status != .dropped }.prefix(10)
        let maxCount = Double(top.first?.count ?? 1)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Strongest hand-offs").font(AppTypography.metadata.weight(.semibold))
            ForEach(Array(top)) { edge in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        nameButton(edge.source)
                        Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(.secondary)
                        nameButton(edge.target)
                        Spacer(minLength: 6)
                        Text(edge.count.formatted()).font(AppTypography.metadata.monospacedDigit()).foregroundStyle(.secondary)
                        changeBadge(edge)
                    }
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.8)).frame(width: max(2, geo.size.width * Double(edge.count) / maxCount))
                    }
                    .frame(height: 5)
                }
            }
            Text("A → B means B was the very next thing you played after A, in the same sitting. Click a name to see everything around it.")
                .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func changeBadge(_ edge: TrendsFlow.Edge) -> some View {
        if data?.comparing == true {
            switch edge.status {
            case .new: Text("new").font(AppTypography.denseBadge).foregroundStyle(.green)
            case .dropped: Text("gone").font(AppTypography.denseBadge).foregroundStyle(.red)
            case .shared:
                let delta = edge.count - (edge.previousCount ?? edge.count)
                if delta != 0 {
                    Text((delta > 0 ? "+" : "") + delta.formatted()).font(AppTypography.denseBadge.monospacedDigit()).foregroundStyle(delta > 0 ? Color.green : Color.red)
                }
            }
        }
    }

    private func nameButton(_ id: String) -> some View {
        Button { focus = id } label: { Text(id).font(AppTypography.metadata).lineLimit(1) }
            .buttonStyle(.plain)
            .help("See what leads into and out of \(id)")
    }

    /// The grid. Roles (▸ opens sessions more than its share, ▪ closes them) are shown beside a name.
    private func grid(_ shown: [TrendsFlow.Node], _ data: TrendsFlow) -> some View {
        let lookup = Dictionary(uniqueKeysWithValues: data.edges.map { ($0.id, $0) })
        let maxCount = Double(data.edges.filter { $0.status != .dropped }.map(\.count).max() ?? 1)
        let maxDelta = Double(data.edges.map { abs($0.count - ($0.previousCount ?? $0.count)) }.max() ?? 1)
        let cell: CGFloat = shown.count > 15 ? 22 : 28
        let openMedian = median(shown.map(\.openShare)), closeMedian = median(shown.map(\.closeShare))
        return VStack(alignment: .leading, spacing: 8) {
            Text("Who follows whom").font(AppTypography.metadata.weight(.semibold))
            Text("Each row is what you played first; each column is what came next. Hover a cell to read it.").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .trailing, spacing: 2) {
                    Color.clear.frame(width: 1, height: Self.headerHeight)
                    ForEach(shown) { row in
                        HStack(spacing: 4) {
                            if row.opens >= 5, row.openShare >= openMedian * 1.5 { Image(systemName: "play.fill").font(.system(size: 7)).foregroundStyle(.green).help("Often the first thing you play in a sitting (\(pct(row.openShare)) of its plays)") }
                            if row.closes >= 5, row.closeShare >= closeMedian * 1.5 { Image(systemName: "stop.fill").font(.system(size: 7)).foregroundStyle(.orange).help("Often the last thing you play in a sitting (\(pct(row.closeShare)) of its plays)") }
                            Button { focus = row.id } label: { Text(row.id).font(AppTypography.chartAxis).lineLimit(1).frame(maxWidth: 150, alignment: .trailing) }
                                .buttonStyle(.plain)
                        }
                        .frame(height: cell)
                        .opacity(hoveredCell == nil || hoveredCell?.from == row.id ? 1 : 0.5)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 2) {
                        ForEach(shown) { col in
                            Text(shortened(col.id)).font(AppTypography.chartAxis).lineLimit(1).fixedSize()
                                .rotationEffect(.degrees(-60), anchor: .bottomLeading)
                                .frame(width: cell, height: Self.headerHeight, alignment: .bottomLeading)
                                .help(col.id)
                                .opacity(hoveredCell == nil || hoveredCell?.to == col.id ? 1 : 0.5)
                        }
                    }
                    ForEach(shown) { row in
                        HStack(spacing: 2) {
                            ForEach(shown) { col in
                                gridCell(row: row.id, col: col.id, lookup: lookup, maxCount: maxCount, maxDelta: maxDelta, size: cell)
                            }
                        }
                    }
                }
                // The reading appears beside the cell it describes — above it, or below it near the top — so it is
                // never off the bottom of the screen, and it takes no room of its own.
                .overlay(alignment: .topLeading) {
                    if let hovered = hoveredCell, let r = shown.firstIndex(where: { $0.id == hovered.from }), let c = shown.firstIndex(where: { $0.id == hovered.to }) {
                        let above = r >= 3
                        let x = CGFloat(c) * (cell + 2) + cell / 2
                        let y = Self.headerHeight + 2 + CGFloat(r) * (cell + 2) + (above ? -6 : cell + 6)
                        Color.clear.frame(width: 1, height: 1)
                            .overlay(alignment: above ? (c > shown.count / 2 ? .bottomTrailing : .bottomLeading) : (c > shown.count / 2 ? .topTrailing : .topLeading)) {
                                Text(hoverText(lookup, data))
                                    .font(AppTypography.metadata.monospacedDigit())
                                    .fixedSize()
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                                    .overlay { RoundedRectangle(cornerRadius: 8).stroke(.separator.opacity(0.6)) }
                                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                            }
                            .offset(x: x, y: y)
                            .allowsHitTesting(false)
                    }
                }
                .zIndex(10)
            }
            .alignmentGuide(.firstFlowCell) { dimensions in
                dimensions[.top] + 126
            }
            Text(data.comparing && gridMode == .change ? "Green: happened more than in the previous period · red: less." : "Darker: happened more often. ▸ often starts a sitting · ▪ often ends one.")
                .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
        }
    }

    /// Tall enough for the longest (shortened) column name at 60°.
    private static let headerHeight: CGFloat = 124

    /// Column names are turned on a slant, so a long one is cut short (the full name is in the tooltip).
    private func shortened(_ name: String) -> String { name.count > 20 ? String(name.prefix(19)) + "…" : name }

    private func gridCell(row: String, col: String, lookup: [String: TrendsFlow.Edge], maxCount: Double, maxDelta: Double, size: CGFloat) -> some View {
        let edge = row == col ? nil : lookup[row + "\u{0}" + col]
        let fill: Color = {
            guard let edge else { return Color.primary.opacity(row == col ? 0.02 : 0.05) }
            if data?.comparing == true, gridMode == .change {
                let delta = Double(edge.count - (edge.previousCount ?? edge.count))
                if edge.status == .dropped { return Color.red.opacity(0.15 + 0.6 * min(1, Double(edge.count) / maxDelta)) }
                return (delta >= 0 ? Color.green : Color.red).opacity(delta == 0 ? 0.06 : 0.15 + 0.7 * min(1, abs(delta) / maxDelta))
            }
            if edge.status == .dropped { return Color.primary.opacity(0.05) }
            return Color.accentColor.opacity(0.15 + 0.8 * sqrt(Double(edge.count) / maxCount))
        }()
        return RoundedRectangle(cornerRadius: 3).fill(fill)
            .frame(width: size, height: size)
            .overlay { if hoveredCell?.from == row && hoveredCell?.to == col { RoundedRectangle(cornerRadius: 3).stroke(Color.primary, lineWidth: 1.5) } }
            .contentShape(Rectangle())
            .onHover { inside in
                if inside, edge != nil { hoveredCell = (row, col) } else if hoveredCell?.from == row && hoveredCell?.to == col { hoveredCell = nil }
            }
            .onTapGesture { if edge != nil { focus = row } }
    }

    private func hoverText(_ lookup: [String: TrendsFlow.Edge], _ data: TrendsFlow) -> String {
        guard let cell = hoveredCell, let edge = lookup[cell.from + "\u{0}" + cell.to] else { return "Hover a cell to read it." }
        var text = "After \(cell.from) you played \(cell.to) \(edge.count.formatted()) time\(edge.count == 1 ? "" : "s")"
        if data.comparing, let previous = edge.previousCount { text += " · before: \(previous.formatted())" }
        return text
    }

    // MARK: - One name's neighbourhood

    private func neighbourhood(_ id: String, _ data: TrendsFlow) -> some View {
        let node = data.nodes.first { $0.id == id }!
        let before = data.edges.filter { $0.target == id && $0.status != .dropped }.sorted { $0.count > $1.count }
        let after = data.edges.filter { $0.source == id && $0.status != .dropped }.sorted { $0.count > $1.count }
        let maxCount = Double(max(1, (before + after).map(\.count).max() ?? 1))
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Button { focus = nil } label: { Label("All hand-offs", systemImage: "chevron.left") }.buttonStyle(.borderless)
                Text(id).font(AppTypography.entityTitle)
                Text("\(node.plays.formatted()) plays · \(pct(node.openShare)) of them opened a sitting and \(pct(node.closeShare)) closed one")
                    .font(AppTypography.metadata).foregroundStyle(.secondary)
                Spacer()
                if granularity == .artist {
                    Button("Open \(id)") { openArtist(id) }.buttonStyle(.borderless)
                } else {
                    Button("Open tracks in Query") {
                        var spec = QuerySpec(target: .track)
                        spec.period = QueryPeriod(from: data.range.from, to: data.range.to)
                        spec.groups = [[QueryCondition("plays", .greaterThan, [.number(0)]), QueryCondition("tags", .tagsIsAny, [.tags([id])])]]
                        spec.sorts = [QuerySort(key: .field(QueryFieldRef("plays")), direction: .descending)]
                        spec.columns = AskInterpreter.baseColumns.map { QueryFieldRef($0) }
                        openQuery(spec, "\(id) · " + TrendsDrill.rangeLabel(from: data.range.from, to: data.range.to))
                    }.buttonStyle(.borderless)
                }
            }
            HStack(alignment: .top, spacing: 0) {
                side(title: "Played right before \(id)", edges: before, other: { $0.source }, maxCount: maxCount, leading: true).frame(maxWidth: .infinity)
                Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1)
                side(title: "Played right after \(id)", edges: after, other: { $0.target }, maxCount: maxCount, leading: false).frame(maxWidth: .infinity)
            }
            Text("Bars are how many times that hand-off happened. The percentage is its share of everything that led into it (left) or out of it (right).")
                .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
        }
    }

    private func side(title: String, edges: [TrendsFlow.Edge], other: @escaping (TrendsFlow.Edge) -> String, maxCount: Double, leading: Bool) -> some View {
        let total = Double(max(1, edges.reduce(0) { $0 + $1.count }))
        return VStack(alignment: leading ? .trailing : .leading, spacing: 6) {
            Text(title).font(AppTypography.metadata.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 12)
            ForEach(edges.prefix(10)) { edge in
                HStack(spacing: 8) {
                    if leading {
                        changeBadge(edge)
                        Text("\(Int((Double(edge.count) / total * 100).rounded()))%").font(AppTypography.compactMetadata.monospacedDigit()).foregroundStyle(.secondary)
                        bar(edge.count, maxCount, leading: true)
                        Button(other(edge)) { focus = other(edge) }.buttonStyle(.plain).font(AppTypography.metadata).lineLimit(1).frame(width: 170, alignment: .trailing)
                    } else {
                        Button(other(edge)) { focus = other(edge) }.buttonStyle(.plain).font(AppTypography.metadata).lineLimit(1).frame(width: 170, alignment: .leading)
                        bar(edge.count, maxCount, leading: false)
                        Text("\(Int((Double(edge.count) / total * 100).rounded()))%").font(AppTypography.compactMetadata.monospacedDigit()).foregroundStyle(.secondary)
                        changeBadge(edge)
                    }
                }
                .padding(.horizontal, 12)
            }
            if edges.isEmpty { Text("Nothing above the minimum.").font(AppTypography.metadata).foregroundStyle(.secondary).padding(.horizontal, 12) }
        }
    }

    private func bar(_ count: Int, _ maxCount: Double, leading: Bool) -> some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(0.85))
                .frame(width: max(3, geo.size.width * Double(count) / maxCount))
                .frame(maxWidth: .infinity, alignment: leading ? .trailing : .leading)
                .overlay(alignment: leading ? .trailing : .leading) {
                    Text(count.formatted()).font(AppTypography.chartAxis.monospacedDigit()).foregroundStyle(.white.opacity(0.9)).padding(.horizontal, 4)
                }
        }
        .frame(height: 18)
    }

    // MARK: - Helpers

    private func pct(_ share: Double) -> String { (share * 100).formatted(.number.precision(.fractionLength(0))) + "%" }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    private func recompute() async {
        isLoading = true
        let (granularity, gap, minTransitions, inputs) = (self.granularity, self.gap, self.minTransitions, self.inputs)
        let computed = await TrendsComputeGate.shared.run {
            TrendsFlowEngine.compute(
                scrobbles: inputs.scrobbles, tags: inputs.snapshots.entityTags, granularity: granularity, gapMinutes: gap, minTransitions: minTransitions,
                range: inputs.range, compareRange: inputs.compareRange
            )
        }
        guard !Task.isCancelled, let computed else { return }
        data = computed
        isLoading = false
    }
}
