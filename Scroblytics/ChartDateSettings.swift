import Foundation
import Observation
import SwiftUI

enum PresentationContext: String, CaseIterable {
    case topCharts
    case library
    case detail

    /// App defaults for new users:
    /// - Top Charts: Lists (false) for all entities
    /// - Library: Grid (true) for Artists and Albums
    /// - Detail pages: Lists (false) for all sub-lists
    var defaultIsGridView: Bool {
        switch self {
        case .topCharts: return false
        case .library: return true
        case .detail: return false
        }
    }
}

struct PageSettingsHeader<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(AppTypography.pageTitle)

            content
                .controlSize(.large)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.separator.opacity(0.45), lineWidth: 1)
                }
        }
    }
}

/// The Date range and Chart comparison period, shared identically by
/// Overview and Top Charts and persisted across launches. Both live as single top-level state and are
/// merely *displayed* on whichever page renders the control, not owned per-page.
@MainActor
@Observable
final class ChartDateSettings {
    private enum Keys {
        static let rangeId = "chartDateSettings.rangeId"
        static let compareMode = "chartDateSettings.compareMode"
        static let compareCustomDate = "chartDateSettings.compareCustomDate"
        static let metric = "chartDateSettings.metric"
        static func topChartsRowLimit(for entity: TopChartsEntity) -> String {
            "topCharts.rowLimit.\(entity.rawValue)"
        }
    }

    var selectedRangeId: String {
        didSet { UserDefaults.standard.set(selectedRangeId, forKey: Keys.rangeId) }
    }
    var compareMode: ChartCompareMode {
        didSet { UserDefaults.standard.set(compareMode.rawValue, forKey: Keys.compareMode) }
    }
    var metric: TopChartsMetric {
        didSet { UserDefaults.standard.set(metric.rawValue, forKey: Keys.metric) }
    }
    var compareCustomDate: Date? {
        didSet {
            if let compareCustomDate {
                UserDefaults.standard.set(compareCustomDate, forKey: Keys.compareCustomDate)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.compareCustomDate)
            }
        }
    }
    static let topChartsRowLimitOptions = [10, 25, 40, 50, 100, 250, 500]

    private var gridViewPreferences: [String: Bool] = [:]
    private var topChartsRowLimits: [TopChartsEntity: Int] = [:]

    init() {
        let defaults = UserDefaults.standard
        selectedRangeId = defaults.string(forKey: Keys.rangeId) ?? "last30"
        if let raw = defaults.string(forKey: Keys.compareMode), let mode = ChartCompareMode(rawValue: raw) {
            compareMode = mode
        } else {
            compareMode = .last30
        }
        compareCustomDate = defaults.object(forKey: Keys.compareCustomDate) as? Date
        metric = defaults.string(forKey: Keys.metric).flatMap(TopChartsMetric.init(rawValue:)) ?? .scrobbles

        var preferences: [String: Bool] = [:]
        for context in PresentationContext.allCases {
            for entity in TopChartsEntity.allCases {
                let key = "\(context.rawValue).\(entity.rawValue)"
                let userDefaultsKey = "isGridView.\(key)"
                if let value = defaults.object(forKey: userDefaultsKey) as? Bool {
                    preferences[key] = value
                }
            }
        }
        gridViewPreferences = preferences

        var rowLimits: [TopChartsEntity: Int] = [:]
        for entity in TopChartsEntity.allCases {
            let stored = defaults.integer(forKey: Keys.topChartsRowLimit(for: entity))
            if Self.topChartsRowLimitOptions.contains(stored) {
                rowLimits[entity] = stored
            }
        }
        topChartsRowLimits = rowLimits
    }

    func topChartsRowLimit(for entity: TopChartsEntity) -> Int {
        topChartsRowLimits[entity] ?? 100
    }

    func setTopChartsRowLimit(_ value: Int, for entity: TopChartsEntity) {
        guard Self.topChartsRowLimitOptions.contains(value) else { return }
        topChartsRowLimits[entity] = value
        UserDefaults.standard.set(value, forKey: Keys.topChartsRowLimit(for: entity))
    }

    func topChartsRowLimitBinding(for entity: TopChartsEntity) -> Binding<Int> {
        Binding(
            get: { self.topChartsRowLimit(for: entity) },
            set: { self.setTopChartsRowLimit($0, for: entity) }
        )
    }

    func isGridView(for entity: TopChartsEntity, context: PresentationContext) -> Bool {
        let key = "\(context.rawValue).\(entity.rawValue)"
        return gridViewPreferences[key] ?? context.defaultIsGridView
    }

    func setIsGridView(_ value: Bool, for entity: TopChartsEntity, context: PresentationContext) {
        let key = "\(context.rawValue).\(entity.rawValue)"
        gridViewPreferences[key] = value
        UserDefaults.standard.set(value, forKey: "isGridView.\(key)")
    }

    func binding(for entity: TopChartsEntity, context: PresentationContext) -> Binding<Bool> {
        Binding(
            get: { self.isGridView(for: entity, context: context) },
            set: { self.setIsGridView($0, for: entity, context: context) }
        )
    }

    /// Resolves the current comparison setting into an actual compare range
    /// for `range` — the same switch every page previously duplicated.
    func resolveCompareRange(for range: DateRange) -> DateRange? {
        switch compareMode {
        case .custom:
            guard let compareCustomDate else { return nil }
            return OverviewTotalsEngine.endingOnDate(range, date: compareCustomDate)
        default:
            guard let days = compareMode.days else { return nil }
            return OverviewTotalsEngine.endingDaysAgo(range, days: days)
        }
    }

    /// Comparing to a window as wide as (or wider than) the selected range
    /// is meaningless — if the current selection no longer offers that
    /// option, fall back to the widest one that's still valid for it.
    /// `.custom` is a manual date pick, not a fixed offset, so it's exempt.
    func clampCompareMode(for range: DateRange) {
        guard compareMode != .custom else { return }
        let days = range.to.timeIntervalSince(range.from) / 86400
        let valid = ChartCompareMode.validPresets(rangeDays: days)
        if !valid.isEmpty, !valid.contains(compareMode) {
            compareMode = valid.last!
        }
    }

    /// Seeds the date picker with a sensible starting point the first time
    /// it's opened, rather than leaving it empty (no comparison shown)
    /// until the user picks a date.
    func selectCustomCompareMode(for range: DateRange) {
        compareMode = .custom
        if compareCustomDate == nil {
            compareCustomDate = OverviewTotalsEngine.endingDaysAgo(range, days: 30)?.to
                ?? OverviewTotalsEngine.endingDaysAgo(range, days: 1)?.to
                ?? range.from
        }
    }
}

/// Shared "Last 30 days"-style Date range dropdown — identical on both
/// Overview and Top Charts, backed by the same `ChartDateSettings`.
struct DateRangeMenu: View {
    let settings: ChartDateSettings
    let rangeOptions: [DateRangeOption]

    private var currentRangeLabel: String {
        rangeOptions.first { $0.id == settings.selectedRangeId }?.label ?? "Last 30 days"
    }

    var body: some View {
        Menu {
            Picker("Period", selection: Binding(
                get: { settings.selectedRangeId },
                set: { settings.selectedRangeId = $0 }
            )) {
                ForEach(rangeOptions) { option in
                    Text(option.label).tag(option.id)
                }
            }
        } label: {
            Label("Period: \(currentRangeLabel)", systemImage: "calendar")
        }
    }
}

/// Shared "Chart comparison" control — identical on both Overview and Top
/// Charts, backed by the same `ChartDateSettings`. Hidden entirely when no
/// preset is narrower than the selected range and no custom date is set,
/// in that case.
struct ChartFilterBar: View {
    let settings: ChartDateSettings
    let rangeOptions: [DateRangeOption]
    let currentRange: DateRange
    var usesTimelineMetricPicker = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                leadingControls
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 12)
                metricPicker
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    leadingControls
                }
                metricPicker
            }
        }
    }

    @ViewBuilder
    private var leadingControls: some View {
        DateRangeMenu(settings: settings, rangeOptions: rangeOptions)
        Divider().frame(height: 22)
        ChartComparisonControl(settings: settings, currentRange: currentRange)
    }

    @ViewBuilder
    private var metricPicker: some View {
        if usesTimelineMetricPicker {
            Picker("Metric", selection: Binding(
                get: { settings.metric },
                set: { settings.metric = $0 }
            )) {
                ForEach(TopChartsMetric.allCases) { metric in
                    Text(metric.displayName).tag(metric)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.regular)
            .fixedSize()
            .layoutPriority(1)
        } else {
            ChartMetricToggle(metric: Binding(
                get: { settings.metric },
                set: { settings.metric = $0 }
            ))
            .frame(maxWidth: 460)
            .layoutPriority(1)
        }
    }
}

struct ChartMetricToggle: View {
    @Binding var metric: TopChartsMetric

    var body: some View {
        ViewThatFits(in: .horizontal) {
            buttonBar
                .frame(minWidth: 250)

            Menu {
                Picker("Metric", selection: $metric) {
                    ForEach(TopChartsMetric.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
            } label: {
                Label("Metric: \(metric.displayName)", systemImage: "chart.bar")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var buttonBar: some View {
        HStack(spacing: 0) {
            ForEach(TopChartsMetric.allCases) { option in
                Button {
                    metric = option
                } label: {
                    Text(option.displayName)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(metric == option ? Color.white : Color.primary)
                .background(
                    metric == option ? Color.accentColor : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .accessibilityAddTraits(metric == option ? .isSelected : [])
            }
        }
        .padding(2)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Metric")
    }
}

struct EntityPresentationRow<Selector: View>: View {
    let selectorWidth: CGFloat
    @Binding var isGridView: Bool
    @ViewBuilder let selector: Selector

    init(
        selectorWidth: CGFloat,
        isGridView: Binding<Bool>,
        @ViewBuilder selector: () -> Selector
    ) {
        self.selectorWidth = selectorWidth
        _isGridView = isGridView
        self.selector = selector()
    }

    var body: some View {
        HStack(spacing: 12) {
            selector
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: selectorWidth)

            Spacer(minLength: 12)

            Picker("Presentation", selection: $isGridView) {
                Label("List", systemImage: "list.bullet").tag(false)
                Label("Grid", systemImage: "square.grid.2x2").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 112)
        }
    }
}

struct ChartControlsPanel<AdditionalContent: View>: View {
    let settings: ChartDateSettings
    let rangeOptions: [DateRangeOption]
    let currentRange: DateRange
    @ViewBuilder let additionalContent: AdditionalContent

    init(
        settings: ChartDateSettings,
        rangeOptions: [DateRangeOption],
        currentRange: DateRange,
        @ViewBuilder additionalContent: () -> AdditionalContent
    ) {
        self.settings = settings
        self.rangeOptions = rangeOptions
        self.currentRange = currentRange
        self.additionalContent = additionalContent()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ChartFilterBar(settings: settings, rangeOptions: rangeOptions, currentRange: currentRange)
            additionalContent
        }
        .controlSize(.large)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.separator.opacity(0.45), lineWidth: 1)
        }
    }
}

struct ChartFilterBarSection: View {
    let settings: ChartDateSettings
    let rangeOptions: [DateRangeOption]
    let currentRange: DateRange

    var body: some View {
        ChartFilterBar(settings: settings, rangeOptions: rangeOptions, currentRange: currentRange)
            .controlSize(.large)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.separator.opacity(0.45), lineWidth: 1)
            }
    }
}

struct ChartComparisonControl: View {
    let settings: ChartDateSettings
    let currentRange: DateRange

    private var rangeDays: Double {
        currentRange.to.timeIntervalSince(currentRange.from) / 86400
    }
    private var validCompareModes: [ChartCompareMode] {
        ChartCompareMode.validPresets(rangeDays: rangeDays)
    }
    private var customDateBounds: ClosedRange<Date> {
        let minDate = currentRange.from.addingTimeInterval(86400)
        let maxDate = min(currentRange.to, Date())
        return minDate...max(minDate, maxDate)
    }

    var body: some View {
        Group {
            if !validCompareModes.isEmpty || settings.compareMode == .custom {
                HStack(spacing: 8) {
                    Menu {
                        Picker("Comparison", selection: Binding(
                            get: { settings.compareMode },
                            set: { mode in
                                if mode == .custom {
                                    settings.selectCustomCompareMode(for: currentRange)
                                } else {
                                    settings.compareMode = mode
                                }
                            }
                        )) {
                            ForEach(validCompareModes) { mode in
                                Text(mode.label).tag(mode)
                            }
                            Text(ChartCompareMode.custom.label).tag(ChartCompareMode.custom)
                        }
                    } label: {
                        Label("Compare: \(settings.compareMode.label)", systemImage: "arrow.left.arrow.right")
                    }
                    if settings.compareMode == .custom {
                        PopoverDatePicker(
                            "Comparison date",
                            selection: Binding(
                                get: { settings.compareCustomDate ?? currentRange.from },
                                set: { settings.compareCustomDate = $0 }
                            ),
                            in: customDateBounds
                        )
                    }
                }
            }
        }
        .onChange(of: currentRange) { settings.clampCompareMode(for: currentRange) }
    }
}
