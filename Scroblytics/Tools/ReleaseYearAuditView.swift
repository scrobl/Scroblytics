import SwiftData
import SwiftUI

/// "Release Year Audit": albums whose release year in Scroblytics differs from the year Apple Music holds for them. Each row shows both
/// years and where the Scroblytics date came from, and lets you use Music's year, keep Scroblytics', or edit the date. It only ever changes
/// Scroblytics' own album dates (the same override the date editor sets); it never writes to Music or Last.fm.
///
/// Reading Music takes about a second but is an Apple Events round trip that can raise the Automation permission prompt, so, like the
/// Loved Status Audit, opening the tool starts it only when Music is already open and it has been run before. Music is never launched.
struct ReleaseYearAuditView: View {
    let modelContainer: ModelContainer
    let navigation: DetailNavigationCoordinator

    typealias Filter = ReleaseYearAudit.Filter

    struct Options: Codable, Equatable {
        var filter = Filter.all
        var sort = ReleaseYearAudit.SortKey.difference
        /// nil: the sort's own starting direction.
        var ascending: Bool?
        /// Set after a successful run: Automation permission has been granted, so a later visit may read Music without asking.
        var hasRun = false
        var lastRun: Date?

        init() {}

        private enum CodingKeys: String, CodingKey { case filter, sort, ascending, hasRun, lastRun }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            filter = try values.decodeIfPresent(Filter.self, forKey: .filter) ?? .all
            sort = (try? values.decodeIfPresent(ReleaseYearAudit.SortKey.self, forKey: .sort)) ?? .difference
            ascending = try values.decodeIfPresent(Bool.self, forKey: .ascending)
            hasRun = try values.decodeIfPresent(Bool.self, forKey: .hasRun) ?? false
            lastRun = try values.decodeIfPresent(Date.self, forKey: .lastRun)
        }
    }

    /// A change waiting for the person's confirmation.
    enum BulkRequest: Identifiable {
        case useApple([ReleaseYearAudit.AlbumRow])
        case useAppleTracks([ReleaseYearAudit.AlbumRow])
        case keepMine([ReleaseYearAudit.AlbumRow])

        var id: String {
            switch self {
            case .useApple(let rows): "use-\(rows.count)"
            case .useAppleTracks(let rows): "tracks-\(rows.count)"
            case .keepMine(let rows): "keep-\(rows.count)"
            }
        }
    }

    /// A change to Music's years that is waiting for the person's yes.
    struct MusicOffer: Identifiable {
        let id = UUID()
        let updates: [ReleaseYearAudit.MusicYearUpdate]
        let albums: Int
        /// For an album whose tracks have several years in Music: what that is, so the prompt can say it will set them all to one.
        var variedNote: String?
    }

    private static let toolId = "releaseYearAudit"

    @Environment(\.modelContext) private var modelContext
    @State private var options = Options()
    @State private var didLoadOptions = false
    @State private var report: ReleaseYearAudit.Report?
    /// What the last run read from Music, kept so a decision can recompute in memory without reading Music again.
    @State private var music: [AppleMusicTrackYear]?
    @State private var isRunning = false
    @State private var errorMessage: String?
    @State private var readSummary: String?
    @State private var resultMessage: String?
    @State private var showingDecisions = false
    @State private var bulk: BulkRequest?
    @State private var editing: ReleaseYearAudit.AlbumRow?
    /// Scroblytics' years brought to Music, once the person says yes.
    @State private var musicOffer: MusicOffer?
    @State private var isWritingMusic = false
    /// How far a change to Music has got, and the task doing it (so it can be stopped).
    @State private var musicProgress: (done: Int, total: Int)?
    @State private var musicTask: Task<Void, Never>?
    /// The list's width, which decides between the columns (with a header) and the stacked rows.
    @State private var listWidth: CGFloat = 1100
    @Query(sort: \ReleaseYearDecision.decidedAt, order: .reverse) private var decisions: [ReleaseYearDecision]

    private var decisionMap: [String: ReleaseYearAudit.Decision] {
        Dictionary(decisions.compactMap { d -> (String, ReleaseYearAudit.Decision)? in
            guard let verdict = ReleaseYearAudit.Decision.Verdict(rawValue: d.verdict) else { return nil }
            return (d.albumKey, .init(albumKey: d.albumKey, verdict: verdict, scroblyticsYear: d.scroblyticsYear, musicYear: d.musicYear, tracksSignature: d.tracksSignature ?? ""))
        }, uniquingKeysWith: { first, _ in first })
    }

    /// Changes whenever a decision is added, removed or restored from a backup.
    private var decisionSignature: [String] { decisions.map { "\($0.albumKey)|\($0.verdict)|\($0.scroblyticsYear)|\($0.musicYear)|\($0.tracksSignature ?? "")|\($0.trackChangesJSON?.count ?? 0)" } }

    private var visibleRows: [ReleaseYearAudit.AlbumRow] {
        guard let report else { return [] }
        return ReleaseYearAudit.sorted(ReleaseYearAudit.listed(report.rows, filter: options.filter, decisions: decisionMap), by: options.sort, ascending: options.ascending)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                PageSettingsHeader("Release Year Audit") { controls }
                if let report {
                    headline(report)
                    actionRow
                    list
                } else {
                    startCard
                }
            }
            .padding(16)
        }
        .navigationTitle("Release Year Audit")
        .task {
            guard !didLoadOptions else { return }
            options = ToolFilterSettingsStore.load(Options.self, toolId: Self.toolId, context: modelContext, default: Options())
            didLoadOptions = true
            if options.hasRun, AppleMusicFavoritesReader.isMusicRunning { await run() }
        }
        .onChange(of: options) { _, new in
            guard didLoadOptions else { return }
            ToolFilterSettingsStore.save(new, toolId: Self.toolId, context: modelContext)
        }
        .onChange(of: decisionSignature) { Task { await recompute() } }
        .sheet(item: $editing) { row in
            ReleaseDateEditView(
                target: .album(artist: row.scroblytics.artist, album: row.scroblytics.title),
                detectedDate: row.scroblytics.detected, currentOverride: row.scroblytics.override,
                modelContext: modelContext, onSaved: { Task { await recompute(); offerMusicUpdate(forAlbum: row.albumKey) } }
            )
        }
        // While Music is being changed, nothing else can be used.
        .sheet(isPresented: Binding(get: { isWritingMusic }, set: { _ in })) {
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text("Updating Apple Music…").font(.headline)
                if let progress = musicProgress {
                    Text("\(progress.done.formatted()) of \(progress.total.formatted()) tracks").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                Button("Stop") { musicTask?.cancel() }
                    .help("Stops after the track being changed. What was already changed stays changed.")
            }
            .padding(32)
            .frame(minWidth: 340)
            .interactiveDismissDisabled()
        }
        .confirmationDialog(
            "Update Apple Music too?", isPresented: Binding(get: { musicOffer != nil }, set: { if !$0 { musicOffer = nil } }), titleVisibility: .visible
        ) {
            Button("Update Apple Music") {
                if let offer = musicOffer { musicOffer = nil; musicTask = Task { await writeToMusic(offer) } }
            }
            Button("Not now", role: .cancel) { musicOffer = nil }
        } message: {
            Text(musicOfferMessage)
        }
        .confirmationDialog(
            bulkTitle, isPresented: Binding(get: { bulk != nil }, set: { if !$0 { bulk = nil } }), titleVisibility: .visible
        ) {
            switch bulk {
            case .useApple(let rows)?:
                Button("Use Apple Music’s year") { bulk = nil; apply(.useApple(rows)) }
            case .useAppleTracks(let rows)?:
                Button("Use Apple Music’s years for the tracks") { bulk = nil; apply(.useAppleTracks(rows)) }
            case .keepMine(let rows)?:
                Button("Keep Scroblytics") { bulk = nil; apply(.keepMine(rows)) }
            case nil:
                EmptyView()
            }
            Button("Cancel", role: .cancel) { bulk = nil }
        } message: {
            Text(bulkMessage)
        }
    }

    // MARK: Controls

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                wideFilterPicker
                Spacer(minLength: 0)
                runningIndicator
                decisionsButton
                auditButton
            }
            VStack(alignment: .leading, spacing: 10) {
                wideFilterPicker
                otherControls
            }
            VStack(alignment: .leading, spacing: 10) {
                compactFilterPicker.frame(maxWidth: .infinity, alignment: .leading)
                otherControls
            }
        }
    }

    private var otherControls: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            runningIndicator
            decisionsButton
            auditButton
        }
    }

    private static func label(_ filter: Filter) -> String {
        switch filter {
        case .all: "All"
        case .close: "1–2 years"
        case .far: "3+ years"
        case .yourDates: "Your own dates"
        case .musicVaries: "Compilations"
        }
    }

    private var wideFilterPicker: some View {
        Picker("Show", selection: $options.filter) {
            ForEach(Filter.allCases, id: \.self) { Text(Self.label($0)).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .disabled(report == nil)
    }

    private var compactFilterPicker: some View {
        Picker("Show", selection: $options.filter) {
            ForEach(Filter.allCases, id: \.self) { Text(Self.label($0)).tag($0) }
        }
        .pickerStyle(.menu)
        .disabled(report == nil)
    }

    @ViewBuilder
    private var runningIndicator: some View {
        if isRunning { ProgressView().controlSize(.small) }
    }

    @ViewBuilder
    private var decisionsButton: some View {
        if !decisions.isEmpty {
            Button { showingDecisions = true } label: { Label("Decisions (\(decisions.count))", systemImage: "checklist") }
                .help("The albums you’ve settled. Remove one to be asked again; for one you used Apple Music’s year on, it also puts the earlier date back.")
                .popover(isPresented: $showingDecisions, arrowEdge: .bottom) { decisionsList }
        }
    }

    private var auditButton: some View {
        Button { Task { await run() } } label: { Label(report == nil ? "Run audit" : "Refresh", systemImage: "arrow.clockwise") }
            .disabled(isRunning)
            .help("Reads the years in your Music library (about a second) and compares them with your Scroblytics release dates.")
    }

    private var decisionsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your decisions").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(decisions) { decision in
                        let used = decision.verdict == ReleaseYearAudit.Decision.Verdict.usedApple.rawValue
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: used ? "arrow.down.circle" : "hand.raised")
                                .foregroundStyle(used ? .blue : .secondary).frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(decision.album).font(AppTypography.contentTitle).lineLimit(1)
                                Text(decision.artist).font(AppTypography.compactMetadata).foregroundStyle(.secondary).lineLimit(1)
                                Text(ReleaseYearAuditActions.summary(of: decision))
                                    .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                                if !used, isStale(decision) {
                                    Text("The years have changed since, so it is being asked about again.")
                                        .font(AppTypography.compactMetadata).foregroundStyle(.orange)
                                }
                            }
                            Spacer(minLength: 8)
                            // An album you kept can still be brought to Music later: it is offered again whenever Music's years differ.
                            if !used, let row = report?.rows.first(where: { $0.albumKey == decision.albumKey }),
                               !ReleaseYearAudit.musicUpdates(for: row, albumYear: nil, includeVaried: true).isEmpty {
                                Button("Update Apple Music…") { showingDecisions = false; offerMusicUpdate(for: [row]) }
                                    .help("Offers to set the years of this album’s tracks in Music to the year Scroblytics shows. Nothing changes until you confirm.")
                            }
                            Button(used ? "Undo" : "Remove") { undo(decision) }
                        }
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .padding(14)
        .frame(width: 480)
    }

    /// A "keep Scroblytics" that no longer applies because either year changed.
    private func isStale(_ decision: ReleaseYearDecision) -> Bool {
        guard let row = report?.rows.first(where: { $0.albumKey == decision.albumKey }) else { return false }
        return !ReleaseYearAudit.isDecided(row, decisions: decisionMap) && (row.category == .offByOne || row.category == .differs)
    }

    // MARK: Start / empty states

    @ViewBuilder
    private var startCard: some View {
        if isRunning {
            ProgressView("Reading Music…").frame(maxWidth: .infinity, minHeight: 240)
        } else if let errorMessage {
            ContentUnavailableView {
                Label("Couldn’t run the audit", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try again") { Task { await run() } }
            }
            .frame(maxWidth: .infinity, minHeight: 240)
        } else {
            ContentUnavailableView {
                Label("Compare release years with Apple Music", systemImage: "calendar.badge.exclamationmark")
            } description: {
                Text("Lists albums whose release year here differs from the year in your Music library, with where each Scroblytics date came from. It reads your Music library once, which takes about a second, and changes nothing until you choose: only Scroblytics’ own album dates ever change, never Music. The first run asks for permission to control Music.")
            } actions: {
                Button("Run audit") { Task { await run() } }.buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, minHeight: 240)
        }
    }

    // MARK: Headline and actions

    private func headline(_ report: ReleaseYearAudit.Report) -> some View {
        ToolHeadlineCard("SCROBLYTICS vs APPLE MUSIC") {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(report.count(.same).formatted()) of \(report.matched.formatted()) albums agree")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) { counts(report) }
                    VStack(alignment: .leading, spacing: 6) { counts(report) }
                }
                .font(AppTypography.contentTitle)
                let origins = originSummary(report)
                if !origins.isEmpty {
                    Text("Where the differing dates came from: \(origins)")
                        .font(AppTypography.compactMetadata).fontWeight(.regular).foregroundStyle(.secondary)
                }
                if let readSummary {
                    Text(readSummary).font(AppTypography.compactMetadata).fontWeight(.regular).foregroundStyle(.secondary)
                }
                if let resultMessage {
                    Text(resultMessage).font(AppTypography.compactMetadata).fontWeight(.regular).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func counts(_ report: ReleaseYearAudit.Report) -> some View {
        Label("\(report.count(band: .close).formatted()) 1–2 years apart", systemImage: "plusminus.circle.fill").foregroundStyle(.orange)
        Label("\(report.count(band: .far).formatted()) 3+ years apart", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        Label("\(report.rows.filter { $0.musicVaries && !$0.trackDifferences.isEmpty }.count.formatted()) compilations", systemImage: "square.stack.3d.up").foregroundStyle(.secondary)
            .help("Albums whose tracks have several different years in Music (a greatest-hits set, a rarities collection) and some of whose tracks show a different year here.")
    }

    /// "Detected (source not recorded) 133 · Manual 40 …" for the albums that differ.
    private func originSummary(_ report: ReleaseYearAudit.Report) -> String {
        var counts: [String: Int] = [:]
        for row in report.rows where row.category == .offByOne || row.category == .differs { counts[row.scroblytics.origin.label, default: 0] += 1 }
        return counts.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value.formatted())" }.joined(separator: " · ")
    }

    private var actionRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                resultCount
                sortControls
                Spacer()
                bulkButtons
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) { resultCount; sortControls }
                bulkButtons
            }
        }
    }

    /// What the list is ordered by, and which way.
    private var sortControls: some View {
        HStack(spacing: 6) {
            Picker("Sort", selection: $options.sort) {
                ForEach(ReleaseYearAudit.SortKey.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help("What the list is ordered by.")
            .onChange(of: options.sort) { _, _ in options.ascending = nil }
            Button {
                options.ascending = !(options.ascending ?? options.sort.startsAscending)
            } label: {
                Image(systemName: (options.ascending ?? options.sort.startsAscending) ? "arrow.up" : "arrow.down")
            }
            .help(options.sort.directionLabel(ascending: options.ascending ?? options.sort.startsAscending) + ". Click to reverse.")
        }
        .controlSize(.small)
        .disabled(report == nil)
    }

    private var resultCount: some View {
        Text("\(visibleRows.count.formatted()) \(visibleRows.count == 1 ? "album" : "albums")")
            .font(AppTypography.metadata.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var bulkButtons: some View {
        let rows = visibleRows
        if !rows.isEmpty {
            // The same order as the columns and the row buttons: Scroblytics, then Apple Music.
            HStack(spacing: 8) {
                Button { bulk = .keepMine(rows) } label: { Label("Keep Scroblytics for all \(rows.count.formatted())…", systemImage: "hand.raised") }
                    .help("Settles every album listed, after you confirm. Each comes back if either year changes.")
                if options.filter == .musicVaries {
                    Button { bulk = .useAppleTracks(rows) } label: { Label("Use Apple Music’s years for the tracks of all \(rows.count.formatted())…", systemImage: "arrow.down.circle") }
                        .help("Sets the tracks’ own release dates to the years in Music, after you confirm. A track you gave a date of your own is never changed.")
                } else {
                    Button { bulk = .useApple(rows) } label: { Label("Use Apple Music’s year for all \(rows.count.formatted())…", systemImage: "arrow.down.circle") }
                        .help("Sets each album’s own release date to the year in Music, after you confirm. Albums whose Music tracks span several years are skipped.")
                }
            }
            .controlSize(.small)
            .disabled(isRunning)
        }
    }

    private var bulkTitle: String {
        switch bulk {
        case .useApple(let rows)?: rows.count == 1 ? "Use Apple Music’s year for this album?" : "Use Apple Music’s year for \(rows.count.formatted()) albums?"
        case .useAppleTracks(let rows)?: rows.count == 1 ? "Use Apple Music’s years for this album’s tracks?" : "Use Apple Music’s years for the tracks of \(rows.count.formatted()) albums?"
        case .keepMine(let rows)?: rows.count == 1 ? "Keep Scroblytics’ date for this album?" : "Keep Scroblytics’ date for \(rows.count.formatted()) albums?"
        case nil: ""
        }
    }

    private var bulkMessage: String {
        func lines(_ rows: [ReleaseYearAudit.AlbumRow]) -> String {
            var text = rows.prefix(10).map { "• \($0.scroblytics.artist) — \($0.scroblytics.title): \($0.scroblytics.year.map(String.init) ?? "—") → \($0.musicYear.map(String.init) ?? "—")" }.joined(separator: "\n")
            if rows.count > 10 { text += "\n…and \(rows.count - 10) more" }
            return text
        }
        switch bulk {
        case .useApple(let rows)?:
            let varies = rows.filter(\.musicVaries).count
            var text = lines(rows) + "\n\nThis sets each album’s own release date in Scroblytics to Music’s year (the most common year among its tracks). Nothing changes in Music."
            if varies > 0 { text += " \(varies.formatted()) \(varies == 1 ? "album whose" : "albums whose") Music tracks span several years \(varies == 1 ? "is" : "are") skipped." }
            return text + " You can undo any of them from Decisions."
        case .useAppleTracks(let rows)?:
            var text = rows.prefix(10).map { "• \($0.scroblytics.artist) — \($0.scroblytics.title): \($0.trackDifferences.count) \($0.trackDifferences.count == 1 ? "track" : "tracks")" }.joined(separator: "\n")
            if rows.count > 10 { text += "\n…and \(rows.count - 10) more" }
            return text + "\n\nThis sets each of those tracks’ own release date in Scroblytics to the year Music holds for it. A track you gave a date of your own, and a track you have never played, is left alone. Nothing changes in Music. You can undo any of them from Decisions."
        case .keepMine(let rows)?:
            return lines(rows) + "\n\nNothing changes in Scroblytics or Music. These albums leave the list until either year changes."
        case nil:
            return ""
        }
    }

    // MARK: List

    @ViewBuilder
    private var list: some View {
        let rows = visibleRows
        if rows.isEmpty {
            ContentUnavailableView(
                options.filter == .all ? "Everything agrees" : "Nothing here",
                systemImage: "checkmark.circle",
                description: Text(options.filter == .all
                    ? "Every album’s release year here matches the one in Music, or you’ve settled the difference."
                    : "No albums match this view.")
            )
            .frame(maxWidth: .infinity, minHeight: 200)
        } else {
            let isWide = listWidth >= ReleaseYearAuditRowView.wideMinimumWidth
            LazyVStack(alignment: .leading, spacing: 1) {
                if isWide { ReleaseYearAuditHeaderView() }
                ForEach(rows) { row in
                    ReleaseYearAuditRowView(
                        row: row, isWide: isWide,
                        onUseApple: { apply(.useApple([row])) },
                        onUseTracks: { apply(.useAppleTracks([row])) },
                        onKeepMine: { apply(.keepMine([row])) },
                        onEdit: { editing = row },
                        onOpen: { navigation.goToAlbum(AlbumIdentity(artist: row.scroblytics.artist, name: row.scroblytics.title)) }
                    )
                }
            }
            .padding(.horizontal, 10)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { listWidth = $0 }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator.opacity(0.4), lineWidth: 1) }
        }
    }

    // MARK: Running and changing

    private func run() async {
        guard !isRunning else { return }
        guard AppleMusicFavoritesReader.isMusicRunning else {
            errorMessage = AppleMusicFavoritesReader.ReadError.musicNotRunning.errorDescription
            return
        }
        isRunning = true
        errorMessage = nil
        defer { isRunning = false }
        do {
            let started = Date()
            let tracks = try await AppleMusicYearReader.read()
            music = tracks
            await recompute()
            readSummary = "Read \(tracks.count.formatted()) tracks from Music in \(Date().timeIntervalSince(started).formatted(.number.precision(.fractionLength(1)))) s."
            options.hasRun = true
            options.lastRun = Date()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Compares again with what was read from Music, after a date or a decision changed. Music is not read again.
    private func recompute() async {
        guard let music else { return }
        let loaded = await ReleaseYearAuditStoreReader(modelContainer: modelContainer).load()
        let next = await Task.detached(priority: .userInitiated) {
            ReleaseYearAudit.compare(music: music, albums: loaded.albums, trackOverrides: loaded.trackOverrides, trackOverrideIndex: loaded.trackOverrideIndex, knownTracks: loaded.known)
        }.value
        report = next
    }

    // MARK: Updating Music too

    /// After you keep Scroblytics' date (or edit it by hand), offers to make the years in Music match. Nothing happens in Music unless you say yes.
    /// One album you chose yourself is offered in full, even if its tracks have several years in Music (the prompt says so). Several at once
    /// leave alone any album whose tracks have different years there, so a batch can't flatten many compilations. Either way, if there is
    /// nothing to offer, the result line says why.
    private func offerMusicUpdate(for rows: [ReleaseYearAudit.AlbumRow]) {
        let single = rows.count == 1
        let updates = rows.flatMap { ReleaseYearAudit.musicUpdates(for: $0, albumYear: nil, includeVaried: single) }
        let skippedVaried = single ? 0 : rows.filter { $0.musicVaries && ReleaseYearAudit.musicUpdates(for: $0, albumYear: nil, includeVaried: true).count > ReleaseYearAudit.musicUpdates(for: $0, albumYear: nil).count }.count
        guard !updates.isEmpty else {
            guard !rows.isEmpty else { return }
            let note = skippedVaried > 0
                ? "Apple Music left alone for \(skippedVaried.formatted()) \(skippedVaried == 1 ? "album" : "albums") whose tracks have different years there (keep Scroblytics on one album to update it)."
                : (single ? "Apple Music already has this album’s years." : "Apple Music already has these albums’ years.")
            resultMessage = [resultMessage, note].compactMap { $0 }.joined(separator: " ")
            return
        }
        var offer = MusicOffer(updates: updates, albums: rows.filter { !ReleaseYearAudit.musicUpdates(for: $0, albumYear: nil, includeVaried: single).isEmpty }.count)
        if single, let row = rows.first, row.musicVaries, let first = row.musicEarliest, let last = row.musicLatest {
            offer.variedNote = "Music holds several different years for this album’s tracks (\(first)–\(last)). This sets all of them to \(row.scroblytics.year.map(String.init) ?? "this year")."
        }
        if skippedVaried > 0 { resultMessage = [resultMessage, "Left \(skippedVaried.formatted()) \(skippedVaried == 1 ? "album" : "albums") whose tracks have different years in Music alone."].compactMap { $0 }.joined(separator: " ") }
        musicOffer = offer
    }

    private func offerMusicUpdate(forAlbum key: String) {
        guard let row = report?.rows.first(where: { $0.albumKey == key }) else { return }
        resultMessage = nil
        offerMusicUpdate(for: [row])
    }

    private var musicOfferMessage: String {
        guard let offer = musicOffer else { return "" }
        var lines = offer.updates.prefix(8).map { "• \($0.name) — \($0.album): \($0.from.map(String.init) ?? "no year") → \($0.to)" }
        if offer.updates.count > 8 { lines.append("…and \(offer.updates.count - 8) more") }
        let tracks = offer.updates.count
        let time = AppleMusicYearWriter.estimate(tracks: tracks).map { " This takes \($0); you can stop it." } ?? ""
        let varied = offer.variedNote.map { "\n\n" + $0 } ?? ""
        return lines.joined(separator: "\n") + varied + "\n\nThis changes the Year of \(tracks.formatted()) \(tracks == 1 ? "track" : "tracks") on \(offer.albums.formatted()) \(offer.albums == 1 ? "album" : "albums") in your Apple Music library to match Scroblytics. It changes nothing else in Music. A track whose name or year in Music has changed since it was read is left alone, and Music may refuse a streaming track it can’t edit. Music has no undo for this: the list above is what was there.\(time)"
    }

    private func writeToMusic(_ offer: MusicOffer) async {
        isWritingMusic = true
        musicProgress = (0, offer.updates.count)
        let results = await AppleMusicYearWriter.apply(offer.updates, progress: { done, total in
            Task { @MainActor in musicProgress = (done, total) }
        })
        isWritingMusic = false
        musicProgress = nil
        musicTask = nil
        resultMessage = AppleMusicYearWriter.summary(results)
        // Read Music again so the list shows what it holds now.
        await run()
    }

    private func apply(_ request: BulkRequest) {
        do {
            switch request {
            case .useApple(let rows):
                let result = try ReleaseYearAuditActions.useAppleYear(rows, skipVaries: rows.count > 1, tracksOfVaried: rows.count == 1, context: modelContext)
                let tracks = result.tracksSet > 0 ? " and \(result.tracksSet.formatted()) \(result.tracksSet == 1 ? "track" : "tracks") to their own years in Music" : ""
                resultMessage = Self.message("Set \(result.applied.formatted()) \(result.applied == 1 ? "album" : "albums") to Apple Music’s year" + tracks, result)
            case .useAppleTracks(let rows):
                let result = try ReleaseYearAuditActions.useAppleYearsForTracks(rows, context: modelContext)
                var text = "Set \(result.tracksSet.formatted()) \(result.tracksSet == 1 ? "track’s year" : "tracks’ years") on \(result.albums.formatted()) \(result.albums == 1 ? "album" : "albums")"
                if result.skippedOwnDate > 0 { text += "; left \(result.skippedOwnDate.formatted()) with a date of your own" }
                if result.skippedShared > 0 { text += "; \(result.skippedShared.formatted()) are on more than one of these albums and were set once" }
                if result.skippedNoTrack > 0 { text += "; \(result.skippedNoTrack.formatted()) have no track here (never played)" }
                resultMessage = text + "."
            case .keepMine(let rows):
                let result = try ReleaseYearAuditActions.keepMine(rows, context: modelContext)
                resultMessage = "Kept Scroblytics’ date for \(result.applied.formatted()) \(result.applied == 1 ? "album" : "albums")."
                offerMusicUpdate(for: rows)
            }
        } catch {
            resultMessage = "That didn’t work: \(error.localizedDescription)"
        }
        Task { await recompute() }
    }

    private static func message(_ lead: String, _ result: ReleaseYearAuditActions.Result) -> String {
        var text = lead
        if result.skippedVaries > 0 { text += "; skipped \(result.skippedVaries.formatted()) whose Music tracks span several years" }
        if result.skipped > 0 { text += "; \(result.skipped.formatted()) couldn’t be changed" }
        return text + "."
    }

    private func undo(_ decision: ReleaseYearDecision) {
        do { try ReleaseYearAuditActions.undo(decision, context: modelContext) } catch { resultMessage = "Couldn’t undo that: \(error.localizedDescription)" }
        Task { await recompute() }
    }
}

/// The column widths the wide rows and their header share, so the figures line up down the list.
private enum ReleaseYearAuditColumns {
    static let scroblytics: CGFloat = 265
    static let music: CGFloat = 150
    static let gap: CGFloat = 110
    static let buttons: CGFloat = 372
    static let spacing: CGFloat = 14
}

/// The labels over the wide list's columns.
struct ReleaseYearAuditHeaderView: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: ReleaseYearAuditColumns.spacing) {
            Text("Album").frame(maxWidth: .infinity, alignment: .leading)
            Text("Scroblytics").frame(width: ReleaseYearAuditColumns.scroblytics, alignment: .leading)
                .help("The album's release date here, and where it came from.")
            Text("Apple Music").frame(width: ReleaseYearAuditColumns.music, alignment: .leading)
                .help("The most common year among the album's tracks in your Music library.")
            Text("Difference").frame(width: ReleaseYearAuditColumns.gap, alignment: .leading)
            Color.clear.frame(width: ReleaseYearAuditColumns.buttons, height: 1)
        }
        .font(AppTypography.compactMetadata)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// One album that differs: both years, where the Scroblytics date came from, and what to do about it. Wide: columns under a header
/// (`ReleaseYearAuditHeaderView`). Otherwise stacked, each figure with its own label.
struct ReleaseYearAuditRowView: View {
    /// The narrowest list width at which the columns fit.
    static let wideMinimumWidth: CGFloat = 1140

    let row: ReleaseYearAudit.AlbumRow
    var isWide = true
    var onUseApple: () -> Void = {}
    var onUseTracks: () -> Void = {}
    var onKeepMine: () -> Void = {}
    var onEdit: () -> Void = {}
    var onOpen: () -> Void = {}
    /// The tracks that differ are listed under the album when this is open.
    @State private var showsTracks = false
    /// Open to begin with (the layout snapshots use this; the list never does).
    var initiallyOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            columns
            if showsTracks, showsTrackDetails { trackPanel }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onAppear { if initiallyOpen { showsTracks = true } }
    }

    /// The tracks are listed only for an album whose tracks differ among themselves in Music (a compilation). On an ordinary album every
    /// track differs only because the album's year does, which the row already says.
    private var showsTrackDetails: Bool { Self.showsTrackDetails(row) }

    static func showsTrackDetails(_ row: ReleaseYearAudit.AlbumRow) -> Bool { row.musicVaries && !row.trackDifferences.isEmpty }

    private var columns: some View {
        Group {
            if isWide {
                HStack(alignment: .center, spacing: ReleaseYearAuditColumns.spacing) {
                    identity
                    scroblyticsBlock(width: ReleaseYearAuditColumns.scroblytics, labelled: false)
                    musicBlock(width: ReleaseYearAuditColumns.music, labelled: false)
                    // A row with no gap to show still keeps the column, or its neighbours would slide along.
                    Color.clear.frame(width: ReleaseYearAuditColumns.gap, height: 1).overlay(alignment: .leading) { gapBadge }
                    buttons.frame(width: ReleaseYearAuditColumns.buttons, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    identity
                    HStack(alignment: .top, spacing: 14) {
                        scroblyticsBlock(width: 190, labelled: true)
                        musicBlock(width: 140, labelled: true)
                    }
                    gapBadge
                    buttons
                }
            }
        }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.scroblytics.title).font(AppTypography.contentTitle).lineLimit(1)
                    Text(row.scroblytics.artist).font(AppTypography.metadata).foregroundStyle(.secondary).lineLimit(1)
                    if row.musicVaries, let first = row.musicEarliest, let last = row.musicLatest {
                        Label("Its tracks span \(String(first))–\(String(last)) in Music", systemImage: "square.stack.3d.up")
                            .font(AppTypography.compactMetadata).foregroundStyle(.secondary).lineLimit(1)
                            .help("Music holds several different years for this album’s tracks, so a single year for the album is a guess. The most common one is shown.")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("Open the album")
            if showsTrackDetails {
                let count = row.trackDifferences.count
                Button { showsTracks.toggle() } label: {
                    Label("\(count.formatted()) \(count == 1 ? "track differs" : "tracks differ")", systemImage: showsTracks ? "chevron.down" : "chevron.right")
                        .font(AppTypography.compactMetadata)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help("Show the tracks whose year here differs from the year Music holds for them.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The tracks that differ: the year shown here (its own date, or the album's) beside Music's.
    private var trackPanel: some View {
        let eligible = row.trackDifferences.filter { !$0.ownDate }.count
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Text("Track").frame(maxWidth: .infinity, alignment: .leading)
                Text("Scroblytics").frame(width: 130, alignment: .trailing)
                Text("Apple Music").frame(width: 100, alignment: .trailing)
            }
            .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
            ForEach(row.trackDifferences.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, id: \.self) { difference in
                HStack(spacing: 10) {
                    Text(difference.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Text(String(difference.scroblyticsYear) + (difference.ownDate ? " · your date" : ""))
                        .foregroundStyle(difference.ownDate ? Color.purple : Color.secondary).frame(width: 130, alignment: .trailing)
                    Text(String(difference.musicYear)).monospacedDigit().frame(width: 100, alignment: .trailing)
                }
                .font(AppTypography.metadata)
            }
            HStack(spacing: 10) {
                Button(action: onUseTracks) {
                    Label(eligible == 1 ? "Use Apple Music’s year for this track" : "Use Apple Music’s years for \(eligible.formatted()) tracks", systemImage: "arrow.down.circle")
                }
                .controlSize(.small)
                .disabled(eligible == 0)
                .help("Sets these tracks’ own release dates to the years in Music. A track you gave a date of your own, or one you have never played, is left alone.")
                if eligible < row.trackDifferences.count {
                    Text("A date you set yourself is never changed.").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func scroblyticsBlock(width: CGFloat, labelled: Bool) -> some View {
        yearBlock(
            title: labelled ? "Scroblytics" : nil, year: row.scroblytics.year,
            detail: [row.scroblytics.date.map(ReleaseDateEngine.formatDate), row.scroblytics.origin.label].compactMap { $0 }.joined(separator: " · "),
            tint: row.scroblytics.origin == .manual ? Color.purple : nil, width: width
        )
    }

    private func musicBlock(width: CGFloat, labelled: Bool) -> some View {
        yearBlock(
            title: labelled ? "Apple Music" : nil, year: row.musicYear,
            detail: row.musicVaries ? "most common of \(row.trackCount) tracks" : "\(row.trackCount) \(row.trackCount == 1 ? "track" : "tracks")",
            tint: nil, width: width
        )
    }

    private func yearBlock(title: String?, year: Int?, detail: String, tint: Color?, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if let title { Text(title).font(AppTypography.compactMetadata).foregroundStyle(.secondary) }
            Text(year.map(String.init) ?? "—").font(AppTypography.contentTitle.monospacedDigit()).foregroundStyle(tint ?? Color.primary)
            Text(detail).font(AppTypography.compactMetadata).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: width, alignment: .leading)
    }

    @ViewBuilder
    private var gapBadge: some View {
        if let gap = row.gap, gap != 0 {
            let years = abs(gap)
            let big = years > 1
            Text("\(years) \(years == 1 ? "year" : "years") \(gap > 0 ? "later" : "earlier")")
                .font(AppTypography.supportingDense)
                .foregroundStyle(big ? Color.red : Color.orange)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background((big ? Color.red : Color.orange).opacity(0.15), in: Capsule())
                .fixedSize()
                .help(gap > 0 ? "Scroblytics has this album \(years) \(years == 1 ? "year" : "years") later than Music." : "Scroblytics has this album \(years) \(years == 1 ? "year" : "years") earlier than Music.")
        }
    }

    private var buttons: some View {
        // The same order as the columns: the Scroblytics side (keep it, or edit it), then Apple Music's.
        HStack(spacing: 6) {
            Button(action: onKeepMine) { Label("Keep Scroblytics", systemImage: "hand.raised") }
                .help("Settle this album as it is. It comes back only if either year changes.")
            Button(action: onEdit) { Label("Edit…", systemImage: "calendar") }
                .help("Set a different date by hand.")
            // An album whose own year already agrees (a compilation listed for its tracks) has nothing to set.
            if row.category != .same {
            Button(action: onUseApple) { Label("Use Apple Music’s", systemImage: "arrow.down.circle") }
                .disabled(row.musicYear == nil)
                .help(row.musicVaries ? "Set this album’s date to \(row.musicYear.map(String.init) ?? "—"), the most common year among its tracks in Music, and each track to its own year in Music (a track you gave a date of your own keeps it)." : "Set this album’s own release date to \(row.musicYear.map(String.init) ?? "—").")
            }
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.small)
        .fixedSize()
    }
}
