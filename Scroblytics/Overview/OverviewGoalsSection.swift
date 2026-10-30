import SwiftData
import SwiftUI

/// The goals chosen for the Overview (up to three), as their cards in one row that shares the width between them; a narrow window wraps
/// them instead. A card opens the goal on the Goals page.
struct OverviewGoalsSection: View {
    /// Opens the Goals page, on this goal when there is one.
    let openGoal: (UUID?) -> Void
    /// Ready-made goals and their numbers (layout snapshots); nothing is read.
    var preview: [(goal: ListeningGoal, analysis: GoalAnalysis)]?

    @Environment(\.modelContext) private var modelContext
    @State private var goals: [ListeningGoal] = []
    @State private var summaries: [UUID: GoalAnalysis] = [:]
    @State private var reloadTask: Task<Void, Never>?

    /// The narrowest a card is squeezed to before the row wraps.
    private static let minimumCardWidth: CGFloat = 270

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !goals.isEmpty { section }
            // Always there, so the section hears about goals chosen later even while it shows nothing.
            Color.clear.frame(height: 0)
                .task { await reload() }
                .onReceive(NotificationCenter.default.publisher(for: .goalsDidChange)) { _ in schedule() }
                .onReceive(NotificationCenter.default.publisher(for: .scrobbleSyncDidComplete)) { _ in schedule() }
        }
        // Takes back the gap the page leaves between its parts when there is nothing to show.
        .padding(.top, goals.isEmpty ? -16 : 0)
    }

    private var section: some View {
        VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Goals", systemImage: "target").font(AppTypography.sectionTitle)
                    Spacer()
                    Button { openGoal(nil) } label: {
                        HStack(spacing: 4) {
                            Text("View all")
                            Image(systemName: "chevron.right").font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(goals) { card($0).frame(minWidth: Self.minimumCardWidth, maxWidth: .infinity) }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.minimumCardWidth), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                        ForEach(goals) { card($0) }
                    }
                }
        }
    }

    private func card(_ goal: ListeningGoal) -> some View {
        GoalCard(
            goal: goal, analysis: summaries[goal.id],
            shareCard: { summaries[goal.id].flatMap { GoalShareCards.card(goal: goal, analysis: $0, result: nil) } },
            onOpen: { openGoal(goal.id) }, onEdit: {}, onDelete: {}, showsMenu: false, overviewChrome: true
        )
    }

    private func schedule() {
        reloadTask?.cancel()
        reloadTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            if !Task.isCancelled { await reload() }
        }
    }

    private func reload() async {
        if let preview {
            goals = preview.map(\.goal)
            summaries = Dictionary(uniqueKeysWithValues: preview.map { ($0.goal.id, $0.analysis) })
            return
        }
        let state = ToolFilterSettingsStore.load(GoalsState.self, toolId: GoalsState.toolId, context: modelContext, default: GoalsState())
        let chosen = state.overviewGoals
        goals = chosen
        guard !chosen.isEmpty else { summaries = [:]; return }
        if let computed = try? await GoalSummaryLoader.load(goals: chosen, context: modelContext, container: modelContext.container, calendar: AppCalendars.listening), !Task.isCancelled {
            summaries = computed
        }
    }
}
