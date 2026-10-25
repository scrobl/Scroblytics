import SwiftUI

/// Shared Ask popover used from both the app toolbar and the Query page.
struct AskPopoverContent: View {
    @Bindable var ask: AskModel
    let registry: QueryFieldRegistry
    let context: () -> AskContext
    let onRun: (QuerySpec) -> Void
    let onEdit: (QuerySpec) -> Void
    let onSave: (QuerySpec) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask your library")
                .font(AppTypography.sectionTitle)
            Text("Describe what you want to find. You can review the generated query before applying it.")
                .font(AppTypography.metadata)
                .foregroundStyle(.secondary)
            AskBar(
                ask: ask,
                registry: registry,
                context: context,
                onRun: onRun,
                onEdit: onEdit,
                onSave: onSave
            )
        }
        .padding(16)
        .frame(width: 540)
    }
}

/// The Ask entry point on the Query tab: a sentence in, an interpretation out for the user to confirm.
/// It is only a new way in — confirming loads the interpreted spec into the same builder and results
/// table as a hand-made query.
struct AskBar: View {
    @Bindable var ask: AskModel
    let registry: QueryFieldRegistry
    let context: () -> AskContext
    let onRun: (QuerySpec) -> Void
    let onEdit: (QuerySpec) -> Void
    let onSave: (QuerySpec) -> Void

    @Environment(AskSimilarRouter.self) private var similarRouter
    @Environment(AskSuggestionStore.self) private var suggestions
    @FocusState private var focused: Bool

    /// True while the person is editing (deleting characters to empty the box must not swap the example under them).
    private var focusedAndTyping: Bool { focused }

    /// The example shown in the empty box: picked when Ask opened, never changing while it stays open.
    private var exampleSentence: String { suggestions.current?.sentence ?? AskSuggestionStore.defaultSentence }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.secondary)
                TextField("Ask", text: $ask.text, prompt: Text("Ask — for example “\(exampleSentence)”"))
                    .textFieldStyle(.plain)
                    .focused($focused)
                    // Tab on an empty box takes the example, so trying it is one keystroke.
                    .onKeyPress(.tab) {
                        guard ask.text.isEmpty, ask.availability == .available else { return .ignored }
                        ask.text = exampleSentence
                        return .handled
                    }
                    .disabled(ask.availability != .available)
                    .onSubmit { ask.submit(registry: registry, context: context()) }
                    .onChange(of: focused) { if focused { ask.prewarm(registry: registry) } }
                if ask.text.isEmpty, !ask.isBusy, ask.availability == .available {
                    Button("Try it") { ask.text = exampleSentence }
                        .buttonStyle(.borderless).font(AppTypography.compactMetadata)
                        .help("Use this example (or press Tab).")
                }
                if ask.isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Ask") { ask.submit(registry: registry, context: context()) }
                        .disabled(ask.availability != .available || ask.text.trimmingCharacters(in: .whitespaces).isEmpty)
                        .help("Turn this sentence into a query. You’ll see how it was understood before anything runs.")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            AskEngineIndicator()

            if case .unavailable(let why) = ask.availability {
                Label(why, systemImage: "exclamationmark.triangle").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
            }
            switch ask.state {
            case .idle, .translating: EmptyView()
            case .failed(let message):
                HStack(alignment: .top) {
                    Label(message, systemImage: "exclamationmark.triangle").font(AppTypography.metadata).foregroundStyle(.orange)
                    Spacer()
                    Button { ask.discard() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
            case .review(let review):
                reviewCard(review)
            }
        }
        .onAppear {
            focused = true
        }
        .task { await suggestions.chooseForOpening(engine: AskSettingsStore.load().selected) }
        // After a question is acted on the box is empty again; give it a fresh example (the Query tab's bar stays on screen).
        .onChange(of: ask.text) { old, new in
            if !old.isEmpty, new.isEmpty, !focusedAndTyping { Task { await suggestions.chooseForOpening(engine: AskSettingsStore.load().selected) } }
        }
    }

    /// "Find 25 songs similar to X": shown as what it is — a Similar Sounds search — with the library item it found.
    @ViewBuilder
    private func similarCard(_ review: AskModel.Review, _ similar: AskModel.Review.Similar) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Here’s how I understood that").font(AppTypography.metadata).foregroundStyle(.secondary)
                Spacer()
                Button { ask.discard() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Dismiss")
            }
            AskFlowLayout(spacing: 6) {
                Text("Similar Sounds").font(AppTypography.metadata).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.25), in: Capsule())
                Text(similar.seed?.label ?? "“\(similar.intent.seedText)” — not in your library")
                    .font(AppTypography.metadata).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                Text("\(similar.intent.limit) tracks").font(AppTypography.metadata).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
            if similar.seed == nil {
                Label("Similar Sounds starts from something you’ve scrobbled, and I couldn’t find that in your library. Open Similar Sounds to pick a seed yourself.", systemImage: "exclamationmark.triangle")
                    .font(AppTypography.compactMetadata).foregroundStyle(.orange)
            }
            HStack {
                Button("Find similar") {
                    if let seed = similar.seed { similarRouter.pending = AskSimilarRequest(seed: seed, limit: similar.intent.limit) }
                    ask.complete()
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(similar.seed == nil)
                .help("Open Similar Sounds on this seed and look up what Last.fm says is similar.")
            }
            if !review.engine.isEmpty {
                Text("Answered by \(review.engine)" + (review.usage.map { " · \($0.seconds.formatted(.number.precision(.fractionLength(1)))) s" } ?? ""))
                    .font(AppTypography.supportingDense).foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func reviewCard(_ review: AskModel.Review) -> some View {
        if let similar = review.similar {
            similarCard(review, similar)
        } else {
            queryCard(review)
        }
    }

    @ViewBuilder
    private func queryCard(_ review: AskModel.Review) -> some View {
        let interpretation = review.interpretation
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Here’s how I understood that").font(AppTypography.metadata).foregroundStyle(.secondary)
                Spacer()
                Button { ask.discard() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Dismiss")
            }
            AskFlowLayout(spacing: 6) {
                ForEach(review.chips) { chip in
                    Text(chip.text)
                        .font(AppTypography.metadata)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(background(for: chip.kind), in: Capsule())
                        .foregroundStyle(chip.kind == .alternative ? .secondary : .primary)
                        .help(chip.help ?? "")
                }
            }
            ForEach(Array(Set(review.chips.compactMap(\.caveat))).sorted(), id: \.self) { caveat in
                Label(caveat, systemImage: "info.circle").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
            }
            ForEach(review.resolvedTerms, id: \.self) { term in
                Label("“\(term.phrase)” → \(term.meaning)", systemImage: "slider.horizontal.3")
                    .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                    .help("The model chose this number for a vague phrase. Use “Edit filters instead” to change it.")
            }
            if interpretation.spec.groups.isEmpty, interpretation.spec.sorts.isEmpty, interpretation.spec.limit == nil {
                Text(interpretation.unsupported.isEmpty
                     ? "I couldn’t find anything in that to search for."
                     : "Nothing in that request can be searched for yet.")
                    .font(AppTypography.metadata).foregroundStyle(.secondary)
            }
            if !interpretation.unsupported.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Not something I can search for", systemImage: "exclamationmark.triangle").font(AppTypography.metadata).foregroundStyle(.orange)
                    ForEach(interpretation.unsupported, id: \.self) { Text("• " + $0).font(AppTypography.compactMetadata).foregroundStyle(.secondary) }
                }
            }
            if !interpretation.dropped.isEmpty {
                Label(
                    "\(interpretation.dropped.count) part\(interpretation.dropped.count == 1 ? "" : "s") of the answer couldn’t be applied and \(interpretation.dropped.count == 1 ? "was" : "were") left out.",
                    systemImage: "exclamationmark.circle"
                )
                .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                .help(interpretation.dropped.map { "\($0.what): \($0.reason)" }.joined(separator: "\n"))
            }
            HStack {
                Button("Run") { onRun(interpretation.spec); ask.complete() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(interpretation.spec.groups.isEmpty && interpretation.spec.sorts.isEmpty && interpretation.spec.limit == nil)
                    .help("Run this query and show the results.")
                Button("Edit filters instead") { onEdit(interpretation.spec); ask.complete() }
                    .controlSize(.small)
                    .help("Open this in the filter builder to adjust it by hand.")
                Button("Save…") { onSave(interpretation.spec); ask.complete() }
                    .controlSize(.small)
                    .help("Save this query as a condition set.")
            }
            if !review.engine.isEmpty {
                Text("Answered by \(review.engine)" + (review.usage.map { " · \($0.seconds.formatted(.number.precision(.fractionLength(1)))) s" } ?? ""))
                    .font(AppTypography.supportingDense).foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func background(for kind: AskChip.Kind) -> AnyShapeStyle {
        switch kind {
        case .target: AnyShapeStyle(Color.accentColor.opacity(0.25))
        case .alternative: AnyShapeStyle(Color.clear)
        default: AnyShapeStyle(.quaternary)
        }
    }
}

/// Chips that wrap onto new lines.
struct AskFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arranged = arrange(width: bounds.width, subviews: subviews)
        for (index, frame) in arranged.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height); maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), frames)
    }
}


/// A small line under the Ask box: which model answers, a warning when it is the on-device one, and a link to where it is
/// changed. Re-reads the stored choice, so it follows a change made in Settings while the Query tab stays on screen.
struct AskEngineIndicator: View {
    @AppStorage(AskSettingsStore.key) private var stored: Data?

    /// What to say for a given choice; separate from the view so the wording can be checked.
    nonisolated static func describe(_ settings: AskSettings) -> (title: String, warning: String?, note: String?) {
        let engine = settings.selected
        guard engine != .onDevice else {
            return ("Apple on-device", "Limited: the on-device model understands fewer kinds of request and often misreads them. Check the filters before running, or choose a larger model.", nil)
        }
        let model = settings.config(for: engine).model
        return (model.isEmpty ? engine.label : "\(engine.label) · \(model)", nil, engine.localSpeedNote)
    }

    var body: some View {
        AskEngineIndicatorLine(settings: stored.flatMap { try? JSONDecoder().decode(AskSettings.self, from: $0) } ?? AskSettings())
    }
}

/// The indicator for a given choice (the view above feeds it the stored one; a layout check feeds it any).
struct AskEngineIndicatorLine: View {
    let settings: AskSettings
    @AppStorage(SettingsTab.storageKey) private var settingsTab = SettingsTab.general.rawValue

    var body: some View {
        let description = AskEngineIndicator.describe(settings)
        let icon = Image(systemName: settings.selected == .onDevice ? "laptopcomputer" : "cloud").imageScale(.small)
        let title = Text("Answering with ") + Text(description.title).fontWeight(.medium)
        // The tab is chosen as the window opens (the Settings tabs follow this stored value, whenever it changes).
        let link = SettingsLink { Text("Change in Settings") }
            .simultaneousGesture(TapGesture().onEnded { settingsTab = SettingsTab.ask.rawValue })
            .buttonStyle(.link).foregroundStyle(Color.accentColor).fixedSize()
            .help("Open Settings › Ask to choose another model.")
        VStack(alignment: .leading, spacing: 3) {
            // One line when it fits; otherwise the link drops under the model name, which may then wrap.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    icon
                    title.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 8)
                    link
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        icon
                        title.fixedSize(horizontal: false, vertical: true)
                    }
                    link
                }
            }
            if let warning = description.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = description.note {
                Label(note, systemImage: "clock")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(AppTypography.compactMetadata)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 2)
    }
}
