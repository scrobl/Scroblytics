import SwiftUI
import SwiftData

/// "Name Corrections": names Last.fm spells oddly (see `NameCorrectionFinder`), each with a suggestion to apply, edit or dismiss, plus the
/// corrections already made. Nothing leaves the Mac and nothing on Last.fm changes; a correction only changes how the name is shown.
struct NameCorrectionsView: View {
    let modelContainer: ModelContainer
    let navigation: DetailNavigationCoordinator

    enum Listing: String, Codable, CaseIterable, Identifiable {
        case review, corrected, reviewed
        var id: Self { self }
        var label: String {
            switch self {
            case .review: "To Review"
            case .corrected: "Corrected"
            case .reviewed: "Looks Right"
            }
        }
    }

    enum KindFilter: String, Codable, CaseIterable, Identifiable {
        case all, artist, album, track
        var id: Self { self }
        var label: String {
            switch self {
            case .all: "All names"
            case .artist: "Artists"
            case .album: "Albums"
            case .track: "Tracks"
            }
        }
        func includes(_ kind: NameCorrectionKind) -> Bool { self == .all || self.rawValue == kind.rawValue }
    }

    /// Which kind of problem the list shows. "Likely problems" leaves out ALL CAPS, which is mostly how a title was meant to be written.
    enum Why: String, Codable, CaseIterable, Identifiable {
        case likely, everything, variants, spacing, oddCapitals, allCaps
        var id: Self { self }
        var label: String {
            switch self {
            case .likely: "Likely problems"
            case .everything: "Everything, ALL CAPS too"
            case .variants: NameCorrectionFinder.Reason.variants.label
            case .spacing: NameCorrectionFinder.Reason.spacing.label
            case .oddCapitals: NameCorrectionFinder.Reason.oddCapitals.label
            case .allCaps: NameCorrectionFinder.Reason.allCaps.label
            }
        }
        func includes(_ reason: NameCorrectionFinder.Reason) -> Bool {
            switch self {
            case .likely: reason != .allCaps
            case .everything: true
            case .variants: reason == .variants
            case .spacing: reason == .spacing
            case .oddCapitals: reason == .oddCapitals
            case .allCaps: reason == .allCaps
            }
        }
    }

    struct Options: Codable, Equatable {
        var listing = Listing.review
        var kind = KindFilter.all
        var why = Why.likely
    }

    private static let toolId = "namecorrections"

    @Environment(\.modelContext) private var modelContext
    @State private var options = Options()
    @State private var findings: [NameCorrectionFinder.Finding] = []
    @State private var decided: [NameCorrectionSnapshot] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var correcting: NameCorrectionSubject?
    @State private var busyKeys: Set<String> = []

    private var shownFindings: [NameCorrectionFinder.Finding] {
        findings.filter { options.kind.includes($0.kind) && options.why.includes($0.reason) }
    }

    private func shownDecisions(_ status: NameCorrectionStatus) -> [NameCorrectionSnapshot] {
        decided.filter { $0.status == status && options.kind.includes($0.kind) }
            .sorted { ($0.kind.rawValue, $0.original.lowercased()) < ($1.kind.rawValue, $1.original.lowercased()) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageSettingsHeader("Name Corrections") {
                    ToolControlsFlow { controls }
                }
                Text("Last.fm sometimes spells a name oddly: a capital inside a word, a name in all capitals, the same name spelled two ways. A correction changes only how the name is shown on this Mac, in capitalization and spacing. Nothing changes on Last.fm or in your saved plays.")
                    .font(AppTypography.compactMetadata).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let errorMessage {
                    Text(errorMessage).font(AppTypography.compactMetadata).foregroundStyle(.red)
                }
                content
            }
            .padding(16)
        }
        .navigationTitle("Name Corrections")
        .task {
            options = ToolFilterSettingsStore.load(Options.self, toolId: Self.toolId, context: modelContext, default: Options())
            await reload()
        }
        .onChange(of: options) { _, new in ToolFilterSettingsStore.save(new, toolId: Self.toolId, context: modelContext) }
        .onReceive(NotificationCenter.historyOrNamesChanged) { _ in Task { await reload() } }
        .sheet(item: $correcting) { subject in NameCorrectionSheet(subject: subject) }
    }

    @ViewBuilder
    private var controls: some View {
        Picker("List", selection: $options.listing) {
            ForEach(Listing.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden()
        .help("To Review: names that look wrong. Corrected: the corrections you have made. Looks Right: names you marked as fine.")
        Picker("Names", selection: $options.kind) {
            ForEach(KindFilter.allCases) { Text($0.label).tag($0) }
        }
        .fixedSize()
        if options.listing == .review {
            Picker("Why", selection: $options.why) {
                ForEach(Why.allCases) { Text($0.label).tag($0) }
            }
            .fixedSize()
            .help("Likely problems are different spellings, extra spaces and odd capitals. ALL CAPS is left out unless you ask for it, because many titles are written that way on purpose.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && findings.isEmpty && decided.isEmpty {
            ProgressView().frame(maxWidth: .infinity, minHeight: 240)
        } else {
            switch options.listing {
            case .review: reviewList
            case .corrected: decisionList(.corrected)
            case .reviewed: decisionList(.looksRight)
            }
        }
    }

    // MARK: To review

    @ViewBuilder
    private var reviewList: some View {
        let shown = shownFindings
        if shown.isEmpty {
            ContentUnavailableView(
                "Nothing to review", systemImage: "checkmark.circle",
                description: Text(findings.isEmpty ? "No name looks oddly capitalized or spaced." : "Nothing matches these filters. \(findings.count.formatted()) in all, including ALL CAPS names (choose Everything under Why).")
            )
            .frame(maxWidth: .infinity, minHeight: 240)
        } else {
            Text("\(shown.count.formatted()) \(shown.count == 1 ? "name" : "names") to review")
                .font(AppTypography.metadata.monospacedDigit()).foregroundStyle(.secondary)
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(shown) { finding in
                    NameCorrectionFindingRow(
                        finding: finding, isBusy: busyKeys.contains(finding.key),
                        onApply: { run(finding.key) { try await NameCorrections.save(container: modelContainer, kind: finding.kind, artist: finding.artist, original: finding.original, display: finding.suggestion, keepIfSame: finding.mergesSpellings) } },
                        onEdit: { correcting = NameCorrectionSubject(kind: finding.kind, artist: finding.artist, name: finding.original) },
                        onLooksRight: { run(finding.key) { try await NameCorrections.markLooksRight(container: modelContainer, kind: finding.kind, artist: finding.artist, original: finding.original) } },
                        onOpen: { open(kind: finding.kind, artist: finding.artist, name: finding.suggestion) }
                    )
                    Divider()
                }
            }
            .padding(.horizontal, 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator.opacity(0.4), lineWidth: 1) }
        }
    }

    // MARK: Corrected and looks right

    @ViewBuilder
    private func decisionList(_ status: NameCorrectionStatus) -> some View {
        let rows = shownDecisions(status)
        if rows.isEmpty {
            ContentUnavailableView(
                status == .corrected ? "No corrections yet" : "Nothing marked as right",
                systemImage: status == .corrected ? "textformat" : "hand.thumbsup",
                description: Text(status == .corrected
                    ? "Apply a suggestion here, or right-click any artist, album or track and choose Correct Name…."
                    : "Names you mark Looks Right are kept out of To Review. They can be put back here.")
            )
            .frame(maxWidth: .infinity, minHeight: 240)
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows, id: \.key) { row in
                    NameCorrectionDecisionRow(
                        row: row, isBusy: busyKeys.contains(row.key),
                        onEdit: { correcting = NameCorrectionSubject(kind: row.kind, artist: row.artist, name: row.display ?? row.original) },
                        onReset: { run(row.key) { try await NameCorrections.reset(container: modelContainer, kind: row.kind, artist: row.artist, original: row.original) } }
                    )
                    Divider()
                }
            }
            .padding(.horizontal, 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator.opacity(0.4), lineWidth: 1) }
        }
    }

    // MARK: Work

    private func run(_ key: String, _ work: @escaping @MainActor () async throws -> Void) {
        guard !busyKeys.contains(key) else { return }
        busyKeys.insert(key)
        Task {
            defer { busyKeys.remove(key) }
            do { try await work(); errorMessage = nil } catch { errorMessage = error.localizedDescription }
        }
    }

    private func open(kind: NameCorrectionKind, artist: String, name: String) {
        switch kind {
        case .artist: navigation.goToArtist(ArtistIdentity(name: name))
        case .album: navigation.goToAlbum(AlbumIdentity(artist: artist, name: name))
        case .track: navigation.goToTrack(TrackIdentity(artist: artist, name: name))
        }
    }

    private func reload() async {
        isLoading = true
        do {
            let plays = try await ScrobbleHistoryCache.shared.snapshots(container: modelContainer)
            let rows = try await NameCorrectionStore(modelContainer: modelContainer).all()
            let handled = Set(rows.map(\.key))
            decided = rows
            findings = await Task.detached(priority: .utility) { NameCorrectionFinder.find(plays: plays, handled: handled) }.value
            errorMessage = nil
        } catch {
            errorMessage = "Couldn’t read your history: \(error.localizedDescription)"
        }
        isLoading = false
    }
}

private func kindIcon(_ kind: NameCorrectionKind) -> String {
    switch kind {
    case .artist: "music.mic"
    case .album: "square.stack"
    case .track: "music.note"
    }
}

struct NameCorrectionFindingRow: View {
    let finding: NameCorrectionFinder.Finding
    let isBusy: Bool
    let onApply: () -> Void
    let onEdit: () -> Void
    let onLooksRight: () -> Void
    let onOpen: () -> Void

    private var text: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(finding.spellings.count > 1 ? finding.spellings.map(\.name).joined(separator: "  ·  ") : finding.original)
                    .font(AppTypography.contentTitle).lineLimit(3).textSelection(.enabled)
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                Text(finding.suggestion).font(AppTypography.contentTitle).foregroundStyle(Color.accentColor).lineLimit(3)
            }
            AskFlowLayout(spacing: 8) {
                if finding.kind != .artist, !finding.artist.isEmpty { Text(finding.artist).lineLimit(1) }
                Text("\(finding.plays.formatted()) \(finding.plays == 1 ? "play" : "plays")").monospacedDigit()
                if finding.spellings.count > 1 {
                    Text(finding.spellings.map { "\($0.plays.formatted())" }.joined(separator: " + ")).foregroundStyle(.tertiary).monospacedDigit()
                }
                Text(finding.reason.label)
                    .lineLimit(1).fixedSize()
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(.quaternary.opacity(0.6)))
                    .help(finding.reason.explanation)
            }
            .font(AppTypography.compactMetadata).foregroundStyle(.secondary)
        }
    }

    private var buttons: some View {
        HStack(spacing: 6) {
            Button("Apply", action: onApply).buttonStyle(.borderedProminent).controlSize(.small)
                .help("Show this \(finding.kind.rawValue) as “\(finding.suggestion)” everywhere")
            Button("Edit…", action: onEdit).buttonStyle(.bordered).controlSize(.small)
                .help("Type the spelling you want instead")
            Button("Looks Right", action: onLooksRight).buttonStyle(.bordered).controlSize(.small)
                .help("Keep Last.fm’s spelling and stop listing this name")
            Button(action: onOpen) { Image(systemName: "chevron.right") }.buttonStyle(.borderless)
                .help("Open this \(finding.kind.rawValue)")
        }
        .fixedSize()
        .disabled(isBusy)
    }

    private var icon: some View {
        Image(systemName: kindIcon(finding.kind)).foregroundStyle(.secondary).frame(width: 22).padding(.top, 2)
    }

    var body: some View {
        // Beside the text when there is room, under it when there isn't.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                icon
                text.frame(maxWidth: 520, alignment: .leading)
                Spacer(minLength: 8)
                buttons
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    icon
                    text.frame(maxWidth: .infinity, alignment: .leading)
                }
                buttons.padding(.leading, 34)
            }
        }
        .padding(.vertical, 10)
    }
}

struct NameCorrectionDecisionRow: View {
    let row: NameCorrectionSnapshot
    let isBusy: Bool
    let onEdit: () -> Void
    let onReset: () -> Void

    private var text: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let display = row.display {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.original).font(AppTypography.contentTitle).foregroundStyle(.secondary).lineLimit(3)
                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                    Text(display).font(AppTypography.contentTitle).lineLimit(3)
                }
            } else {
                Text(row.original).font(AppTypography.contentTitle).lineLimit(3)
            }
            if row.kind != .artist, !row.artist.isEmpty {
                Text(row.artist).font(AppTypography.compactMetadata).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 6) {
            if row.display != nil {
                Button("Edit…", action: onEdit).buttonStyle(.bordered).controlSize(.small)
            }
            Button(row.display == nil ? "Put Back" : "Reset", action: onReset).buttonStyle(.bordered).controlSize(.small)
                .help(row.display == nil ? "List this name for review again" : "Show this name as Last.fm spells it")
        }
        .fixedSize()
        .disabled(isBusy)
    }

    private var icon: some View { Image(systemName: kindIcon(row.kind)).foregroundStyle(.secondary).frame(width: 22) }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                icon
                text.frame(maxWidth: 520, alignment: .leading)
                Spacer(minLength: 8)
                buttons
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    icon
                    text.frame(maxWidth: .infinity, alignment: .leading)
                }
                buttons.padding(.leading, 34)
            }
        }
        .padding(.vertical, 10)
    }
}
