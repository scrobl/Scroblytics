import SwiftUI

/// The AND/OR condition-group editor: groups of conditions, AND within a group, OR across groups. Built on
/// `QueryConditionRow`, so it offers exactly the fields of whichever registry/target it's given. Shared by the
/// Query tab (its working spec) and any tool that refines a result with real Field Registry conditions.
struct QueryConditionsEditor: View {
    @Binding var groups: [[QueryCondition]]
    let registry: QueryFieldRegistry
    let target: QueryTarget
    var tagVocabulary: [QueryTagSuggestion] = []
    var asOf: Date = Date()
    /// What an empty condition list means, e.g. "matches every track".
    var emptyText: String?

    private var conditionCount: Int { groups.reduce(0) { $0 + $1.count } }

    var body: some View {
        DisclosureGroup("Conditions (\(conditionCount))") {
            VStack(alignment: .leading, spacing: 10) {
                if groups.isEmpty {
                    Text(emptyText ?? "No conditions — matches every \(target.rawValue).")
                        .font(AppTypography.metadata).foregroundStyle(.secondary)
                }
                ForEach(Array(groups.indices), id: \.self) { gi in
                    if gi > 0 {
                        HStack { Rectangle().frame(height: 1); Text("OR").font(AppTypography.badge); Rectangle().frame(height: 1) }
                            .foregroundStyle(.tertiary)
                    }
                    let group = groups[safe: gi] ?? []
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(group.indices), id: \.self) { ci in
                            QueryConditionRow(
                                condition: conditionBinding(gi, ci), registry: registry, target: target,
                                tagVocabulary: tagVocabulary, asOf: asOf,
                                onRemove: { removeCondition(gi, ci) }
                            )
                            if ci < group.count - 1 {
                                HStack(spacing: 8) {
                                    Rectangle().frame(height: 1)
                                    Text("AND").font(AppTypography.supportingDense)
                                    Rectangle().frame(height: 1)
                                }
                                .foregroundStyle(.quaternary)
                            }
                        }
                        Button { addCondition(to: gi) } label: { Label("Add condition", systemImage: "plus") }
                            .buttonStyle(.borderless).font(AppTypography.metadata)
                            .help("Add another condition to this group — every condition in a group must be true.")
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                }
                HStack {
                    Button { addGroup() } label: {
                        Label(groups.isEmpty ? "Add condition" : "Add OR group", systemImage: "plus.circle")
                    }
                    .buttonStyle(.borderless).font(AppTypography.metadata)
                    .help(groups.isEmpty ? "Add a condition to narrow the results."
                          : "Add an alternative group — a row matches if it satisfies every condition in ANY group.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
        }
        .font(AppTypography.sectionTitle)
    }

    private func conditionBinding(_ gi: Int, _ ci: Int) -> Binding<QueryCondition> {
        Binding(
            get: {
                groups.indices.contains(gi) && groups[gi].indices.contains(ci) ? groups[gi][ci] : QueryCondition("plays", .hasValue)
            },
            set: { newValue in
                if groups.indices.contains(gi), groups[gi].indices.contains(ci) { groups[gi][ci] = newValue }
            }
        )
    }

    private func newCondition() -> QueryCondition {
        QueryConditionRow.makeCondition(fieldID: "plays", registry: registry)
    }

    private func addCondition(to group: Int) {
        guard groups.indices.contains(group) else { return }
        groups[group].append(newCondition())
    }

    private func addGroup() { groups.append([newCondition()]) }

    private func removeCondition(_ gi: Int, _ ci: Int) {
        guard groups.indices.contains(gi), groups[gi].indices.contains(ci) else { return }
        groups[gi].remove(at: ci)
        if groups[gi].isEmpty { groups.remove(at: gi) }
    }
}
