import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

/// "Missing Data": one field picker (Release Date, Images, Duration, Tempo, Album Match) drives
/// everything else — which entity types are offered, the coverage count, the row list, and where a
/// row-click routes. A generic front end over the Field Registry's own "has value / is missing"
/// capability, not four separate tool implementations.
struct MissingDataView: View {
    let modelContainer: ModelContainer
    let navigation: DetailNavigationCoordinator
    /// Opens Query on `spec` (the "Advanced" escape hatch); `detail` is the breadcrumb tooltip, the third
    /// value defaults the Save As sheet if the user saves it from there.
    let openQuery: (QuerySpec, String, String?) -> Void

    struct Options: Codable, Equatable {
        var fieldID: String
        var target: QueryTarget
        var sort: MissingDataSort
        var rowLimit: Int

        init(fieldID: String, target: QueryTarget, sort: MissingDataSort, rowLimit: Int) {
            self.fieldID = fieldID
            self.target = target
            self.sort = sort
            self.rowLimit = rowLimit
        }

        private enum CodingKeys: String, CodingKey { case fieldID, target, sort, rowLimit }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            fieldID = try values.decode(String.self, forKey: .fieldID)
            target = try values.decode(QueryTarget.self, forKey: .target)
            sort = try values.decodeIfPresent(MissingDataSort.self, forKey: .sort) ?? .plays
            rowLimit = try values.decodeIfPresent(Int.self, forKey: .rowLimit) ?? 50
        }
    }
    private static let toolId = "missingData"
    private static let defaultOptions = Options(fieldID: "duration", target: .track, sort: .plays, rowLimit: 50)
    private static let rowLimitChoices = [10, 25, 50, 100, 250, 500, 0]

    @Environment(\.modelContext) private var modelContext
    @State private var options = MissingDataView.defaultOptions
    @State private var scrobbles: [ScrobbleSnapshot]?
    @State private var data: MissingDataResult?
    @State private var isLoading = true
    @State private var isResolving = false
    @State private var isImportingDurations = false
    @State private var didStartResolving = false
    @State private var errorMessage: String?
    /// A transient notice from the last "Resolve Now" attempt (e.g. missing Last.fm credentials) — shown
    /// inline near the button, never the big empty-state error (the row list is usually non-empty when
    /// this fires, so that view wouldn't even be visible).
    @State private var resolveNotice: String?
    @State private var durationImportNotice: String?
    /// Reused across recomputes — rebuilding an album-group index from scratch costs about a second for
    /// the whole library, so this must persist as long as the view does, not get reconstructed per query.
    @State private var turnoverGroupCache = TurnoverGroupCache()

    /// Bundles a sheet's whole parameter set into one atomic, `Identifiable` value so `.sheet(item:)`
    /// presents it as a pure function of that value — never several loosely-related `@State` vars plus a
    /// separate boolean flag, which raced on first presentation (the sheet's content closure could be
    /// evaluated before every var had committed, rendering blank until closed and reopened).
    private struct ReleaseDateEditContext: Identifiable {
        let id = UUID()
        let target: ReleaseDateEditView.Target
        let detected: String?
        let override: String?
    }
    private struct DurationEditContext: Identifiable {
        let id = UUID()
        let artist: String
        let track: String
        let album: String?
        let detectedSeconds: Int?
        let overrideSeconds: Int?
    }
    private struct BPMEditContext: Identifiable {
        let id = UUID()
        let artist: String
        let track: String
        let detected: BPMEngine.Resolved?
        let override: Double?
    }
    private struct AlbumMatchFixContext: Identifiable {
        let id = UUID()
        let group: AlbumGroup
        let client: LastfmAPIClient?
    }
    @State private var releaseDateEditContext: ReleaseDateEditContext?
    @State private var durationEditContext: DurationEditContext?
    @State private var bpmEditContext: BPMEditContext?
    @State private var albumMatchFixContext: AlbumMatchFixContext?

    private var field: MissingDataField { MissingDataField.all.first { $0.id == options.fieldID } ?? MissingDataField.all[0] }
    /// The sorted, row-limited subset actually on screen — the export and the list must always agree on
    /// what "shown" means, so both read this instead of `data.rows` (the full, unsliced bucketed set).
    private var visibleRows: [MissingDataRow] {
        guard let data else { return [] }
        let sorted = MissingDataEngine.sorted(data.rows, by: options.sort)
        return options.rowLimit == 0 ? sorted : Array(sorted.prefix(options.rowLimit))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageSettingsHeader("Missing Data") { controls }
                if let data {
                    headlineCallout(data)
                }
                actionRow(data)
                if !visibleRows.isEmpty {
                    list(visibleRows)
                } else if isLoading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 240)
                } else if let errorMessage {
                    ContentUnavailableView("Couldn't load", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    ContentUnavailableView(
                        "Nothing’s missing", systemImage: "checkmark.circle",
                        description: Text("Every \(options.target.pluralLabel.lowercased()) already has \(field.label.lowercased()).")
                    )
                    .frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .padding(16)
        }
        .navigationTitle("Missing Data")
        .task {
            options = ToolFilterSettingsStore.load(Options.self, toolId: Self.toolId, context: modelContext, default: Self.defaultOptions)
            await recompute()
        }
        .onChange(of: options.fieldID) { _, newFieldID in
            let newField = MissingDataField.all.first { $0.id == newFieldID } ?? MissingDataField.all[0]
            if !newField.targets.contains(options.target) { options.target = newField.targets[0] }
            didStartResolving = false
            resolveNotice = nil
            durationImportNotice = nil
            ToolFilterSettingsStore.save(options, toolId: Self.toolId, context: modelContext)
            Task { await recompute() }
        }
        .onChange(of: options.target) { _, _ in
            resolveNotice = nil
            durationImportNotice = nil
            ToolFilterSettingsStore.save(options, toolId: Self.toolId, context: modelContext)
            Task { await recompute() }
        }
        .onChange(of: options.sort) { _, _ in
            ToolFilterSettingsStore.save(options, toolId: Self.toolId, context: modelContext)
        }
        .onChange(of: options.rowLimit) { _, _ in
            ToolFilterSettingsStore.save(options, toolId: Self.toolId, context: modelContext)
        }
        .onReceive(NotificationCenter.default.publisher(for: .scrobbleSyncDidComplete)) { _ in
            scrobbles = nil
            Task { await recompute() }
        }
        .onReceive(NotificationCenter.default.publisher(for: DurationEngine.progressNotification)) { _ in
            guard field.resolverKind == .duration else { return }
            Task { await recompute() }
        }
        .onReceive(NotificationCenter.default.publisher(for: BPMEngine.progressNotification)) { _ in
            guard field.resolverKind == .bpm else { return }
            Task { await recompute() }
        }
        .onReceive(NotificationCenter.default.publisher(for: ReleaseDateEngine.progressNotification)) { _ in
            guard field.resolverKind == .releaseDate else { return }
            Task { await recompute() }
        }
        .sheet(item: $releaseDateEditContext) { context in
            ReleaseDateEditView(
                target: context.target, detectedDate: context.detected, currentOverride: context.override,
                modelContext: modelContext, onSaved: { Task { await recompute() } }
            )
        }
        .sheet(item: $bpmEditContext) { context in
            TrackBPMEditView(
                artist: context.artist, track: context.track, detected: context.detected, currentOverride: context.override,
                modelContext: modelContext, onSaved: { Task { await recompute() } }
            )
        }
        .sheet(item: $durationEditContext) { context in
            TrackDurationEditView(
                artist: context.artist, track: context.track, album: context.album,
                detectedSeconds: context.detectedSeconds, currentOverrideSeconds: context.overrideSeconds,
                modelContext: modelContext, onSaved: { Task { await recompute() } }
            )
        }
        .sheet(item: $albumMatchFixContext) { context in
            AlbumMatchFixView(
                group: context.group, modelContext: modelContext, client: context.client,
                onResolved: { Task { await recompute() } }
            )
        }
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { pickers }
            VStack(alignment: .leading, spacing: 10) { pickers }
        }
    }

    @ViewBuilder
    private var pickers: some View {
        Picker("Field", selection: $options.fieldID) {
            ForEach(MissingDataField.all) { Text($0.label).tag($0.id) }
        }
        .pickerStyle(.segmented).labelsHidden()
        Picker("Type", selection: $options.target) {
            ForEach(field.targets, id: \.self) { Text($0.pluralLabel).tag($0) }
        }
        .fixedSize()
        Picker("Sort", selection: $options.sort) {
            ForEach(MissingDataSort.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden()
        .help("Which to prioritize fixing first.")
        Picker("Limit", selection: $options.rowLimit) {
            ForEach(Self.rowLimitChoices, id: \.self) { limit in
                Text(limit == 0 ? "No Limit" : limit.formatted()).tag(limit)
            }
        }
        .fixedSize()
        if isLoading {
            ProgressView().controlSize(.small)
        }
    }

    private func headlineCallout(_ data: MissingDataResult) -> some View {
        let percent = data.universeCount == 0 ? 0 : Int((Double(data.missingCount + data.pendingCount) / Double(data.universeCount) * 100).rounded())
        return ToolHeadlineCard("Coverage") {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(data.missingCount + data.pendingCount) of \(data.universeCount) \(options.target.pluralLabel.lowercased()) (\(percent)%) missing \(data.field.label.lowercased())")
                if data.field.resolverKind != nil {
                    Text("\(data.missingCount.formatted()) confirmed missing, \(data.pendingCount.formatted()) not yet checked")
                        .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func list(_ rows: [MissingDataRow]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(rows) { row in
                Row(
                    row: row, onOpen: { open(row) }, onGoToDetail: { goToDetail(row) },
                    onFixAlbumMatch: row.target == .album ? { openAlbumMatchFix(for: row) } : nil
                )
            }
        }
        .padding(.horizontal, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator.opacity(0.4), lineWidth: 1) }
    }

    private func actionRow(_ data: MissingDataResult?) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                if let durationImportNotice {
                    Text(durationImportNotice).font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                }
                if let resolveNotice {
                    Text(resolveNotice).font(AppTypography.compactMetadata).foregroundStyle(.orange)
                } else if didStartResolving, let data, data.field.resolverKind != nil, data.pendingCount > 0 {
                    Text("Still resolving in the background — this list will keep shrinking as results come in.")
                        .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !visibleRows.isEmpty, options.target == .track {
                AppleMusicPlaylistExportButton(
                    defaultPlaylistName: "Missing \(field.label)",
                    tracks: { playlistTracks(for: visibleRows) }
                )
            }
            if let data, data.field.resolverKind != nil, !data.rows.isEmpty {
                if data.field.id == "duration", data.target == .track {
                    Button {
                        Task { await importDurationsFromAppleMusic(data) }
                    } label: {
                        if isImportingDurations {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Reading Music Library…")
                            }
                        } else {
                            Label("Import from Apple Music", systemImage: "music.note")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isImportingDurations || isResolving)
                    .help("Checks every track missing a duration against your local Music.app library. Confident matches are imported; unavailable or ambiguous tracks are skipped. The import safely continues if you navigate away.")
                }
                Button(resolveButtonLabel(data)) {
                    Task { await resolveNow(data) }
                }
                .buttonStyle(.bordered)
                .disabled(isResolving || isImportingDurations || data.pendingCount == 0 || Connectivity.shared.isOffline)
                .help(data.pendingCount == 0
                    ? "Every item here has already been checked and confirmed to have no \(data.field.label.lowercased()) — resolving again won’t change that. Use the row’s own edit option to set a value by hand."
                    : "Starts a fresh lookup for the \(data.pendingCount.formatted()) item(s) that haven’t been checked yet. Confirmed-missing items are untouched — they need a manual override instead.")
            }
            Button("Advanced") {
                let spec = MissingDataEngine.advancedSpec(field: field, target: options.target)
                openQuery(spec, "Missing Data · \(field.label), \(options.target.pluralLabel)", "Missing \(field.label) (from Tool)")
            }
            .buttonStyle(.bordered)
            .help("Open the equivalent condition in Query. Note: this hands off strictly “confirmed missing” — a still-unchecked value shown in this list isn’t expressible as a single condition, so Advanced’s count may be smaller than this list’s.")
        }
    }

    private func resolveButtonLabel(_ data: MissingDataResult) -> String {
        if isResolving { return "Resolving…" }
        return data.pendingCount == 0 ? "Nothing to Resolve" : "Resolve Now (\(data.pendingCount.formatted()))"
    }

    private func playlistTracks(for rows: [MissingDataRow]) -> [AppleMusicPlaylistTrack] {
        rows.map { AppleMusicPlaylistTrack(artist: $0.artist, track: $0.name, album: $0.album ?? "") }
    }

    private func recompute() async {
        isLoading = true
        errorMessage = nil
        do {
            let all: [ScrobbleSnapshot]
            if let scrobbles { all = scrobbles } else {
                let container = modelContainer
                let fetched = try await offMain { try await ScrobbleSnapshotReader(modelContainer: container).fetchSortedSnapshots() }
                all = QueryIdentity.canonicalizingArtists(fetched)
                scrobbles = all
            }
            let loaded = await QuerySnapshotReader(modelContainer: modelContainer).loadAll()
            let snapshots = QuerySnapshots(
                durations: loaded.durations, bpm: loaded.bpm, releaseDates: loaded.releaseDates, turnover: loaded.turnover, images: loaded.images,
                turnoverGroups: turnoverGroupCache
            )
            let currentField = field
            let target = options.target
            let computed = await Task.detached(priority: .utility) {
                MissingDataEngine.compute(field: currentField, target: target, scrobbles: all, snapshots: snapshots)
            }.value
            data = computed
        } catch {
            errorMessage = "\(error)"
        }
        isLoading = false
    }

    private func resolveNow(_ data: MissingDataResult) async {
        isResolving = true
        didStartResolving = true
        resolveNotice = nil
        resolveNotice = await MissingDataEngine.resolveNow(
            field: field, rows: data.rows, scrobbles: scrobbles ?? [], turnoverGroups: turnoverGroupCache, context: modelContext
        )
        isResolving = false
        await recompute()
    }

    private func importDurationsFromAppleMusic(_ data: MissingDataResult) async {
        guard !isImportingDurations, data.field.id == "duration", data.target == .track else { return }
        isImportingDurations = true
        durationImportNotice = "Reading durations from Music.app. Changes are saved after the library scan completes."
        defer { isImportingDurations = false }

        let requests = data.rows.map { row in
            AppleMusicMatcher.DurationRequest(
                key: DurationEngine.cacheKey(artist: row.artist, track: row.name),
                artist: row.artist,
                track: row.name,
                album: row.album
            )
        }

        do {
            let result = try await AppleMusicMatcher.findTrackDurations(requests)
            let currentDurations = DurationEngine.loadSnapshot(context: modelContext)
            let trackRows = try modelContext.fetch(FetchDescriptor<Track>())
            let tracksByKey = Dictionary(uniqueKeysWithValues: trackRows.map { ($0.identityKey, $0) })
            var importedCount = 0
            var changedWhileImportingCount = 0

            for (key, seconds) in result.matches {
                if case .seconds = currentDurations.resolution(forKey: key) {
                    changedWhileImportingCount += 1
                    continue
                }
                guard let track = tracksByKey[key], track.durationOverrideSeconds == nil else {
                    changedWhileImportingCount += 1
                    continue
                }
                track.durationOverrideSeconds = seconds
                importedCount += 1
            }
            if importedCount > 0 { try modelContext.save() }

            var parts = [
                "Scanned \(result.libraryTrackCount.formatted()) Music.app tracks and imported \(importedCount.formatted()) duration\(importedCount == 1 ? "" : "s")."
            ]
            if result.unmatchedCount > 0 { parts.append("\(result.unmatchedCount.formatted()) not found.") }
            if result.ambiguousCount > 0 { parts.append("\(result.ambiguousCount.formatted()) ambiguous and skipped.") }
            if changedWhileImportingCount > 0 { parts.append("\(changedWhileImportingCount.formatted()) already resolved and left unchanged.") }
            durationImportNotice = parts.joined(separator: " ")
            await recompute()
        } catch {
            durationImportNotice = error.localizedDescription
        }
    }

    /// The context menu's "Open" — the row's own click goes to the field's override editor instead.
    private func goToDetail(_ row: MissingDataRow) {
        switch row.target {
        case .artist: navigation.goToArtist(ArtistIdentity(name: row.artist))
        case .album: navigation.goToAlbum(AlbumIdentity(artist: row.artist, name: row.name))
        case .track: navigation.goToTrack(TrackIdentity(artist: row.artist, name: row.name, album: row.album, imageURL: row.imageURL))
        }
    }

    private func open(_ row: MissingDataRow) {
        switch field.id {
        case "images": chooseCustomImage(for: row)
        case "releaseDate": openReleaseDateEdit(for: row)
        case "duration": openDurationEdit(for: row)
        case "bpm": openBPMEdit(for: row)
        case "albumMatch": openAlbumMatchFix(for: row)
        default: break
        }
    }

    /// The row's own bucketing already dropped any album whose group couldn't be found (see
    /// `MissingDataField`'s `albumMatch` entry), so by construction this should always find one — but
    /// stay silent rather than crash if scrobbles changed underneath it since the list was built.
    private func openAlbumMatchFix(for row: MissingDataRow) {
        let byArtist = turnoverGroupCache.groups(for: scrobbles ?? [])
        guard let groups = byArtist[row.artist], let group = AlbumTurnoverEngine.findAlbumGroup(groups, album: row.name) else { return }
        let client = LastfmCredentialsStore.load().map { LastfmAPIClient(apiKey: $0.apiKey, username: $0.username) }
        albumMatchFixContext = AlbumMatchFixContext(group: group, client: client)
    }

    /// Duplicates `EntityContextMenu.chooseCustomImage()`'s own inline panel + write — no separate
    /// reusable component exists for this; the write itself goes through the same canonical `ImageStore`.
    private func chooseCustomImage(for row: MissingDataRow) {
        let target: ImageTarget
        switch row.target {
        case .artist: target = ImageTarget(kind: .artist, artist: row.artist, album: nil, track: nil)
        case .album: target = ImageTarget(kind: .album, artist: row.artist, album: row.name, track: nil)
        case .track: target = ImageTarget(kind: .track, artist: row.artist, album: row.album, track: row.name)
        }
        let panel = NSOpenPanel()
        panel.title = "Choose Image"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ImageStore.shared.setCustomImage(data: Data(contentsOf: url), for: target, context: modelContext)
            Task { await recompute() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Fetches fresh detected/override values right before presenting — a background resolution could
    /// have landed since this row was bucketed, same guard `AlbumDetailView`/`TrackDetailView` apply.
    private func openReleaseDateEdit(for row: MissingDataRow) {
        switch row.target {
        case .album:
            let current = ReleaseDateEngine.albumRow(context: modelContext, artist: row.artist, album: row.name)
            let override = current?.releaseDateOverride
            releaseDateEditContext = ReleaseDateEditContext(
                target: .album(artist: row.artist, album: row.name),
                detected: override == nil ? current?.releaseDateDetected : nil, override: override
            )
        case .track:
            let key = TextNormalization.lovedKey(artist: row.artist, track: row.name)
            var descriptor = FetchDescriptor<Track>(predicate: #Predicate<Track> { $0.identityKey == key })
            descriptor.fetchLimit = 1
            let trackRow = try? modelContext.fetch(descriptor).first
            let override = trackRow?.releaseDateOverride
            let matchingScrobbles = (scrobbles ?? []).filter { $0.artistName == row.artist && $0.trackName == row.name }
            let primary = ReleaseDateEngine.primaryAlbum(scrobbles: matchingScrobbles)
            let detected = override == nil
                ? ReleaseDateEngine.cachedTrackDate(context: modelContext, artist: row.artist, track: row.name, primaryAlbum: primary) : nil
            releaseDateEditContext = ReleaseDateEditContext(target: .track(artist: row.artist, track: row.name), detected: detected, override: override)
        case .artist:
            return
        }
    }

    private func openBPMEdit(for row: MissingDataRow) {
        let key = BPMEngine.cacheKey(artist: row.artist, track: row.name)
        var descriptor = FetchDescriptor<Track>(predicate: #Predicate<Track> { $0.identityKey == key })
        descriptor.fetchLimit = 1
        let override = (try? modelContext.fetch(descriptor).first)?.bpmOverride
        var detected: BPMEngine.Resolved?
        if override == nil, case .value(let resolved) = BPMEngine.loadSnapshot(context: modelContext).resolution(forKey: key) { detected = resolved }
        bpmEditContext = BPMEditContext(artist: row.artist, track: row.name, detected: detected, override: override)
    }

    private func openDurationEdit(for row: MissingDataRow) {
        let key = TextNormalization.lovedKey(artist: row.artist, track: row.name)
        var descriptor = FetchDescriptor<Track>(predicate: #Predicate<Track> { $0.identityKey == key })
        descriptor.fetchLimit = 1
        let trackRow = try? modelContext.fetch(descriptor).first
        let override = trackRow?.durationOverrideSeconds
        var detected: Int?
        if override == nil {
            let snapshot = DurationEngine.loadSnapshot(context: modelContext)
            if case .seconds(let seconds) = snapshot.resolution(forKey: key) { detected = seconds }
        }
        durationEditContext = DurationEditContext(
            artist: row.artist, track: row.name, album: row.album, detectedSeconds: detected, overrideSeconds: override
        )
    }
}

private struct Row: View {
    let row: MissingDataRow
    let onOpen: () -> Void
    let onGoToDetail: () -> Void
    let onFixAlbumMatch: (() -> Void)?

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                EntityThumbnail(url: row.imageURL, entity: thumbnailEntity(for: row.target))
                    .frame(width: AppArtworkSizing.thumbnail, height: AppArtworkSizing.thumbnail)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(row.name).font(AppTypography.contentTitle).lineLimit(1)
                        if row.target == .track {
                            TrackFlaggedIndicator(
                                artist: row.artist,
                                track: row.name,
                                font: AppTypography.metadata
                            )
                        }
                    }
                    if row.target != .artist {
                        Text(row.artist).font(AppTypography.metadata).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(row.plays.formatted()) plays").font(AppTypography.metadata.monospacedDigit())
                    if let lastPlayed = row.lastPlayed {
                        Text("last played \(lastPlayed.formatted(.relative(presentation: .named)))")
                            .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                    }
                }
                if row.bucket == .pending {
                    Text("Not yet checked")
                        .font(AppTypography.denseBadge).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
            }
            .padding(.vertical, 10).padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .drillDownHighlight()
        .entityContextMenu(target: imageTarget, currentImageURL: row.imageURL, onFixAlbumMatch: onFixAlbumMatch, onOpen: onGoToDetail)
        Divider()
    }

    private var imageTarget: ImageTarget {
        switch row.target {
        case .artist: ImageTarget(kind: .artist, artist: row.artist, album: nil, track: nil)
        case .album: ImageTarget(kind: .album, artist: row.artist, album: row.name, track: nil)
        case .track: ImageTarget(kind: .track, artist: row.artist, album: row.album, track: row.name)
        }
    }

    private func thumbnailEntity(for target: QueryTarget) -> TopChartsEntity {
        switch target {
        case .artist: .artist
        case .album: .album
        case .track: .track
        }
    }
}
