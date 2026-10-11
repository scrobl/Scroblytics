import SwiftUI
import SwiftData

/// "Loved Status Audit": where a track's loved status disagrees between Last.fm and Apple Music. It never writes to
/// Last.fm. It writes to Music in exactly one place: "Remove from Favorites…" on a favorite that isn't a library track,
/// only after a confirmation (see `AppleMusicFavoritesWriter`).
///
/// Reading Music.app takes about half a second (see `AppleMusicFavoritesReader`), but it is still an Apple Events
/// round trip that can raise the Automation permission prompt, so opening the tool never starts it unless that is
/// already a known-good, expected thing: it auto-runs only if Music is ALREADY open and the audit has been run
/// before (permission is then already granted). Otherwise the user starts it with "Run audit". Music is never
/// launched by the audit.
struct LovedStatusAuditView: View {
    let modelContainer: ModelContainer
    let navigation: DetailNavigationCoordinator

    enum Filter: String, Codable, CaseIterable, Identifiable {
        case all, lastfmOnly, appleOnly, uncertain, lovedNoScrobbles, notInLibrary
        var id: Self { self }
        var label: String {
            switch self {
            case .all: "All"
            case .lastfmOnly: "Only on Last.fm"
            case .appleOnly: "Only on Apple Music"
            case .uncertain: "Uncertain"
            case .lovedNoScrobbles: "Loved, no scrobbles"
            case .notInLibrary: "Not in library"
            }
        }
    }

    struct Options: Codable, Equatable {
        var showAgreement = false
        var filter = Filter.all
        /// Set after a successful run — the signal that Automation permission has been granted, so a later visit
        /// may read Music without asking.
        var hasRun = false
        var lastRun: Date?

        init() {}

        private enum CodingKeys: String, CodingKey { case showAgreement, filter, hasRun, lastRun }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            showAgreement = try values.decodeIfPresent(Bool.self, forKey: .showAgreement) ?? false
            filter = try values.decodeIfPresent(Filter.self, forKey: .filter) ?? .all
            hasRun = try values.decodeIfPresent(Bool.self, forKey: .hasRun) ?? false
            lastRun = try values.decodeIfPresent(Date.self, forKey: .lastRun)
        }
    }

    private static let toolId = "lovedStatusAudit"

    @Environment(\.modelContext) private var modelContext
    @Environment(LovedTracksStore.self) private var lovedTracksStore
    @State private var options = Options()
    @State private var didLoadOptions = false
    /// What the last run found. Never mutated by love/unlove — `audit` layers those changes on top.
    @State private var result: LovedAudit?
    /// The loved set as the run saw it, so a later love/unlove (which updates `LovedTracksStore`) can be told
    /// apart from what the run already knew.
    @State private var baselineLovedKeys: Set<String> = []
    @State private var readSummary: String?
    @State private var isRunning = false
    @State private var errorMessage: String?
    /// Distinct (artist, track) pairs from scrobble history — "is this track in Last.fm at all". Reused across
    /// re-runs; dropped when a sync lands.
    @State private var history: [LovedStatusAuditEngine.Entry]?
    /// What the last run read, kept so a decision can recompute the audit in memory without reading Music again.
    @State private var inputs: AuditInputs?
    @State private var showingDecisions = false
    /// How many decisions the last run dropped because the tracks they were about no longer exist.
    @State private var prunedDecisionCount = 0
    /// Rows the person has asked to remove from Apple Music's Favorites, waiting for the confirmation dialog.
    @State private var removalRequest: [LovedAuditRow] = []
    @State private var isRemoving = false
    /// What the "busy" sheet says while a removal and the re-read that follows are under way.
    @State private var removalPhase = ""
    @State private var removalMessage: String?
    /// A problem with a removal, shown in an alert so it can't be missed (Music closed, an entry that changed or couldn't be changed).
    @State private var removalAlert: String?
    @Query(sort: \LovedAuditDecision.decidedAt, order: .reverse) private var decisions: [LovedAuditDecision]

    struct AuditInputs {
        let loved: [LovedStatusAuditEngine.Entry]
        let history: [LovedStatusAuditEngine.Entry]
        let apple: AppleMusicSnapshot
    }

    private var engineDecisions: [LovedStatusAuditEngine.Decision] {
        decisions.map { .init(lastfm: .init(artist: $0.lastfmArtist, track: $0.lastfmTrack), apple: .init(artist: $0.appleArtist, track: $0.appleTrack), sameTrack: $0.sameTrack) }
    }
    /// Changes whenever a decision is added, removed, flipped or restored from a backup.
    private var decisionSignature: [String] { decisions.map { "\($0.pairKey)|\($0.sameTrack)" } }

    /// `result` with any love/unlove done from this list since the run applied to the Last.fm side, so the row
    /// updates — or leaves the list — straight away, with no re-read of Music. Only keys that CHANGED since the
    /// run are touched; a row whose own spelling was never in the loved set isn't mistaken for an unlove.
    private var audit: LovedAudit? {
        guard let result else { return nil }
        let changed = lovedTracksStore.keys.symmetricDifference(baselineLovedKeys)
        guard lovedTracksStore.hasLoaded, !changed.isEmpty else { return result }
        var rows: [LovedAuditRow] = []
        rows.reserveCapacity(result.rows.count)
        for row in result.rows {
            let key = TextNormalization.lovedKey(artist: row.artist, track: row.track)
            guard changed.contains(key) else { rows.append(row); continue }
            let lastfm: LovedAuditState = lovedTracksStore.keys.contains(key) ? .loved : (row.lastfm == .notPresent ? .notPresent : .notLoved)
            let updated = LovedAuditRow(
                id: row.id, artist: row.artist, track: row.track, album: row.album,
                lastfm: lastfm, appleMusic: row.appleMusic, uncertainty: row.uncertainty, lastfmHasScrobbles: row.lastfmHasScrobbles,
                appleNotInLibrary: row.appleNotInLibrary
            )
            // Loved on neither side any more: not in the audit's population.
            if updated.lastfm != .loved, updated.appleMusic != .loved, updated.uncertainty == nil { continue }
            rows.append(updated)
        }
        return LovedAudit(rows: rows, lastfmLovedCount: result.lastfmLovedCount, appleFavoritesCount: result.appleFavoritesCount)
    }

    private var visibleRows: [LovedAuditRow] {
        guard let audit else { return [] }
        let base = options.showAgreement ? audit.rows : audit.discrepancies
        switch options.filter {
        case .all: return base
        case .lastfmOnly: return base.filter { $0.uncertainty == nil && $0.lastfm == .loved && $0.appleMusic != .loved }
        case .appleOnly: return base.filter { $0.uncertainty == nil && $0.appleMusic == .loved && $0.lastfm != .loved }
        case .uncertain: return base.filter { $0.uncertainty != nil }
        // Every love whose name no scrobble uses, whether or not Apple Music agrees: these are the stale ones.
        case .lovedNoScrobbles: return audit.rows.filter(\.isLovedWithoutScrobbles)
        // Apple favorites that are not library tracks, whatever Last.fm says about them.
        case .notInLibrary: return audit.rows.filter { $0.appleNotInLibrary != nil }
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                PageSettingsHeader("Loved Status Audit") { controls }
                if let audit {
                    headline(audit)
                    actionRow(audit)
                    list(audit)
                } else {
                    startCard
                }
            }
            .padding(16)
        }
        .navigationTitle("Loved Status Audit")
        .task {
            guard !didLoadOptions else { return }
            options = ToolFilterSettingsStore.load(Options.self, toolId: Self.toolId, context: modelContext, default: Options())
            didLoadOptions = true
            // Auto-run only when it can't surprise the user: Music already open, and run before.
            if options.hasRun, AppleMusicFavoritesReader.isMusicRunning { await runAudit() }
        }
        .onChange(of: options) { _, new in
            guard didLoadOptions else { return }
            ToolFilterSettingsStore.save(new, toolId: Self.toolId, context: modelContext)
        }
        .onChange(of: decisionSignature) { Task { await recompute() } }
        .alert("Remove from Favorites", isPresented: Binding(get: { removalAlert != nil }, set: { if !$0 { removalAlert = nil } })) {
            Button("OK", role: .cancel) { removalAlert = nil }
        } message: {
            Text(removalAlert ?? "")
        }
        // While a removal and the re-read after it run, a sheet with a spinner holds the window: nothing else can be used
        // until the audit shows the result.
        .sheet(isPresented: Binding(get: { isRemoving }, set: { _ in })) {
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text(removalPhase).font(.headline).multilineTextAlignment(.center)
                Text("Please wait. This takes a few seconds.").font(.callout).foregroundStyle(.secondary)
            }
            .padding(32)
            .frame(minWidth: 340)
            .interactiveDismissDisabled()
        }
        .confirmationDialog(
            removalRequest.count == 1 ? "Remove this favorite from Apple Music?" : "Remove \(removalRequest.count) favorites from Apple Music?",
            isPresented: Binding(get: { !removalRequest.isEmpty }, set: { if !$0 { removalRequest = [] } }),
            titleVisibility: .visible
        ) {
            Button("Remove from Favorites", role: .destructive) {
                let rows = removalRequest
                removalRequest = []
                Task { await removeFromFavorites(rows) }
            }
            Button("Cancel", role: .cancel) { removalRequest = [] }
        } message: {
            Text(removalMessageText)
        }
        .onReceive(NotificationCenter.default.publisher(for: .scrobbleSyncDidComplete)) { _ in
            history = nil
            // A sync may have changed the loved set; refresh only under the same no-surprise policy.
            guard audit != nil, AppleMusicFavoritesReader.isMusicRunning else { return }
            Task { await runAudit() }
        }
    }

    // MARK: Controls

    /// Three layouts, each used only when it fits at its natural size, so nothing is ever squeezed or overlaps:
    /// everything on one row; the filter segments on a row of their own with the other controls beneath; and, in a narrow
    /// window, the filter as a menu.
    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                wideFilterPicker
                agreementToggle
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
                compactFilterPicker
                    .frame(maxWidth: .infinity, alignment: .leading)
                otherControls
            }
        }
    }

    private var otherControls: some View {
        HStack(spacing: 12) {
            agreementToggle
            Spacer(minLength: 0)
            runningIndicator
            decisionsButton
            auditButton
        }
    }

    /// The segmented filter at its natural width: if that doesn't fit, `ViewThatFits` moves on to the next layout.
    private var wideFilterPicker: some View {
        Picker("Show", selection: $options.filter) {
            ForEach(Filter.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .disabled(audit == nil)
    }

    private var compactFilterPicker: some View {
        Picker("Show", selection: $options.filter) {
            ForEach(Filter.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.menu)
        .disabled(audit == nil)
    }

    private var agreementToggle: some View {
        Toggle("Show agreement", isOn: $options.showAgreement)
            .toggleStyle(.checkbox)
            .fixedSize()
            .disabled(audit == nil)
            .help("Also list tracks that are loved on both services.")
    }

    @ViewBuilder
    private var runningIndicator: some View {
        if isRunning {
            ProgressView()
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private var decisionsButton: some View {
        if !decisions.isEmpty {
            Button {
                showingDecisions = true
            } label: {
                Label("Decisions (\(decisions.count))", systemImage: "checklist")
            }
            .help("The “same track” and “different tracks” decisions you’ve made. Remove one to be asked again.")
            .popover(isPresented: $showingDecisions, arrowEdge: .bottom) { decisionsList }
        }
    }

    private var decisionsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your decisions").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(decisions) { decision in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: decision.sameTrack ? "link" : "xmark.circle")
                                .foregroundStyle(decision.sameTrack ? .green : .secondary)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(decision.sameTrack ? "Same track" : "Different tracks").font(AppTypography.contentTitle)
                                Text("Last.fm: \(decision.lastfmTrack) · \(decision.lastfmArtist)").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                                Text("Apple Music: \(decision.appleTrack) · \(decision.appleArtist)").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Button("Remove") { modelContext.delete(decision); try? modelContext.save() }
                        }
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .padding(14)
        .frame(width: 460)
    }

    private var auditButton: some View {
        Button {
            Task { await runAudit() }
        } label: {
            Label(audit == nil ? "Run audit" : "Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(isRunning)
        .help("Reads your Music library (about a second) and compares it with your synced Last.fm loves.")
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
                Button("Try again") { Task { await runAudit() } }
            }
            .frame(maxWidth: .infinity, minHeight: 240)
        } else {
            ContentUnavailableView {
                Label("Compare your loved tracks", systemImage: "heart.text.square")
            } description: {
                Text("Finds tracks you’ve loved on Last.fm but not favorited in Apple Music, and the other way round. It reads your Music library once, which takes about a second, and changes nothing unless you choose to remove a favorite that isn’t in your library (it asks first). The first run asks for permission to control Music.")
            } actions: {
                Button("Run audit") { Task { await runAudit() } }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, minHeight: 240)
        }
    }

    // MARK: Headline and actions

    private func headline(_ audit: LovedAudit) -> some View {
        ToolHeadlineCard("LAST.FM vs APPLE MUSIC") {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(audit.agreeCount.formatted()) loved on both")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) {
                        auditCounts(audit)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        auditCounts(audit)
                    }
                }
                .font(AppTypography.contentTitle)
                if let readSummary {
                    Text(readSummary)
                        .font(AppTypography.compactMetadata).fontWeight(.regular).foregroundStyle(.secondary)
                }
                if let removalMessage {
                    Text(removalMessage)
                        .font(AppTypography.compactMetadata).fontWeight(.regular).foregroundStyle(.secondary)
                }
                if prunedDecisionCount > 0 {
                    Text("\(prunedDecisionCount) \(prunedDecisionCount == 1 ? "decision was" : "decisions were") removed: the tracks \(prunedDecisionCount == 1 ? "it was" : "they were") about no longer exist (you fixed the spelling).")
                        .font(AppTypography.compactMetadata).fontWeight(.regular).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func auditCounts(_ audit: LovedAudit) -> some View {
        Label("\(audit.lastfmOnlyCount.formatted()) only on Last.fm", systemImage: "heart.fill")
            .foregroundStyle(.red)
        Label("\(audit.appleOnlyCount.formatted()) only on Apple Music", systemImage: "star.fill")
            .foregroundStyle(.pink)
        Label("\(audit.uncertainCount.formatted()) uncertain", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
        if audit.notInLibraryCount > 0 {
            Label("\(audit.notInLibraryCount.formatted()) not in library", systemImage: "externaldrive.badge.questionmark")
                .foregroundStyle(.secondary)
                .help("Favorites in Apple Music that aren’t tracks in your library: songs you favorited from the catalogue, or leftover entries for tracks you have since renamed or replaced.")
        }
        Label("\(audit.lovedWithoutScrobblesCount.formatted()) loved, no scrobbles", systemImage: "questionmark.circle")
            .foregroundStyle(.secondary)
            .help("Loved on Last.fm under a name no scrobble uses: usually a track that was renamed or whose plays were deleted after you loved it.")
    }

    private func actionRow(_ audit: LovedAudit) -> some View {
        let missingFromApple = playlistTracks(for: audit)
        return ViewThatFits(in: .horizontal) {
            HStack {
                resultCount
                Spacer()
                removeAllButton
                playlistExport(missingFromApple)
            }
            VStack(alignment: .leading, spacing: 8) {
                resultCount
                removeAllButton
                playlistExport(missingFromApple)
            }
        }
    }

    /// Under the "Not in library" filter: unfavorite every listed entry in Apple Music, after a confirmation.
    @ViewBuilder
    private var removeAllButton: some View {
        let rows = visibleRows
        if options.filter == .notInLibrary, !rows.isEmpty {
            Button {
                requestRemoval(rows)
            } label: {
                Label("Remove all \(rows.count.formatted()) from Favorites…", systemImage: "star.slash")
            }
            .disabled(isRemoving || isRunning)
            .help("Unfavorites these entries in Apple Music after you confirm. Nothing in your library changes.")
        }
    }

    private var resultCount: some View {
        Text("\(visibleRows.count.formatted()) \(visibleRows.count == 1 ? "track" : "tracks")")
            .font(AppTypography.metadata.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func playlistExport(_ tracks: [AppleMusicPlaylistTrack]) -> some View {
        if !tracks.isEmpty {
            AppleMusicPlaylistExportButton(
                defaultPlaylistName: "Loved on Last.fm, not on Apple Music",
                tracks: { tracks }
            )
            .help("Confirmed tracks only — uncertain matches are left out.")
        }
    }

    /// Loved on Last.fm, not favorited in Apple Music, and not merely a spelling the audit is unsure of.
    private func playlistTracks(for audit: LovedAudit) -> [AppleMusicPlaylistTrack] {
        audit.rows
            .filter { $0.uncertainty == nil && $0.lastfm == .loved && $0.appleMusic != .loved }
            .map { AppleMusicPlaylistTrack(artist: $0.artist, track: $0.track, album: $0.album ?? "") }
    }

    // MARK: List

    @ViewBuilder
    private func list(_ audit: LovedAudit) -> some View {
        let rows = visibleRows
        if rows.isEmpty {
            ContentUnavailableView(
                options.showAgreement || options.filter != .all ? "Nothing here" : "Everything agrees",
                systemImage: "checkmark.circle",
                description: Text(options.showAgreement || options.filter != .all
                    ? "No tracks match this view."
                    : "Every track loved on one service is loved on the other.")
            )
            .frame(maxWidth: .infinity, minHeight: 200)
        } else {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(rows) { row in
                    AuditRow(
                        row: row, onDecide: { same in decide(row, sameTrack: same) },
                        onRemoveFromFavorites: row.appleNotInLibrary == nil || isRemoving ? nil : { requestRemoval([row]) }
                    ) {
                        navigation.goToTrack(TrackIdentity(artist: row.artist, name: row.track, album: row.album, imageURL: nil))
                    }
                }
            }
            .padding(.horizontal, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator.opacity(0.4), lineWidth: 1) }
        }
    }

    // MARK: Removing favorites that aren't in the library

    /// Opens the confirmation, unless Music is closed: removing needs Music open (the app never starts it), so say so up front.
    private func requestRemoval(_ rows: [LovedAuditRow]) {
        guard AppleMusicFavoritesReader.isMusicRunning else {
            removalAlert = "Music isn’t open. Open Music, then try again. Scroblytics never opens it for you."
            return
        }
        removalRequest = rows
    }

    private var removalMessageText: String {
        let lines = removalRequest.prefix(10).compactMap { row -> String? in
            guard let ghost = row.appleNotInLibrary else { return nil }
            let kind = ghost.origin == .catalogue ? "Apple Music catalogue favorite" : "leftover entry"
            return "• \(ghost.name) — \(ghost.artist) (\(kind))"
        }
        var text = lines.joined(separator: "\n")
        if removalRequest.count > 10 { text += "\n…and \(removalRequest.count - 10) more" }
        text += "\n\nThis changes Apple Music: it un-favorites these entries in your Favorite Songs. Nothing in your library is touched. Leftover entries can’t be favorited again (Music doesn’t show them); a catalogue favorite can be favorited again from the song in Music."
        return text
    }

    /// Unfavorites the confirmed rows' entries in Music, then reads Music again. Each entry is found by its ID and left alone
    /// if its name or artist no longer matches.
    private func removeFromFavorites(_ rows: [LovedAuditRow]) async {
        let targets = rows.compactMap { row in
            row.appleNotInLibrary.map { AppleMusicFavoritesWriter.Target(id: $0.databaseID, name: $0.name, artist: $0.artist) }
        }
        guard !targets.isEmpty else { return }
        isRemoving = true
        var pendingAlert: String?
        removalPhase = "Removing \(targets.count) \(targets.count == 1 ? "favorite" : "favorites") from Apple Music…"
        let results = await AppleMusicFavoritesWriter.unfavorite(targets)
        removalPhase = "Reading Music again to update the audit…"
        let removed = results.filter { $0.outcome == .removed }.count
        let problems = results.filter { !$0.outcome.succeeded }
        var message = "Removed \(removed) of \(targets.count) from your Apple Music Favorites."
        if let first = problems.first {
            switch first.outcome {
            case .musicNotRunning: message = "Music isn’t open, so nothing was removed. Open Music and try again."
            case .notFound: message += " \(problems.count) couldn’t be found any more."
            case .mismatch: message += " \(problems.count) changed since the list was read and were left alone."
            default: message += " \(problems.count) couldn’t be changed."
            }
        }
        removalMessage = message
        if !problems.isEmpty {
            let lines = problems.prefix(10).map { result -> String in
                let reason: String
                switch result.outcome {
                case .musicNotRunning: reason = "Music isn’t open"
                case .notFound: reason = "no longer in your Favorite Songs"
                case .mismatch(let now): reason = "it is called “\(now)” now, so it was left alone"
                case .failed(let text): reason = "Music said: \(text)"
                case .removed, .wouldRemove: reason = "done"
                }
                return "• \(result.target.name) — \(reason)"
            }
            pendingAlert = "\(message)\n\n" + lines.joined(separator: "\n")
        }
        await runAudit()
        // The alert waits until the busy sheet has closed, so it isn't swallowed by it.
        isRemoving = false
        try? await Task.sleep(for: .milliseconds(400))
        removalAlert = pendingAlert
    }

    // MARK: Decisions

    /// Records "same track" or "different tracks" for an Uncertain row. The audit then recomputes from what the last run
    /// read, with no new Music read, as the stored decisions change.
    private func decide(_ row: LovedAuditRow, sameTrack: Bool) {
        guard let pair = row.decisionPair else { return }
        let key = LovedStatusAuditEngine.pairKey(lastfm: pair.lastfm, apple: pair.apple)
        if let existing = decisions.first(where: { $0.pairKey == key }) {
            existing.sameTrack = sameTrack
            existing.decidedAt = .now
        } else {
            modelContext.insert(LovedAuditDecision(
                pairKey: key, lastfmArtist: pair.lastfm.artist, lastfmTrack: pair.lastfm.track,
                appleArtist: pair.apple.artist, appleTrack: pair.apple.track, sameTrack: sameTrack, decidedAt: .now
            ))
        }
        try? modelContext.save()
    }

    /// After a complete run, drops decisions whose tracks no longer exist on one side. Only once the first import has
    /// finished (before that, scrobbles are still arriving and a name could simply not be here yet).
    private func pruneObsoleteDecisions(_ kept: AuditInputs) async {
        prunedDecisionCount = 0
        guard !decisions.isEmpty else { return }
        var descriptor = FetchDescriptor<SyncState>()
        descriptor.fetchLimit = 1
        guard let state = try? modelContext.fetch(descriptor).first, state.lastSyncedAt != nil, state.backfillNextPage == nil else { return }
        let current = engineDecisions
        let obsolete = await Task.detached(priority: .userInitiated) {
            LovedStatusAuditEngine.obsoleteDecisions(current, lovedOnLastfm: kept.loved, history: kept.history, apple: kept.apple)
        }.value
        guard !obsolete.isEmpty else { return }
        let keys = Set(obsolete.map { LovedStatusAuditEngine.pairKey(lastfm: $0.lastfm, apple: $0.apple) })
        var removed = 0
        for decision in decisions where keys.contains(decision.pairKey) {
            modelContext.delete(decision)
            removed += 1
        }
        try? modelContext.save()
        prunedDecisionCount = removed
    }

    /// Re-joins the last run's inputs with the current decisions.
    private func recompute() async {
        guard let kept = inputs else { return }
        let applied = engineDecisions
        let computed = await Task.detached(priority: .userInitiated) {
            LovedStatusAuditEngine.audit(lovedOnLastfm: kept.loved, history: kept.history, apple: kept.apple, decisions: applied)
        }.value
        result = computed
    }

    // MARK: Run

    private func runAudit() async {
        guard !isRunning else { return }
        isRunning = true
        errorMessage = nil
        defer { isRunning = false }
        do {
            // Music first: if it isn't open this fails immediately, before any other work.
            let apple = try await AppleMusicFavoritesReader.read()

            let loved = try modelContext.fetch(FetchDescriptor<LovedTrackEntry>())
                .map { LovedStatusAuditEngine.Entry(artist: $0.artist, track: $0.track) }
            let historyEntries: [LovedStatusAuditEngine.Entry]
            if let history { historyEntries = history } else {
                let container = modelContainer
                let snapshots = try await offMain { try await ScrobbleSnapshotReader(modelContainer: container).fetchSortedSnapshots() }
                var seen = Set<String>()
                var distinct: [LovedStatusAuditEngine.Entry] = []
                for s in snapshots where seen.insert("\(s.artistName)\u{0}\(s.trackName)").inserted {
                    distinct.append(.init(artist: s.artistName, track: s.trackName))
                }
                history = distinct
                historyEntries = distinct
            }

            let kept = AuditInputs(loved: loved, history: historyEntries, apple: apple)
            let applied = engineDecisions
            let computed = await Task.detached(priority: .userInitiated) {
                LovedStatusAuditEngine.audit(lovedOnLastfm: kept.loved, history: kept.history, apple: kept.apple, decisions: applied)
            }.value

            inputs = kept
            result = computed
            await pruneObsoleteDecisions(kept)
            baselineLovedKeys = lovedTracksStore.keys
            var summary = "Read \(apple.library.count.formatted()) library tracks and \(apple.favorites.count.formatted()) favorites from Music in \(apple.readSeconds.formatted(.number.precision(.fractionLength(1)))) s"
            if apple.source == .favoritedFlag { summary += " (via each track’s favorite flag — your Favorites playlist wasn’t found)" }
            readSummary = summary
            options.hasRun = true
            options.lastRun = .now
        } catch {
            // Keep any earlier result on screen; surface the failure only when there's nothing to show.
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Row

struct AuditRow: View {
    let row: LovedAuditRow
    let onDecide: (Bool) -> Void
    let onRemoveFromFavorites: (() -> Void)?
    let onOpen: () -> Void

    /// A track Last.fm has never seen has no listening history to open.
    private var canOpen: Bool { row.lastfm != .notPresent }

    var body: some View {
        // Wide: the row and its buttons side by side. Narrower: the buttons drop beneath the row (and stack if they still
        // don't fit), so nothing is ever clipped or squeezed.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 8) {
                openArea
                actionButtons
            }
            VStack(alignment: .leading, spacing: 4) {
                openArea
                actionButtons
                    .padding(.horizontal, 4)
                    .padding(.bottom, 6)
            }
        }
        .entityContextMenu(
            target: ImageTarget(kind: .track, artist: row.artist, album: row.album, track: row.track),
            onOpen: canOpen ? onOpen : nil
        )
        Divider()
    }

    private var openArea: some View {
        Group {
            if canOpen {
                Button(action: onOpen) { content }
                    .drillDownHighlight()
            } else {
                content
            }
        }
    }

    /// The row's buttons, one line if it fits, otherwise stacked.
    @ViewBuilder
    private var actionButtons: some View {
        if row.decisionPair != nil || onRemoveFromFavorites != nil {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { buttonViews }
                VStack(alignment: .leading, spacing: 6) { buttonViews }
            }
        }
    }

    @ViewBuilder
    private var buttonViews: some View {
        if let pair = row.decisionPair { decisionButtons(pair) }
        if let onRemoveFromFavorites {
            Button(action: onRemoveFromFavorites) { Label("Remove from Favorites…", systemImage: "star.slash") }
                .controlSize(.small)
                .fixedSize()
                .help("Unfavorite this entry in Apple Music, after you confirm. Nothing in your library changes.")
        }
    }

    /// Same track / different tracks, for an Uncertain row. Kept outside the row's own open button.
    private func decisionButtons(_ pair: (lastfm: LovedStatusAuditEngine.Entry, apple: LovedStatusAuditEngine.Entry)) -> some View {
        HStack(spacing: 6) {
            Button { onDecide(true) } label: { Label("Same track", systemImage: "link") }
                .help("These are the same track: “\(pair.lastfm.track)” on Last.fm and “\(pair.apple.track)” in Apple Music. Count them as one.")
            Button { onDecide(false) } label: { Label("Different tracks", systemImage: "xmark.circle") }
                .help("These are different tracks. Stop suggesting “\(pair.lastfm.track)” and “\(pair.apple.track)” as a match.")
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.small)
        .fixedSize()
    }

    private var content: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                identity
                Spacer(minLength: 8)
                states
            }
            .frame(minWidth: 520)

            VStack(alignment: .leading, spacing: 10) {
                identity
                states
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .opacity(row.agrees ? 0.6 : 1)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.track)
                .font(AppTypography.contentTitle)
                .lineLimit(1)
            Text(row.artist)
                .font(AppTypography.metadata)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let ghost = row.appleNotInLibrary {
                Label(ghost.origin == .catalogue ? "Favorite isn’t in your library · Apple Music catalogue" : "Favorite isn’t in your library · leftover entry",
                      systemImage: "externaldrive.badge.questionmark")
                    .font(AppTypography.supportingDense)
                    .foregroundStyle(.secondary)
                    .help(ghost.origin == .catalogue
                        ? "You favorited this song from Apple Music’s catalogue but never added it to your library."
                        : "Music still lists this as a favorite, but the track is no longer in your library (it was probably renamed or replaced). Music usually doesn’t show these.")
            }
            if row.isLovedWithoutScrobbles {
                Text("No scrobbles under this name")
                    .font(AppTypography.compactMetadata)
                    .foregroundStyle(.secondary)
                    .help("You’ve loved this on Last.fm, but no scrobble uses this exact artist and title. It was probably renamed, or its plays were deleted, after you loved it.")
            }
            if let uncertainty = row.uncertainty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        uncertaintyBadge
                        uncertaintyDetail(uncertainty.detail)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        uncertaintyBadge
                        uncertaintyDetail(uncertainty.detail)
                    }
                }
                .help(uncertainty.detail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var uncertaintyBadge: some View {
        Label("Uncertain match", systemImage: "exclamationmark.triangle.fill")
            .font(AppTypography.supportingDense)
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.orange.opacity(0.15), in: Capsule())
            .fixedSize()
    }

    private func uncertaintyDetail(_ detail: String) -> some View {
        Text(detail)
            .font(AppTypography.compactMetadata)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }

    private var states: some View {
        HStack(spacing: 8) {
            StateCell(service: .lastfm, state: row.lastfm, quiet: row.agrees)
            StateCell(service: .appleMusic, state: row.appleMusic, quiet: row.agrees)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// One service's state for a row. Last.fm keeps its heart; Apple Music gets a star so the two are never confused,
/// and each of the three states differs in glyph AND words, not just color.
private struct StateCell: View {
    enum Service { case lastfm, appleMusic }
    let service: Service
    let state: LovedAuditState
    let quiet: Bool

    private var symbol: String {
        switch (service, state) {
        case (.lastfm, .loved): "heart.fill"
        case (.lastfm, .notLoved): "heart"
        case (.appleMusic, .loved): "star.fill"
        case (.appleMusic, .notLoved): "star"
        case (_, .notPresent): "minus.circle"
        }
    }

    private var tint: Color {
        switch state {
        case .loved: quiet ? .secondary : (service == .lastfm ? .red : .pink)
        case .notLoved, .notPresent: .secondary
        }
    }

    private var label: String {
        switch (service, state) {
        case (_, .loved): service == .lastfm ? "Loved" : "Favorite"
        case (_, .notLoved): service == .lastfm ? "Not loved" : "Not a favorite"
        case (.lastfm, .notPresent): "No scrobbles"
        case (.appleMusic, .notPresent): "Not in library"
        }
    }

    private var serviceName: String { service == .lastfm ? "Last.fm" : "Apple Music" }

    var body: some View {
        VStack(alignment: .center, spacing: 2) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(label).font(AppTypography.compactMetadata).foregroundStyle(.secondary)
        }
        .frame(minWidth: 80, maxWidth: 96)
        .help("\(serviceName): \(label)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(serviceName): \(label)")
    }
}
