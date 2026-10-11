import SwiftUI
import SwiftData

// MARK: - A tagging job

/// What to tag, with what, and how — the input to a review. The source is a closure so a review always reads the
/// CURRENT playlist or query result, never a frozen list.
struct TagJob: Identifiable {
    let id = UUID()
    /// "Running - All", "Query results", …
    let title: String
    let tags: [String]
    let mode: TagMode
    /// A saved rule this job came from or should update.
    var ruleID: UUID?
    /// Playlist jobs always read the Music library too (for other versions and exact lengths); other sources can
    /// opt in.
    let readsMusicLibrary: Bool
    let loadSource: @MainActor () async throws -> [TagSourceTrack]
}

// MARK: - Review model

/// Builds the plan for a job and holds what's selected. The plan is a pure function of the source, the scrobble
/// history and the cached personal tags (`TagPlanEngine`), recomputed on demand — never stored.
@MainActor
@Observable
final class TagReviewModel {
    private(set) var plan: TagPlan?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var readSeconds: Double?
    /// `TagPlanItem.id`s that will be written.
    var selected: Set<String> = []

    private var index: ScrobbleTrackIndex?
    private var library: [AppleMusicTrack]?

    func reset() {
        plan = nil
        errorMessage = nil
        selected = []
    }

    /// `includeLibrary`: read Music's library so other versions have exact lengths.
    func load(job: TagJob, container: ModelContainer, includeLibrary: Bool, refreshIndex: Bool = false) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        let started = Date()
        do {
            let source = try await job.loadSource()
            if includeLibrary || job.readsMusicLibrary {
                library = try await AppleMusicPlaylistReader.readLibrary()
            } else {
                library = nil
            }
            if index == nil || refreshIndex {
                let scrobbles = try await offMain {
                    QueryIdentity.canonicalizingArtists(try await ScrobbleSnapshotReader(modelContainer: container).fetchSortedSnapshots())
                }
                index = await Task.detached(priority: .userInitiated) { ScrobbleTrackIndex(scrobbles: scrobbles) }.value
            }
            guard let index else { return }
            let personal = await TagPersonalReader(modelContainer: container).snapshot()
            let library = library
            let tags = job.tags, mode = job.mode
            let computed = await Task.detached(priority: .userInitiated) {
                TagPlanEngine.plan(
                    source: source, tags: tags, mode: mode, index: index,
                    personal: personal.personal, personalTagsKnown: personal.synced, library: library
                )
            }.value
            plan = computed
            selected = Self.defaultSelection(computed)
            readSeconds = Date().timeIntervalSince(started)
        } catch {
            plan = nil
            errorMessage = error.localizedDescription
        }
    }

    /// Everything without a version conflict is selected; conflicts are NEVER pre-selected — the user opts in.
    static func defaultSelection(_ plan: TagPlan) -> Set<String> {
        Set((plan.adds + plan.removals).filter { $0.conflict == nil }.map(\.id))
    }

    var selectedAdds: [TagPlanItem] { (plan?.adds ?? []).filter { selected.contains($0.id) } }
    var selectedRemovals: [TagPlanItem] { (plan?.removals ?? []).filter { selected.contains($0.id) } }

    func ops() -> [TagWriteOp] {
        selectedRemovals.map { TagWriteOp(artist: $0.target.artist, track: $0.target.track, add: [], remove: $0.tags) }
            + selectedAdds.map { TagWriteOp(artist: $0.target.artist, track: $0.target.track, add: $0.tags, remove: []) }
    }

    /// Last.fm calls these ops take: one per removal, and one per 10 tags added.
    func callCount() -> Int {
        let cap = LastfmTagNormalization.maxTagsPerCall
        return ops().reduce(0) { $0 + $1.remove.count + ($1.add.isEmpty ? 0 : (($1.add.count + cap - 1) / cap)) }
    }
}

// MARK: - Review view

/// The preview and apply surface, shared by the Tag Management page and the "Tag these…" sheet. Nothing can be
/// applied until the list and counts it would act on are on screen.
struct TagReviewView: View {
    let job: TagJob
    let modelContainer: ModelContainer
    let navigation: DetailNavigationCoordinator?
    /// A Query source can't tell versions apart by length unless Music is read; the tool offers it.
    var offersMusicLengths = false
    var onApplied: (() -> Void)?

    @Environment(\.modelContext) private var modelContext
    @Environment(TagWriteRunner.self) private var writer
    @State private var model = TagReviewModel()
    @State private var includeMusicLengths = false
    @State private var confirming = false
    @State private var showAlready = false
    @State private var showNotScrobbled = false
    @State private var showUncertain = false
    @State private var isSyncingTags = false
    @State private var syncStatus: String?

    private var isConnected: Bool { LastfmCredentialsStore.load()?.sessionKey != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.isLoading && model.plan == nil {
                ProgressView("Building the review…").frame(maxWidth: .infinity, minHeight: 120)
            } else if let error = model.errorMessage {
                ContentUnavailableView {
                    Label("Couldn’t build the review", systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: {
                    Button("Try again") { Task { await reload() } }
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            } else if let plan = model.plan {
                summary(plan)
                if !plan.personalTagsKnown { syncBanner }
                runnerStatus
                review(plan)
                applyBar
            }
        }
        .task(id: job.id) { await reload() }
        .confirmationDialog(confirmTitle, isPresented: $confirming, titleVisibility: .visible) {
            Button("Apply to Last.fm") { apply() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    private func reload() async {
        await model.load(job: job, container: modelContainer, includeLibrary: includeMusicLengths)
    }

    // MARK: Summary

    private func summary(_ plan: TagPlan) -> some View {
        let conflicts = (plan.adds + plan.removals).filter { $0.conflict != nil }
        return ToolHeadlineCard("REVIEW · \(job.title.uppercased())") {
            VStack(alignment: .leading, spacing: 6) {
                Text(headline(plan))
                HStack(spacing: 14) {
                    if !plan.adds.isEmpty || job.mode != .remove { Label("\(plan.adds.count.formatted()) to add", systemImage: "plus.circle") }
                    if !plan.removals.isEmpty || job.mode != .add { Label("\(plan.removals.count.formatted()) to remove", systemImage: "minus.circle") }
                    Label("\(plan.alreadyDone.count.formatted()) \(job.mode == .remove ? "don’t have it" : "already tagged")", systemImage: "checkmark.circle")
                    if !conflicts.isEmpty {
                        Label("\(conflicts.count.formatted()) share a title with another album", systemImage: "square.on.square")
                            .foregroundStyle(.orange)
                    }
                }
                .font(AppTypography.contentTitle)
                Text(footnote(plan))
                    .font(AppTypography.compactMetadata).fontWeight(.regular).foregroundStyle(.secondary)
            }
        }
    }

    private func headline(_ plan: TagPlan) -> String {
        let tags = job.tags.map { "“\($0)”" }.formatted(.list(type: .and))
        switch job.mode {
        case .add: return "Tag \(plan.resolvedCount.formatted()) tracks \(tags)"
        case .remove: return "Remove \(tags) from \(plan.resolvedCount.formatted()) tracks"
        case .mirror: return "Make \(tags) match “\(job.title)” — \(plan.resolvedCount.formatted()) tracks"
        }
    }

    private func footnote(_ plan: TagPlan) -> String {
        var parts = ["\(plan.sourceCount.formatted()) tracks in the source"]
        if !plan.notScrobbled.isEmpty { parts.append("\(plan.notScrobbled.count.formatted()) not scrobbled (skipped)") }
        if !plan.uncertain.isEmpty { parts.append("\(plan.uncertain.count.formatted()) uncertain matches (skipped)") }
        if let seconds = model.readSeconds { parts.append("built in \(seconds.formatted(.number.precision(.fractionLength(1)))) s") }
        return parts.joined(separator: " · ")
    }

    private var syncBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Your Last.fm tags haven’t been synced yet").font(AppTypography.contentTitle)
                Text(syncStatus ?? "Until they are, “already tagged” is unknown, so tracks that have the tag will show as needing it. Applying is still safe — adding a tag twice does nothing.")
                    .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
            }
            Spacer()
            Button(isSyncingTags ? "Syncing…" : "Sync tags") { Task { await syncPersonalTags() } }
                .disabled(isSyncingTags)
        }
        .padding(12)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func syncPersonalTags() async {
        guard let credentials = LastfmCredentialsStore.load() else { syncStatus = "Connect Last.fm in Settings first."; return }
        isSyncingTags = true
        defer { isSyncingTags = false }
        do {
            let client = LastfmAPIClient(apiKey: credentials.apiKey, username: credentials.username)
            try await EntityTagsEngine.syncPersonalTags(client: client, context: modelContext) { syncStatus = "Syncing \($0)…" }
            syncStatus = nil
            await reload()
        } catch {
            syncStatus = "Couldn’t sync your tags: \(error.localizedDescription)"
        }
    }

    // MARK: Runner

    @ViewBuilder
    private var runnerStatus: some View {
        switch writer.state {
        case .idle:
            EmptyView()
        case .running(let done, let total):
            HStack(spacing: 12) {
                ProgressView(value: Double(done), total: Double(max(total, 1))).frame(maxWidth: 260)
                Text("Applying \(done.formatted()) of \(total.formatted())…").font(AppTypography.metadata.monospacedDigit())
                Spacer()
                Button("Cancel", role: .cancel) { writer.cancel() }
            }
            .padding(12)
            .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .finished(let summary):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: summary.failures.isEmpty && summary.stoppedEarly == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(summary.failures.isEmpty && summary.stoppedEarly == nil ? .green : .orange)
                    Text(finishedText(summary)).font(AppTypography.contentTitle)
                    Spacer()
                    Button("Dismiss") { writer.dismissResult() }
                }
                if let stopped = summary.stoppedEarly { Text(stopped).font(AppTypography.compactMetadata).foregroundStyle(.secondary) }
                ForEach(summary.failures.prefix(6)) { failure in
                    Text("\(failure.artist) — \(failure.track): \(failure.message)")
                        .font(AppTypography.compactMetadata).foregroundStyle(.secondary).lineLimit(1)
                }
                if summary.failures.count > 6 { Text("…and \(summary.failures.count - 6) more").font(AppTypography.compactMetadata).foregroundStyle(.secondary) }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func finishedText(_ summary: TagWriteRunner.Summary) -> String {
        var text = "\(summary.applied.formatted()) of \(summary.total.formatted()) tracks updated"
        if summary.cancelled { text += " — cancelled; run the review again to finish the rest" }
        if !summary.failures.isEmpty { text += " · \(summary.failures.count) failed" }
        return text
    }

    // MARK: Review lists

    @ViewBuilder
    private func review(_ plan: TagPlan) -> some View {
        let plain = (plan.adds + plan.removals).filter { $0.conflict == nil }
        let conflicts = (plan.adds + plan.removals).filter { $0.conflict != nil }
        if !plain.isEmpty {
            section(title: job.mode == .add ? "Will add" : "Will change", count: plain.count, selectable: plain) {
                ForEach(plain) { item in itemRow(item) }
            }
        }
        if !conflicts.isEmpty {
            conflictSection(conflicts)
        }
        if plain.isEmpty && conflicts.isEmpty {
            ContentUnavailableView(
                "Nothing to change", systemImage: "checkmark.circle",
                description: Text(job.mode == .remove ? "None of these tracks carry the tag." : "Every track in the source already has the tag.")
            )
            .frame(maxWidth: .infinity, minHeight: 140)
        }
        disclosure("Already done", count: plan.alreadyDone.count, isOn: $showAlready) {
            ForEach(plan.alreadyDone) { item in plainRow(item.target.track, item.target.artist) }
        }
        disclosure("Not scrobbled — skipped", count: plan.notScrobbled.count, isOn: $showNotScrobbled) {
            ForEach(Array(plan.notScrobbled.enumerated()), id: \.offset) { _, t in plainRow(t.track, t.artist) }
        }
        disclosure("Uncertain matches — skipped", count: plan.uncertain.count, isOn: $showUncertain) {
            ForEach(Array(plan.uncertain.enumerated()), id: \.offset) { _, u in
                plainRow(u.source.track, "\(u.source.artist) · possibly “\(u.candidate.track)” by \(u.candidate.artist)")
            }
        }
    }

    private func section<Content: View>(title: String, count: Int, selectable: [TagPlanItem], @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(title) · \(count.formatted())").font(AppTypography.sectionTitle).foregroundStyle(.secondary)
                Spacer()
                Button("Select all") { model.selected.formUnion(selectable.map(\.id)) }.buttonStyle(.link)
                Button("None") { model.selected.subtract(selectable.map(\.id)) }.buttonStyle(.link)
            }
            card { content() }
        }
    }

    private func conflictSection(_ conflicts: [TagPlanItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Share a title with another album · \(conflicts.count.formatted())").font(AppTypography.sectionTitle).foregroundStyle(.orange)
                Spacer()
                Button("Select likely reissues") {
                    model.selected.formUnion(conflicts.filter { $0.conflict?.kind == .sameRecording }.map(\.id))
                }.buttonStyle(.link)
                Button("None") { model.selected.subtract(conflicts.map(\.id)) }.buttonStyle(.link)
            }
            Text("Last.fm tags a title, not an album, so the tag would also land on the other versions below. They’re unchecked — tick the ones where that’s fine.")
                .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
            card { ForEach(conflicts) { item in itemRow(item) } }
        }
    }

    private func disclosure<Content: View>(_ title: String, count: Int, isOn: Binding<Bool>, @ViewBuilder content: () -> Content) -> some View {
        let built = content()
        return Group {
            if count > 0 {
                DisclosureGroup("\(title) · \(count.formatted())", isExpanded: isOn) {
                    card { built }
                }
                .font(AppTypography.sectionTitle).foregroundStyle(.secondary)
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        LazyVStack(alignment: .leading, spacing: 1) { content() }
            .padding(.horizontal, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator.opacity(0.4), lineWidth: 1) }
    }

    private func plainRow(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(AppTypography.contentTitle).lineLimit(1)
            Text(subtitle).font(AppTypography.compactMetadata).foregroundStyle(.secondary).lineLimit(1)
            Divider().padding(.top, 6)
        }
        .padding(.top, 6)
    }

    private func itemRow(_ item: TagPlanItem) -> some View {
        let isOn = Binding(get: { model.selected.contains(item.id) }, set: { on in
            if on { model.selected.insert(item.id) } else { model.selected.remove(item.id) }
        })
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Toggle("", isOn: isOn).toggleStyle(.checkbox).labelsHidden().padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.target.track).font(AppTypography.contentTitle).lineLimit(1)
                    Text(item.target.artist).font(AppTypography.metadata).foregroundStyle(.secondary).lineLimit(1)
                    if let conflict = item.conflict { conflictDetail(conflict) }
                }
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    ForEach(item.tags, id: \.self) { tag in
                        Text("\(item.action == .remove ? "−" : "+") \(tag)")
                            .font(AppTypography.compactMetadata)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background((item.action == .remove ? Color.red : Color.accentColor).opacity(0.15), in: Capsule())
                    }
                }
                Text("\(item.target.plays.formatted()) \(item.target.plays == 1 ? "play" : "plays")")
                    .font(AppTypography.metadata.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(minWidth: 70, alignment: .trailing)
            }
            .padding(.vertical, 8)
            Divider()
        }
        .contentShape(Rectangle())
        .onTapGesture { isOn.wrappedValue.toggle() }
        .contextMenu {
            if let navigation {
                Button("Open Track") {
                    navigation.goToTrack(TrackIdentity(artist: item.target.artist, name: item.target.track, album: nil, imageURL: nil))
                }
            }
        }
    }

    private func conflictDetail(_ conflict: TagVersionConflict) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text(kindText(conflict.kind))
            } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                .font(AppTypography.supportingDense).foregroundStyle(.orange)
            ForEach(conflict.others.prefix(3), id: \.self) { other in
                Text(otherText(other)).font(AppTypography.compactMetadata).foregroundStyle(.secondary).lineLimit(1)
            }
            if conflict.others.count > 3 {
                Text("…and \(conflict.others.count - 3) more").font(AppTypography.compactMetadata).foregroundStyle(.tertiary)
            }
        }
    }

    private func kindText(_ kind: TagVersionConflict.Kind) -> String {
        switch kind {
        case .differentRecording: "Probably a different recording on another album"
        case .sameRecording: "Same length on another album — likely a reissue"
        case .unknownDuration: "Also on another album — couldn’t compare lengths"
        }
    }

    private func otherText(_ other: TagVersionConflict.Other) -> String {
        var text = "Also on “\(other.album)”"
        if let duration = other.duration {
            text += " · \(clock(duration))"
            if let delta = other.delta, abs(delta) >= 1 { text += " (\(delta > 0 ? "+" : "−")\(clock(abs(delta))))" }
        }
        text += " · \(other.plays.formatted()) \(other.plays == 1 ? "play" : "plays")"
        return text
    }

    private func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }

    // MARK: Apply

    private var applyBar: some View {
        HStack(spacing: 12) {
            if offersMusicLengths {
                Toggle("Compare lengths with Music", isOn: $includeMusicLengths)
                    .toggleStyle(.checkbox)
                    .help("Reads your Music library so other versions of a track show their lengths (needs Music open).")
                    .onChange(of: includeMusicLengths) { _, _ in Task { await reload() } }
            }
            Spacer()
            Text(selectionSummary).font(AppTypography.metadata.monospacedDigit()).foregroundStyle(.secondary)
            Button {
                confirming = true
            } label: {
                Label("Apply to Last.fm", systemImage: "tag")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.plan == nil || model.ops().isEmpty || writer.isRunning || !isConnected || model.isLoading || Connectivity.shared.isOffline)
            .help(Connectivity.shared.isOffline ? "Offline mode is on. Go online to write to Last.fm." : (isConnected ? "Writes the selected changes to your Last.fm account." : "Connect Track Actions in Settings first."))
        }
    }

    private var selectionSummary: String {
        let adds = model.selectedAdds.count, removals = model.selectedRemovals.count
        var parts: [String] = []
        if adds > 0 { parts.append("+\(adds.formatted())") }
        if removals > 0 { parts.append("−\(removals.formatted())") }
        return parts.isEmpty ? "Nothing selected" : "\(parts.joined(separator: " ")) selected"
    }

    private var confirmTitle: String {
        "Apply \(model.ops().count.formatted()) \(model.ops().count == 1 ? "change" : "changes") to Last.fm?"
    }

    private var confirmMessage: String {
        let calls = model.callCount()
        // Measured: ~0.6 s per call end to end (pacing plus the round trip), not just the 0.33 s pacing.
        let seconds = Double(calls) * 0.6
        let time = seconds < 90 ? "under 2 minutes" : "about \(Int((seconds / 60).rounded(.up))) minutes"
        return "\(model.selectedAdds.count) to add, \(model.selectedRemovals.count) to remove — \(calls.formatted()) Last.fm calls, \(time). Tags are public on your Last.fm profile and feed the same shared tag data everyone sees. You can leave this page; it keeps going in the background, and you can cancel any time."
    }

    private func apply() {
        let ops = model.ops()
        guard !ops.isEmpty else { return }
        let ruleID = job.ruleID
        writer.start(ops: ops, context: modelContext) { summary in
            if let ruleID, summary.applied > 0 {
                var descriptor = FetchDescriptor<TagPlaylistRule>(predicate: #Predicate { $0.id == ruleID })
                descriptor.fetchLimit = 1
                if let rule = try? modelContext.fetch(descriptor).first { rule.lastAppliedAt = .now; try? modelContext.save() }
            }
            Task { await reload() }
            onApplied?()
        }
    }
}

// MARK: - Tag names field

/// Tags as removable chips plus a text box (comma or Return adds), with suggestions from the tags you already use.
struct TagNamesField: View {
    @Binding var tags: [String]
    let suggestions: [String]

    @State private var text = ""

    private var matches: [String] {
        let query = LastfmTagNormalization.normalize(text)
        guard !query.isEmpty else { return [] }
        return Array(suggestions.filter { !tags.contains($0) && $0.contains(query) }.prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !tags.isEmpty {
                TagFlowLayout(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        Button { tags.removeAll { $0 == tag } } label: {
                            HStack(spacing: 4) { Text(tag); Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(.tint.opacity(0.2), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Remove “\(tag)” from this list")
                    }
                }
            }
            TextField("Tags (comma-separated) — e.g. running", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commit(text) }
                .onChange(of: text) { _, new in if new.contains(",") { commit(new) } }
            if !matches.isEmpty {
                TagFlowLayout(spacing: 6) {
                    ForEach(matches, id: \.self) { tag in
                        Button(tag) { commit(tag) }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
            if tags.count > LastfmTagNormalization.maxTagsPerCall {
                Text("Last.fm accepts 10 tags at a time; more are sent in batches.").font(AppTypography.supportingDense).foregroundStyle(.secondary)
            }
        }
    }

    private func commit(_ raw: String) {
        let fresh = LastfmTagNormalization.normalizeList([raw]).filter { !tags.contains($0) }
        tags.append(contentsOf: fresh)
        text = ""
    }
}

// MARK: - The tool page

/// "Tag Management": bulk-add or remove Last.fm tags for a whole Apple Music playlist or a saved Query. Saved rules
/// remember playlist → tags so a playlist that has changed is one review away from being in step again.
struct TagManagementView: View {
    let modelContainer: ModelContainer
    let navigation: DetailNavigationCoordinator

    enum SourceKind: String, Codable, CaseIterable, Identifiable {
        case playlist, savedQuery
        var id: Self { self }
        var label: String { self == .playlist ? "Apple Music playlist" : "Saved query" }
    }

    struct Options: Codable, Equatable {
        var source = SourceKind.playlist
        var mode = TagMode.add
        /// Set once the playlist list has been read — Automation permission is then granted, so a later visit may
        /// load it without asking.
        var hasLoadedPlaylists = false
    }

    private static let toolId = "tagManagement"

    @Environment(\.modelContext) private var modelContext
    @Environment(PopularityStore.self) private var popularityStore
    @Query(sort: \TagPlaylistRule.playlistName) private var rules: [TagPlaylistRule]
    @Query(sort: \SavedConditionSet.name) private var savedSets: [SavedConditionSet]

    @State private var options = Options()
    @State private var didLoad = false
    @State private var playlists: [AppleMusicPlaylistInfo]?
    @State private var isLoadingPlaylists = false
    @State private var playlistError: String?
    @State private var playlistFilter = ""
    @State private var selectedPlaylistID: String?
    @State private var selectedSetID: UUID?
    @State private var tags: [String] = []
    @State private var job: TagJob?
    @State private var ruleToDelete: TagPlaylistRule?

    private var vocabulary: [String] {
        guard let username = LastfmCredentialsStore.load()?.username else { return [] }
        return PersonalTagVocabulary.tags(for: username)
    }

    private var selectedPlaylist: AppleMusicPlaylistInfo? { playlists?.first { $0.id == selectedPlaylistID } }
    private var selectedSet: SavedConditionSet? { savedSets.first { $0.id == selectedSetID } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageSettingsHeader("Tag Management") { EmptyView() }
                intro
                if !rules.isEmpty { rulesSection }
                newSection
                if let job {
                    TagReviewView(job: job, modelContainer: modelContainer, navigation: navigation, offersMusicLengths: options.source == .savedQuery)
                        .id(job.id)
                }
            }
            .padding(16)
        }
        .navigationTitle("Tag Management")
        .task {
            guard !didLoad else { return }
            options = ToolFilterSettingsStore.load(Options.self, toolId: Self.toolId, context: modelContext, default: Options())
            didLoad = true
            if options.hasLoadedPlaylists, AppleMusicFavoritesReader.isMusicRunning { await loadPlaylists() }
        }
        .onChange(of: options) { _, new in
            guard didLoad else { return }
            ToolFilterSettingsStore.save(new, toolId: Self.toolId, context: modelContext)
        }
        .confirmationDialog(
            "Delete this rule?", isPresented: Binding(get: { ruleToDelete != nil }, set: { if !$0 { ruleToDelete = nil } }), titleVisibility: .visible
        ) {
            Button("Delete Rule", role: .destructive) {
                if let rule = ruleToDelete { modelContext.delete(rule); try? modelContext.save() }
                ruleToDelete = nil
            }
            Button("Cancel", role: .cancel) { ruleToDelete = nil }
        } message: {
            Text("The rule is forgotten; tags already on Last.fm stay as they are.")
        }
    }

    private var intro: some View {
        ToolHeadlineCard("BULK TAGS") {
            Text("Pick a playlist or saved query, say which tags, and review exactly what would change before anything is written to Last.fm.")
        }
    }

    // MARK: Rules

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Saved rules").font(AppTypography.sectionTitle).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                ForEach(rules) { rule in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.playlistName).font(AppTypography.contentTitle).lineLimit(1)
                            HStack(spacing: 6) {
                                ForEach(rule.tags, id: \.self) { tag in
                                    Text(tag).font(AppTypography.compactMetadata)
                                        .padding(.horizontal, 7).padding(.vertical, 2)
                                        .background(.tint.opacity(0.15), in: Capsule())
                                }
                                if rule.mirrorRemovals { Text("mirrors removals").font(AppTypography.compactMetadata).foregroundStyle(.secondary) }
                            }
                            Text(rule.lastAppliedAt.map { "Last applied \($0.formatted(.relative(presentation: .named)))" } ?? "Not applied yet")
                                .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Review changes") { review(rule: rule) }
                        Button(role: .destructive) { ruleToDelete = rule } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 8)
                    Divider()
                }
            }
            .padding(.horizontal, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator.opacity(0.4), lineWidth: 1) }
        }
    }

    private func review(rule: TagPlaylistRule) {
        let id = rule.playlistPersistentID, name = rule.playlistName
        tags = rule.tags
        options.source = .playlist
        options.mode = rule.mirrorRemovals ? .mirror : .add
        selectedPlaylistID = id
        job = TagJob(
            title: name, tags: rule.tags, mode: rule.mirrorRemovals ? .mirror : .add, ruleID: rule.id, readsMusicLibrary: true,
            loadSource: { try await Self.readPlaylist(id: id, name: name) }
        )
    }

    // MARK: New

    private var newSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New").font(AppTypography.sectionTitle).foregroundStyle(.secondary)
            Picker("Source", selection: $options.source) {
                ForEach(SourceKind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()

            switch options.source {
            case .playlist: playlistPicker
            case .savedQuery: savedQueryPicker
            }

            TagNamesField(tags: $tags, suggestions: vocabulary)

            HStack(spacing: 12) {
                Picker("Action", selection: $options.mode) {
                    Text("Add tags").tag(TagMode.add)
                    Text("Remove tags").tag(TagMode.remove)
                    if options.source == .playlist { Text("Make tags match playlist").tag(TagMode.mirror) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                if options.source == .playlist, let playlist = selectedPlaylist, !tags.isEmpty, options.mode != .remove {
                    Button("Save as rule") { saveRule(playlist) }
                        .help("Remember this playlist → tags mapping so you can review it again later.")
                }
                Button("Review changes") { startReview() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canReview)
            }
            if options.mode == .mirror {
                Text("“Make tags match” also offers to remove the tags from tracks that are no longer in the playlist. Removals are listed and ticked for you to check first.")
                    .font(AppTypography.supportingDense).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator.opacity(0.4), lineWidth: 1) }
        .onChange(of: options.source) { _, new in
            if new == .savedQuery, options.mode == .mirror { options.mode = .add }
            job = nil
        }
    }

    private var canReview: Bool {
        guard !tags.isEmpty else { return false }
        switch options.source {
        case .playlist: return selectedPlaylist != nil
        case .savedQuery: return selectedSet != nil
        }
    }

    @ViewBuilder
    private var playlistPicker: some View {
        if let playlists {
            let filtered = playlists.filter { playlistFilter.isEmpty || $0.name.localizedCaseInsensitiveContains(playlistFilter) }
            HStack(spacing: 10) {
                TextField("Filter playlists", text: $playlistFilter).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                Picker("Playlist", selection: $selectedPlaylistID) {
                    Text("Choose a playlist").tag(String?.none)
                    ForEach(filtered) { playlist in
                        Text(playlist.isSmart ? "\(playlist.name)  (smart)" : playlist.name).tag(String?.some(playlist.id))
                    }
                }
                .labelsHidden()
                Button { Task { await loadPlaylists() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Re-read your playlists from Music")
            }
            if selectedPlaylist?.isSmart == true {
                Text("A smart playlist’s tracks change on their own, so its review is only as current as the moment you run it.")
                    .font(AppTypography.supportingDense).foregroundStyle(.secondary)
            }
        } else if isLoadingPlaylists {
            ProgressView("Reading playlists…")
        } else {
            HStack(spacing: 10) {
                Button("Load my playlists") { Task { await loadPlaylists() } }
                Text(playlistError ?? "Reads the playlist names from Music (about a second). The first time asks for permission to control Music.")
                    .font(AppTypography.supportingDense).foregroundStyle(playlistError == nil ? Color.secondary : Color.orange)
            }
        }
    }

    @ViewBuilder
    private var savedQueryPicker: some View {
        if savedSets.isEmpty {
            Text("You have no saved Query condition sets yet. Build one in Query and save it, or use “Tag these…” on any Query result.")
                .font(AppTypography.supportingDense).foregroundStyle(.secondary)
        } else {
            Picker("Saved query", selection: $selectedSetID) {
                Text("Choose a saved query").tag(UUID?.none)
                ForEach(savedSets) { set in Text(set.name).tag(UUID?.some(set.id)) }
            }
            .labelsHidden().frame(maxWidth: 320)
        }
    }

    // MARK: Actions

    private func loadPlaylists() async {
        isLoadingPlaylists = true
        playlistError = nil
        defer { isLoadingPlaylists = false }
        do {
            playlists = try await AppleMusicPlaylistReader.listPlaylists().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            options.hasLoadedPlaylists = true
        } catch {
            playlistError = error.localizedDescription
        }
    }

    private func startReview() {
        let tags = LastfmTagNormalization.normalizeList(tags)
        guard !tags.isEmpty else { return }
        switch options.source {
        case .playlist:
            guard let playlist = selectedPlaylist else { return }
            let id = playlist.id, name = playlist.name
            let ruleID = rules.first { $0.playlistPersistentID == id && $0.tags == tags }?.id
            job = TagJob(
                title: name, tags: tags, mode: options.mode, ruleID: ruleID, readsMusicLibrary: true,
                loadSource: { try await Self.readPlaylist(id: id, name: name) }
            )
        case .savedQuery:
            guard let set = selectedSet else { return }
            let container = modelContainer
            let popularity = popularityStore
            job = TagJob(
                title: set.name, tags: tags, mode: options.mode == .mirror ? .add : options.mode, ruleID: nil, readsMusicLibrary: false,
                loadSource: { try await TagQuerySource.tracks(for: set, container: container, popularity: popularity) }
            )
        }
    }

    private func saveRule(_ playlist: AppleMusicPlaylistInfo) {
        let normalized = LastfmTagNormalization.normalizeList(tags)
        if let existing = rules.first(where: { $0.playlistPersistentID == playlist.id }) {
            existing.tags = normalized
            existing.playlistName = playlist.name
            existing.mirrorRemovals = options.mode == .mirror
        } else {
            modelContext.insert(TagPlaylistRule(
                playlistPersistentID: playlist.id, playlistName: playlist.name, tags: normalized, mirrorRemovals: options.mode == .mirror
            ))
        }
        try? modelContext.save()
    }

    /// Reads a playlist by its persistent ID; if it's gone (rebuilt, so the ID changed), finds the one with the same name.
    static func readPlaylist(id: String, name: String) async throws -> [TagSourceTrack] {
        let tracks: [AppleMusicTrack]
        do {
            tracks = try await AppleMusicPlaylistReader.readPlaylist(id: id)
        } catch AppleMusicFavoritesReader.ReadError.musicNotRunning {
            throw AppleMusicFavoritesReader.ReadError.musicNotRunning
        } catch {
            guard let match = try await AppleMusicPlaylistReader.listPlaylists().first(where: { $0.name == name }) else { throw error }
            tracks = try await AppleMusicPlaylistReader.readPlaylist(id: match.id)
        }
        return tracks.map { TagSourceTrack(artist: $0.artist, track: $0.name, album: $0.album, duration: $0.duration) }
    }
}

// MARK: - "Tag these…" sheet (from Query results)

/// The same review surface over a fixed list of tracks — the rows of a Query result. The list is shown, with counts,
/// before anything can be applied.
struct TagTracksSheet: View {
    let tracks: [TagSourceTrack]
    let modelContainer: ModelContainer
    let navigation: DetailNavigationCoordinator?

    @Environment(\.dismiss) private var dismiss
    @State private var tags: [String] = []
    @State private var mode = TagMode.add
    @State private var job: TagJob?

    private var vocabulary: [String] {
        guard let username = LastfmCredentialsStore.load()?.username else { return [] }
        return PersonalTagVocabulary.tags(for: username)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Tag \(tracks.count.formatted()) \(tracks.count == 1 ? "track" : "tracks")").font(AppTypography.pageTitle)
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                TagNamesField(tags: $tags, suggestions: vocabulary)
                HStack {
                    Picker("Action", selection: $mode) {
                        Text("Add tags").tag(TagMode.add)
                        Text("Remove tags").tag(TagMode.remove)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Spacer()
                    Button("Review changes") {
                        let normalized = LastfmTagNormalization.normalizeList(tags)
                        let snapshot = tracks
                        job = TagJob(title: "Query results", tags: normalized, mode: mode, ruleID: nil, readsMusicLibrary: false, loadSource: { snapshot })
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(tags.isEmpty)
                }
                if let job {
                    TagReviewView(job: job, modelContainer: modelContainer, navigation: navigation, offersMusicLengths: true)
                        .id(job.id)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 760, minHeight: 560)
    }
}
