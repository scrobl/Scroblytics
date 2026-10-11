import SwiftUI
import SwiftData

private enum PastedTracklistParser {
    static func parse(_ text: String) -> [String] {
        text
            .components(separatedBy: .newlines)
            .map(parseLine)
            .filter { !$0.isEmpty }
    }

    /// Parses a pasted tracklist line. Track numbers
    /// and trailing durations are presentation metadata, not part of a title.
    private static func parseLine(_ raw: String) -> String {
        var line = raw
        if let range = line.range(
            of: #"[\s(–-]*\(?\d{1,2}:\d{2}(?::\d{2})?\)?\s*$"#,
            options: .regularExpression
        ) {
            line.removeSubrange(range)
        }
        if let range = line.range(
            of: #"^\s*(?:\(?\d{1,2}\)?[.):-]?|track\s+\d+:?)\s*[-–]?\s*"#,
            options: [.regularExpression, .caseInsensitive]
        ) {
            line.removeSubrange(range)
        }
        return line.trimmingCharacters(in: .whitespaces)
    }
}

/// "Fix album match…" — reached via right-click on the album art (always
/// available, not gated on match status), with one point that matters a lot in
/// practice: **tapping a candidate only stages it** (a highlight + checkmark)
/// and previewing its tracklist is a fully separate tap target (the chevron)
/// — neither one writes anything. Only the single footer "Save" button
/// commits the currently-staged selection. This two-step shape is
/// deliberate, not incidental: it's what lets someone expand a candidate to
/// check its tracklist without risking applying the wrong one by accident.
struct AlbumMatchFixView: View {
    let group: AlbumGroup
    let modelContext: ModelContext
    let client: LastfmAPIClient?
    let onResolved: () -> Void

    @Environment(\.dismiss) private var dismiss

    private enum LoadState<T> {
        case idle, loading, loaded(T), failed(String)
    }

    /// One Last.fm candidate, fully resolved (tracklist fetched, coverage
    /// computed) BEFORE display. `isAutoMatch` marks the
    /// group's own current identity (always present, even with no tracklist);
    /// `isBestFit` marks the single best-coverage candidate whose tracklist is
    /// at least as long as what the user has actually played.
    private struct LastfmCandidate: Identifiable {
        let id = UUID()
        let queryArtist: String
        let queryAlbum: String
        let isAutoMatch: Bool
        var canonicalArtist: String
        var canonicalAlbum: String
        var tracks: [String]
        /// nil = no catalog tracklist found at all ("Tracklist unavailable");
        /// only ever nil for the auto-match candidate — every other candidate
        /// with no tracklist is dropped entirely before display.
        var trackCount: Int?
        var matchedCount: Int
        var coverage: Double
        var isBestFit = false
    }

    /// What's currently highlighted/checked, staged for the next Save — never
    /// applied until Save is pressed. `nil` means nothing staged yet.
    private enum Selection: Equatable {
        case canonical(candidateID: UUID)
        case appleMusicEdition(index: Int)
        case manualPaste
        case observed
        case resetToAutomatic
    }

    @State private var selection: Selection?
    @State private var hasExistingResolution = false

    @State private var lastfmAlternates: LoadState<[LastfmCandidate]> = .idle
    @State private var expandedLastfmID: UUID?

    @State private var appleMusicEditions: LoadState<[AppleMusicMatcher.Edition]> = .idle
    @State private var expandedAppleMusicIndex: Int?

    @State private var manualText = ""
    @State private var manualTracks: [String] = []
    @State private var showingPasteDialog = false
    @State private var expandedManual = false
    @State private var expandedObserved = false

    @State private var errorMessage: String?
    @State private var isSaving = false

    /// Caps how many identities (auto-match + search hits) get their
    /// tracklist enriched; the rest are never fetched or shown.
    private static let candidateMax = 8
    /// The album search limit — wider than the unrelated
    /// automatic-classifier path might otherwise imply.
    private static let searchLimit = 12

    private var observedTitles: [String] { AlbumTurnoverEngine.distinctObserved(group).titles }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Text("\(group.artist) — \(group.displayName)").font(AppTypography.sectionTitle)
                    Text("Pick the edition whose tracklist best matches what you've played — a green check marks tracks you've scrobbled. Tap a row to select it, tap the chevron to preview its tracklist first — nothing is applied until you press Save.")
                        .font(AppTypography.supporting).foregroundStyle(.secondary)
                }

                Section("Last.fm alternates") {
                    lastfmSection
                }

                Section("Match from Apple Music library") {
                    appleMusicSection
                }

                Section("Paste tracklist manually") {
                    Button {
                        showingPasteDialog = true
                    } label: {
                        Label(
                            manualTracks.isEmpty ? "Paste Tracklist…" : "Edit Pasted Tracklist…",
                            systemImage: "clipboard"
                        )
                    }

                    if !manualTracks.isEmpty {
                        selectableRow(
                            icon: "music.note.list",
                            title: "Pasted tracklist",
                            subtitle: "\(manualTracks.count) track\(manualTracks.count == 1 ? "" : "s")",
                            isSelected: selection == .manualPaste,
                            isEnabled: true,
                            expanded: expandedManual,
                            onToggleExpand: { expandedManual.toggle() }
                        ) {
                            selection = .manualPaste
                        }
                        if expandedManual {
                            trackList(manualTracks.map { ($0, false) }, numbered: true)
                        }
                    }
                }

                Section {
                    selectableRow(
                        icon: "music.note.list", title: "Just use the tracks I've played",
                        subtitle: "\(observedTitles.count) track\(observedTitles.count == 1 ? "" : "s") played · ignores the full catalog tracklist",
                        isSelected: selection == .observed, isEnabled: true,
                        expanded: expandedObserved, onToggleExpand: observedTitles.isEmpty ? nil : { expandedObserved.toggle() }
                    ) { selection = .observed }
                    if expandedObserved {
                        trackList(observedTitles.map { ($0, true) })
                    }

                    if hasExistingResolution {
                        selectableRow(
                            icon: nil, title: "Reset to automatic matching", subtitle: nil,
                            isSelected: selection == .resetToAutomatic, isEnabled: true
                        ) { selection = .resetToAutomatic }
                    }
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button(isSaving ? "Saving…" : "Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil || isSaving)
            }
            .padding()
        }
        .frame(minWidth: 560, minHeight: 520, maxHeight: 680)
        .task {
            hasExistingResolution = AlbumTurnoverEngine.storedResolution(context: modelContext, group: group) != nil
            await loadLastfmAlternates()
        }
        .sheet(isPresented: $showingPasteDialog) {
            PastedTracklistDialog(initialText: manualText) { acceptedText, acceptedTracks in
                manualText = acceptedText
                manualTracks = acceptedTracks
                selection = .manualPaste
                expandedManual = true
            }
        }
    }

    // MARK: - Shared row UI

    @ViewBuilder
    private func selectableRow(
        icon: String?, title: String, subtitle: String?, isSelected: Bool, isEnabled: Bool,
        expanded: Bool = false, onToggleExpand: (() -> Void)? = nil, onSelect: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    if let icon {
                        Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                        if let subtitle {
                            Text(subtitle).font(AppTypography.supporting).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)

            Image(systemName: "checkmark").foregroundStyle(isSelected ? Color.accentColor : .clear)

            if let onToggleExpand {
                Button(action: onToggleExpand) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
    }

    /// A catalog/library
    /// tracklist is numbered in album order (`numbered: true`); the "tracks
    /// I've played" list isn't a tracklist at all, just titles, so it stays
    /// unnumbered (`number` is only ever passed for
    /// `CandidateCard`/`EditionCard`, never for the observed-tracks row).
    private func trackList(_ tracks: [(String, Bool)], numbered: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(tracks.enumerated()), id: \.offset) { index, entry in
                HStack(spacing: 6) {
                    if numbered {
                        Text("\(index + 1)")
                            .font(AppTypography.supportingDense).foregroundStyle(.tertiary)
                            .frame(width: 18, alignment: .trailing)
                    }
                    Image(systemName: entry.1 ? "checkmark.circle.fill" : "circle")
                        .font(AppTypography.supportingDense).foregroundStyle(entry.1 ? Color.green : .secondary)
                    Text(entry.0).font(AppTypography.supporting).foregroundStyle(entry.1 ? .primary : .secondary)
                }
            }
        }
        .padding(.leading, 26)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(AppTypography.denseBadge)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }

    // MARK: - Last.fm alternates

    @ViewBuilder
    private var lastfmSection: some View {
        switch lastfmAlternates {
        case .idle, .loading:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Searching Last.fm…") }
                .font(AppTypography.supporting).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).font(AppTypography.supporting).foregroundStyle(.red)
        case .loaded(let candidates):
            if candidates.isEmpty {
                Text("No alternate candidates found.").font(AppTypography.supporting).foregroundStyle(.secondary)
            } else {
                ForEach(candidates) { candidate in
                    lastfmCandidateRow(candidate)
                    if expandedLastfmID == candidate.id, candidate.trackCount != nil {
                        let observedNorm = Set(observedTitles.map(TextNormalization.normalizeTrackTitle))
                        trackList(candidate.tracks.map { ($0, observedNorm.contains(TextNormalization.normalizeTrackTitle($0))) }, numbered: true)
                    }
                }
            }
        }
    }

    private func lastfmCandidateRow(_ candidate: LastfmCandidate) -> some View {
        let isSelected = selection == .canonical(candidateID: candidate.id)
        return HStack(spacing: 8) {
            Button {
                selection = .canonical(candidateID: candidate.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "opticaldisc").foregroundStyle(.secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(candidate.queryAlbum)
                            if candidate.isAutoMatch { badge("Auto match", color: .secondary) }
                            if candidate.isBestFit { badge("Best fit", color: .green) }
                        }
                        Text(candidate.queryArtist).font(AppTypography.supporting).foregroundStyle(.secondary)
                        Text(statsLine(candidate)).font(AppTypography.supportingDense).foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Image(systemName: "checkmark").foregroundStyle(isSelected ? Color.accentColor : .clear)

            if candidate.trackCount != nil {
                Button {
                    expandedLastfmID = expandedLastfmID == candidate.id ? nil : candidate.id
                } label: {
                    Image(systemName: expandedLastfmID == candidate.id ? "chevron.down" : "chevron.right")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
    }

    private func statsLine(_ candidate: LastfmCandidate) -> String {
        guard let trackCount = candidate.trackCount else { return "Tracklist unavailable" }
        let pct = Int((candidate.coverage * 100).rounded())
        return "\(trackCount) track\(trackCount == 1 ? "" : "s") · you've played \(candidate.matchedCount) of them (\(pct)%)"
    }

    /// Gathers identities (auto-match first, then up to `searchLimit` search
    /// hits, deduped case-insensitively by artist+album), cap to
    /// `candidateMax`, fetch each candidate's tracklist SEQUENTIALLY (not in
    /// parallel — each live fetch already carries
    /// `getCachedTracklist`'s own 120ms politeness delay), drop any
    /// non-auto-match candidate with no tracklist, compute per-candidate
    /// coverage, mark the single best-fit candidate, then sort auto-match
    /// first / coverage desc / matchedCount desc.
    private func loadLastfmAlternates() async {
        if ConnectivityGate.isOffline {
            lastfmAlternates = .failed("Offline mode is on. Go online to see Last.fm candidates (Apple Music and pasted tracklists still work).")
            return
        }
        guard let client else {
            lastfmAlternates = .failed("Log in to Last.fm (Settings > Sync) to see alternate candidates.")
            return
        }
        lastfmAlternates = .loading

        let strippedAlbum = TextNormalization.stripEditionSuffix(group.displayName)
        var seenKeys = Set<String>()
        var identities: [(artist: String, album: String, isAutoMatch: Bool)] = []

        func addIdentity(_ artist: String, _ album: String, isAutoMatch: Bool) {
            let key = "\(artist.lowercased())\u{0}\(album.lowercased())"
            guard !seenKeys.contains(key) else { return }
            seenKeys.insert(key)
            identities.append((artist, album, isAutoMatch))
        }

        addIdentity(group.artist, strippedAlbum, isAutoMatch: true)
        let searchResults = await client.searchAlbums(album: strippedAlbum, limit: Self.searchLimit)
        for r in searchResults {
            addIdentity(r.artist, r.album, isAutoMatch: false)
        }

        let observed = AlbumTurnoverEngine.distinctObserved(group)
        let observedNorm = Set(observed.titles.map(TextNormalization.normalizeTrackTitle).filter { !$0.isEmpty })

        var candidates: [LastfmCandidate] = []
        for identity in identities.prefix(Self.candidateMax) {
            let lookup = try? await AlbumTurnoverEngine.getCachedTracklist(context: modelContext, client: client, artist: identity.artist, album: identity.album)
            switch lookup {
            case .found(let tracklist):
                var seenTitleNorm = Set<String>()
                var tracks: [String] = []
                for t in tracklist.tracks {
                    let norm = TextNormalization.normalizeTrackTitle(t)
                    guard !norm.isEmpty, !seenTitleNorm.contains(norm) else { continue }
                    seenTitleNorm.insert(norm)
                    tracks.append(t)
                }
                let matched = tracks.filter { observedNorm.contains(TextNormalization.normalizeTrackTitle($0)) }.count
                let coverage = tracks.isEmpty ? 0 : Double(matched) / Double(tracks.count)
                candidates.append(LastfmCandidate(
                    queryArtist: identity.artist, queryAlbum: identity.album, isAutoMatch: identity.isAutoMatch,
                    canonicalArtist: tracklist.artist, canonicalAlbum: tracklist.album,
                    tracks: tracks, trackCount: tracks.count, matchedCount: matched, coverage: coverage
                ))
            case .noMatch, .none:
                if identity.isAutoMatch {
                    candidates.append(LastfmCandidate(
                        queryArtist: identity.artist, queryAlbum: identity.album, isAutoMatch: true,
                        canonicalArtist: identity.artist, canonicalAlbum: identity.album,
                        tracks: [], trackCount: nil, matchedCount: 0, coverage: 0
                    ))
                }
                // Non-auto-match candidates with no catalog tracklist carry no
                // signal and are dropped entirely.
            }
        }

        var bestIndex: Int?
        var bestCoverage = -1.0
        for (i, c) in candidates.enumerated() where c.trackCount != nil && c.trackCount! >= observed.count && c.coverage > bestCoverage {
            bestCoverage = c.coverage
            bestIndex = i
        }
        if let bestIndex { candidates[bestIndex].isBestFit = true }

        candidates.sort { a, b in
            if a.isAutoMatch != b.isAutoMatch { return a.isAutoMatch }
            if a.coverage != b.coverage { return a.coverage > b.coverage }
            return a.matchedCount > b.matchedCount
        }

        lastfmAlternates = .loaded(candidates)
    }

    // MARK: - Apple Music

    @ViewBuilder
    private var appleMusicSection: some View {
        switch appleMusicEditions {
        case .idle:
            Button("Search Apple Music Library") { Task { await searchAppleMusic() } }
        case .loading:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Searching Music.app…") }
                .font(AppTypography.supporting).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).font(AppTypography.supporting).foregroundStyle(.red)
            Button("Try Again") { Task { await searchAppleMusic() } }
        case .loaded(let editions):
            if editions.isEmpty {
                Text("No matching album found in your Apple Music library.").font(AppTypography.supporting).foregroundStyle(.secondary)
            } else {
                ForEach(Array(editions.enumerated()), id: \.offset) { index, edition in
                    selectableRow(
                        icon: "music.note", title: edition.album,
                        subtitle: "\(edition.tracks.count) tracks" + (edition.observedMatches > 0 ? " · \(edition.observedMatches) already played" : ""),
                        isSelected: selection == .appleMusicEdition(index: index), isEnabled: true,
                        expanded: expandedAppleMusicIndex == index, onToggleExpand: { expandedAppleMusicIndex = expandedAppleMusicIndex == index ? nil : index }
                    ) {
                        selection = .appleMusicEdition(index: index)
                    }
                    if expandedAppleMusicIndex == index {
                        let observedNorm = Set(observedTitles.map(TextNormalization.normalizeTrackTitle))
                        trackList(edition.tracks.map { ($0.title, observedNorm.contains(TextNormalization.normalizeTrackTitle($0.title))) }, numbered: true)
                    }
                }
            }
        }
    }

    private func searchAppleMusic() async {
        appleMusicEditions = .loading
        do {
            let editions = try await AppleMusicMatcher.findAlbumEditions(artist: group.artist, album: TextNormalization.stripEditionSuffix(group.displayName), observedTitles: observedTitles)
            appleMusicEditions = .loaded(editions)
        } catch {
            appleMusicEditions = .failed(error.localizedDescription)
        }
    }

    // MARK: - Save (the sole commit point)

    private func save() {
        guard let selection else { return }
        isSaving = true
        errorMessage = nil
        Task {
            defer { isSaving = false }
            do {
                switch selection {
                case .canonical(let candidateID):
                    // Reuses the tracklist already fetched while building the
                    // candidate list (including its autocorrected canonical
                    // artist/album strings) — no redundant network call, and
                    // guaranteed to be the exact same cache entry the very
                    // next turnover refresh reads back.
                    guard case .loaded(let candidates) = lastfmAlternates,
                          let candidate = candidates.first(where: { $0.id == candidateID }) else {
                        errorMessage = "That candidate is no longer available — try again."
                        return
                    }
                    try AlbumMatchFixEngine.applyCanonical(context: modelContext, group: group, canonicalArtist: candidate.canonicalArtist, canonicalAlbum: candidate.canonicalAlbum)
                case .appleMusicEdition(let index):
                    guard case .loaded(let editions) = appleMusicEditions, editions.indices.contains(index) else {
                        errorMessage = "That Apple Music result is no longer available — try searching again."
                        return
                    }
                    try AlbumMatchFixEngine.applyManual(context: modelContext, group: group, tracks: editions[index].tracks.map(\.title))
                case .manualPaste:
                    try AlbumMatchFixEngine.applyManual(context: modelContext, group: group, tracks: manualTracks)
                case .observed:
                    try AlbumMatchFixEngine.applyObserved(context: modelContext, group: group)
                case .resetToAutomatic:
                    try AlbumMatchFixEngine.resetToAutomatic(context: modelContext, group: group)
                }
                onResolved()
                dismiss()
            } catch {
                errorMessage = "Couldn't save: \(error.localizedDescription)"
            }
        }
    }
}

private struct PastedTracklistDialog: View {
    let onAccept: (String, [String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var isEditorFocused: Bool

    init(initialText: String, onAccept: @escaping (String, [String]) -> Void) {
        self.onAccept = onAccept
        _text = State(initialValue: initialText)
    }

    private var parsedTracks: [String] {
        PastedTracklistParser.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Paste Tracklist")
                    .font(AppTypography.sectionTitle)
                Text("Paste one track per line. Track numbers and trailing durations are removed automatically.")
                    .font(AppTypography.supporting)
                    .foregroundStyle(.secondary)
            }

            TextEditor(text: $text)
                .font(AppTypography.codeInput)
                .focused($isEditorFocused)
                .frame(minHeight: 140)
                .padding(6)
                .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.separator, lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Preview")
                        .font(AppTypography.contentTitle)
                    Spacer()
                    Text("\(parsedTracks.count) track\(parsedTracks.count == 1 ? "" : "s") detected")
                        .font(AppTypography.supporting)
                        .foregroundStyle(.secondary)
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if parsedTracks.isEmpty {
                            Text("Paste a tracklist above to preview the cleaned titles.")
                                .font(AppTypography.supporting)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 28)
                        } else {
                            ForEach(Array(parsedTracks.enumerated()), id: \.offset) { index, track in
                                HStack(spacing: 10) {
                                    Text("\(index + 1)")
                                        .font(AppTypography.supportingDense)
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 24, alignment: .trailing)
                                    Text(track)
                                        .font(AppTypography.supporting)
                                        .textSelection(.enabled)
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 5)
                                if index < parsedTracks.count - 1 {
                                    Divider()
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .frame(minHeight: 150)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            Divider()

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Use Tracklist") {
                    onAccept(text, parsedTracks)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(parsedTracks.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560, height: 560)
        .onAppear { isEditorFocused = true }
    }
}
