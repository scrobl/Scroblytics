import AppKit
import SwiftData
import SwiftUI

/// Tools › Auto-Updating Playlists: the Apple Music playlists Scroblytics keeps up to date after each sync. Each row says what the
/// playlist is made from and how its last refresh went, and can be refreshed now, switched off, shown in Music, or stopped (the
/// playlist stays in Music). New ones are added here from a Top Charts preset or a saved Query, or from the dialog of any playlist button
/// that offers "Keep this playlist updated after each sync".
struct AutoPlaylistsView: View {
    let modelContainer: ModelContainer
    let navigation: DetailNavigationCoordinator
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AutoPlaylist.createdAt) private var lists: [AutoPlaylist]
    private let scheduler = AutoPlaylistScheduler.shared
    @State private var isAdding = false
    @State private var stopping: AutoPlaylist?
    @State private var refreshingID: UUID?
    @State private var musicIsOpen = AppleMusicFavoritesReader.isMusicRunning
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageSettingsHeader("Auto-Updating Playlists") { controls }
                ToolHeadlineCard("KEPT UP TO DATE AFTER EVERY SYNC") {
                    Text("Each playlist here follows a chart or query: after a sync Scroblytics runs it again and changes the playlist in Music to match, in rank order, never adding a song twice. Music has to be open.")
                }
                if !musicIsOpen && !lists.isEmpty { musicClosedNote }
                if lists.isEmpty {
                    ContentUnavailableView(
                        "No playlists kept up to date",
                        systemImage: "arrow.triangle.2.circlepath",
                        description: Text("Press Add Playlist, or turn on “Keep this playlist updated after each sync” when you create an Apple Music playlist from Top Charts or Query.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    VStack(spacing: 10) {
                        ForEach(lists) { list in
                            AutoPlaylistRow(
                                list: list, isRefreshing: refreshingID == list.id || scheduler.isRefreshing,
                                onRefresh: { refresh(list) }, onShow: { show(list) }, onMakeAgain: { makeAgain(list) },
                                onStop: { stopping = list }, onToggle: { try? modelContext.save() }
                            )
                        }
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("Auto-Updating Playlists")
        .onReceive(NotificationCenter.default.publisher(for: .autoPlaylistsDidRefresh)) { _ in musicIsOpen = AppleMusicFavoritesReader.isMusicRunning }
        .sheet(isPresented: $isAdding) { AddAutoPlaylistSheet(modelContainer: modelContainer) { isAdding = false } }
        .confirmationDialog(
            "Stop updating “\(stopping?.name ?? "")”?", isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } }),
            titleVisibility: .visible
        ) {
            Button("Stop Updating", role: .destructive) {
                if let list = stopping { try? AutoPlaylistStore.stopUpdating(list, context: modelContext) }
                stopping = nil
            }
            Button("Cancel", role: .cancel) { stopping = nil }
        } message: {
            Text("The playlist stays in Music exactly as it is now; it just stops following the list.")
        }
        .alert("Auto-Updating Playlists", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button("Add Playlist…", systemImage: "plus") { isAdding = true }
            Button("Refresh All Now", systemImage: "arrow.clockwise") {
                Task {
                    await scheduler.refreshAll(container: modelContainer, reason: "asked", everything: true)
                    musicIsOpen = AppleMusicFavoritesReader.isMusicRunning
                }
            }
            .disabled(lists.filter(\.isEnabled).isEmpty || scheduler.isRefreshing)
            if scheduler.isRefreshing { ProgressView().controlSize(.small) }
            Spacer()
            HelpLinkButton(articleID: "tool-auto-playlists")
        }
    }

    private var musicClosedNote: some View {
        Label("Music isn’t open. The playlists update after the next sync once it is, or press Refresh All Now.", systemImage: "music.note")
            .font(AppTypography.metadata)
            .foregroundStyle(.orange)
    }

    private func refresh(_ list: AutoPlaylist) {
        refreshingID = list.id
        Task {
            await scheduler.refresh(list, container: modelContainer)
            refreshingID = nil
            musicIsOpen = AppleMusicFavoritesReader.isMusicRunning
        }
    }

    private func show(_ list: AutoPlaylist) {
        Task {
            let shown = (try? await AppleMusicPlaylistBackend().reveal(id: list.playlistPersistentID)) ?? false
            if !shown { message = "Couldn’t show the playlist. Music has to be open, and the playlist still in it." }
        }
    }

    private func makeAgain(_ list: AutoPlaylist) {
        AutoPlaylistStore.makeAgain(list)
        refresh(list)
    }
}

struct AutoPlaylistRow: View {
    let list: AutoPlaylist
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onShow: () -> Void
    let onMakeAgain: () -> Void
    let onStop: () -> Void
    let onToggle: () -> Void
    @State private var showsMissing = false

    private var status: AutoPlaylistStatus { list.status }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: status.isProblem ? "exclamationmark.triangle.fill" : (status == .neverRun ? "circle.dashed" : "checkmark.circle.fill"))
                    .foregroundStyle(status.isProblem ? .orange : (status == .neverRun ? Color.secondary : .green))
                VStack(alignment: .leading, spacing: 2) {
                    Text(list.name).font(AppTypography.contentTitle).lineLimit(1)
                    Text(list.sourceSummary).font(AppTypography.metadata).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 12)
                Toggle("Update after each sync", isOn: Binding(get: { list.isEnabled }, set: { list.isEnabled = $0; onToggle() }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .help("Update after each sync")
                    .accessibilityLabel("Update after each sync")
            }
            Text(AutoPlaylistRowText.status(list))
                .font(AppTypography.metadata)
                .foregroundStyle(status.isProblem ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let times = AutoPlaylistRowText.times(list) {
                Text(times).font(AppTypography.compactMetadata).foregroundStyle(.tertiary)
            }
            if list.lastMissingCount > 0 && !list.lastMissingSample.isEmpty {
                DisclosureGroup(isExpanded: $showsMissing) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(list.lastMissingSample.split(separator: "\n").enumerated()), id: \.offset) { _, line in
                            Text(String(line)).font(AppTypography.compactMetadata).lineLimit(1)
                        }
                        if list.lastMissingCount > list.lastMissingSample.split(separator: "\n").count {
                            Text("and \((list.lastMissingCount - list.lastMissingSample.split(separator: "\n").count).formatted()) more")
                                .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                        }
                        Button("Copy Names") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(list.lastMissingSample, forType: .string)
                        }
                        .controlSize(.small)
                    }
                    .padding(.top, 4)
                } label: {
                    Text("\(list.lastMissingCount.formatted()) not in your library").font(AppTypography.compactMetadata)
                }
            }
            HStack(spacing: 10) {
                Button("Refresh Now", systemImage: "arrow.clockwise", action: onRefresh).disabled(isRefreshing)
                if status == .playlistMissing {
                    Button("Make It Again", systemImage: "plus.circle", action: onMakeAgain).disabled(isRefreshing)
                } else {
                    Button("Show in Music", systemImage: "music.note.list", action: onShow).disabled(list.playlistPersistentID.isEmpty)
                }
                Spacer()
                Button("Stop Updating…", role: .destructive, action: onStop)
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator.opacity(0.4), lineWidth: 1) }
        .opacity(list.isEnabled ? 1 : 0.6)
    }
}

/// The words on a row, as pure functions so they can be checked.
enum AutoPlaylistRowText {
    static func status(_ list: AutoPlaylist) -> String {
        if !list.isEnabled { return "Switched off. It isn’t refreshed after a sync; Refresh Now still works." }
        return list.lastDetail.isEmpty ? AutoPlaylistWording.detail(status: list.status, trackCount: list.lastTrackCount, added: 0, removed: 0, missing: 0) : list.lastDetail
    }

    static func times(_ list: AutoPlaylist, now: Date = Date()) -> String? {
        guard let refreshed = list.lastRefreshAt else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        var text = "Last refreshed \(formatter.localizedString(for: refreshed, relativeTo: now))"
        if let changed = list.lastChangedAt { text += " · changed \(formatter.localizedString(for: changed, relativeTo: now))" }
        return text
    }
}

/// Adds an automatic playlist from a Top Charts preset or a saved Query.
private struct AddAutoPlaylistSheet: View {
    enum Source: String, CaseIterable, Identifiable {
        case chart = "Top Charts", query = "Saved Query"
        var id: String { rawValue }
    }

    let modelContainer: ModelContainer
    let onDone: () -> Void
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SavedConditionSet.name) private var saved: [SavedConditionSet]
    @State private var source = Source.chart
    @State private var entity = TopChartsEntity.track
    @State private var rangeID = "last30"
    @State private var metric = TopChartsMetric.scrobbles
    @State private var rowLimit = 100
    @State private var savedID: UUID?
    @State private var name = ""
    @State private var nameEdited = false
    @State private var rangeOptions: [DateRangeOption] = DateRangePresets.build(oldestScrobbleDate: nil)
    @State private var isWorking = false
    @State private var existingID: String?
    @State private var isResolvingConflict = false
    @State private var errorMessage: String?

    private var eligible: [(set: SavedConditionSet, spec: QuerySpec)] { AutoPlaylistStore.eligibleQueries(saved) }

    private var periodLabel: String { rangeOptions.first { $0.id == rangeID }?.label ?? "Last 30 days" }

    private var recipe: AutoPlaylistRecipe? {
        switch source {
        case .chart: .topCharts(TopChartsPlaylistRecipe(entity: entity, rangeID: rangeID, metric: metric, rowLimit: rowLimit))
        case .query: eligible.first { $0.set.id == savedID }.map { .query($0.spec) }
        }
    }

    private var summary: String {
        switch source {
        case .chart: TopChartsPlaylistRecipe(entity: entity, rangeID: rangeID, metric: metric, rowLimit: rowLimit).summary(periodLabel: periodLabel)
        case .query: "Saved query · \(eligible.first { $0.set.id == savedID }?.set.name ?? "")"
        }
    }

    private var suggestedName: String {
        switch source {
        case .chart: "Top \(entity.displayName) · \(periodLabel)"
        case .query: eligible.first { $0.set.id == savedID }?.set.name ?? ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add an Auto-Updating Playlist").font(AppTypography.sectionTitle)
            Picker("Made from", selection: $source) {
                ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch source {
            case .chart:
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Chart").foregroundStyle(.secondary)
                        Picker("Chart", selection: $entity) { ForEach(TopChartsEntity.allCases) { Text($0.displayName).tag($0) } }.labelsHidden()
                    }
                    GridRow {
                        Text("Period").foregroundStyle(.secondary)
                        Picker("Period", selection: $rangeID) { ForEach(rangeOptions) { Text($0.label).tag($0.id) } }.labelsHidden()
                    }
                    GridRow {
                        Text("Ranked by").foregroundStyle(.secondary)
                        Picker("Ranked by", selection: $metric) { ForEach(TopChartsMetric.allCases) { Text($0.displayName).tag($0) } }.labelsHidden()
                    }
                    GridRow {
                        Text("Rows").foregroundStyle(.secondary)
                        Picker("Rows", selection: $rowLimit) { ForEach(ChartDateSettings.topChartsRowLimitOptions, id: \.self) { Text($0.formatted()).tag($0) } }.labelsHidden()
                    }
                }
                if entity != .track {
                    Text("An artist or album chart makes a playlist of the tracks played in the period by the artists or albums on it.")
                        .font(AppTypography.metadata).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            case .query:
                if eligible.isEmpty {
                    Text("There are no saved queries that list tracks yet. In Query, build one that lists Tracks and save it from the Sets menu.")
                        .font(AppTypography.metadata).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Picker("Saved query", selection: $savedID) {
                        Text("Choose…").tag(UUID?.none)
                        ForEach(eligible, id: \.set.id) { Text($0.set.name).tag(UUID?.some($0.set.id)) }
                    }
                }
            }
            TextField("Playlist name", text: Binding(get: { name }, set: { name = $0; nameEdited = true }))
                .textFieldStyle(.roundedBorder)
            Text("Changes you make to the playlist by hand are replaced at each refresh. Music must be open for it to update.")
                .font(AppTypography.metadata).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if isWorking { ProgressView().controlSize(.small); Text("Making the playlist…").font(AppTypography.metadata).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel", role: .cancel, action: onDone).disabled(isWorking)
                Button("Create and Keep Updated", action: create)
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking || recipe == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task {
            if let oldest = try? await TopChartsEngine.fetchOldestScrobbleDate(container: modelContainer) {
                rangeOptions = DateRangePresets.build(oldestScrobbleDate: oldest)
            }
            if name.isEmpty { name = suggestedName }
        }
        .onChange(of: suggestedName) { _, value in if !nameEdited { name = value } }
        .confirmationDialog("Playlist Already Exists", isPresented: $isResolvingConflict, titleVisibility: .visible) {
            if let existingID {
                Button("Replace Its Contents and Keep It Updated") { make(takeOverID: existingID) }
            }
            Button("Create New Playlist") { make(takeOverID: nil) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A playlist named “\(name)” already exists in Music.app. Replace what is in it with this list and keep it up to date, or create another playlist with the same name? Anything you added to the existing playlist by hand is removed.")
        }
        .alert("Couldn’t Make the Playlist", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isWorking = true
        Task {
            do {
                switch try await AppleMusicPlaylistBackend().findPlaylist(named: trimmed) {
                case .none: make(takeOverID: nil)
                case .found(let id): existingID = id; isWorking = false; isResolvingConflict = true
                case .notEditable:
                    isWorking = false
                    errorMessage = "A playlist named “\(trimmed)” exists in Music, but Music can’t change it (it is a smart playlist or a folder). Choose another name."
                }
            } catch AutoPlaylistError.notAuthorized {
                isWorking = false
                errorMessage = AppleMusicPlaylistExporter.ExportError.notAuthorized.localizedDescription
            } catch {
                isWorking = false
                errorMessage = "Music didn’t answer: \(error.localizedDescription) Music has to be open."
            }
        }
    }

    private func make(takeOverID: String?) {
        guard let recipe else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = summary
        isWorking = true
        Task {
            do {
                let tracks = try await AutoPlaylistSources.tracks(for: recipe, container: modelContainer, popularity: AutoPlaylistScheduler.shared.popularity)
                let made = try await AutoPlaylistCreator.create(
                    name: trimmed, recipe: recipe, summary: summary, tracks: tracks, takeOverID: takeOverID, context: modelContext
                )
                isWorking = false
                if made.list != nil { onDone() } else { errorMessage = made.outcome.detail }
            } catch {
                isWorking = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
