import SwiftUI
import SwiftData

enum TagsLoadState {
    case loading
    case loaded(EntityTagsResult)
}

/// Tags area for a detail page: two visually distinct sections —
/// "Community tags" (Last.fm's
/// aggregate `getTopTags`, always read-only) and "Your tags" (the connected
/// account's own `getTags`, add/remove once Track Actions is connected).
/// Browsing (a Library tab) is separate, later work per tags-feature-prompt.md
/// — not built here.
struct EntityTagsSectionView: View {
    let communityTags: TagsLoadState
    let yourTags: TagsLoadState
    let entity: TopChartsEntity
    let artist: String
    let album: String?
    let track: String?
    let modelContext: ModelContext
    /// Called with the full updated personal-tags list right after a
    /// successful add/remove, so the caller can update its own `yourTags`
    /// state optimistically — Last.fm's `*.getTags` is well known to lag
    /// behind `*.addTags`/`removeTag` by anywhere from seconds to much
    /// longer, so re-fetching immediately would often show the stale list
    /// and look like the write silently failed.
    let onTagsUpdated: ([String]) -> Void

    @State private var draft = ""
    @State private var busy = false
    @State private var writeError: String?
    @State private var albumWarning: AlbumScopeWarning?
    @State private var pendingTags: [String] = []
    @State private var showPublicNotice = false
    @State private var isAddingTag = false
    @State private var tagSuggestions: [String] = []
    @FocusState private var isTagFieldFocused: Bool

    private static let publicNoticeSeenKey = "trackActions.tagPublicNoticeSeen"

    private var isConnected: Bool {
        LastfmCredentialsStore.load()?.sessionKey != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            tagsSubsection(title: "Community tags", state: communityTags, emptyText: "No community tags yet", color: .secondary, removable: false)
            tagsSubsection(title: "Your tags", state: yourTags, emptyText: "You haven't tagged this yet", color: .blue, removable: true)

            if isConnected {
                if isAddingTag {
                    addTagEditor
                } else {
                    Button {
                        beginAddingTag()
                    } label: {
                        Label("Add tag", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .font(AppTypography.compactMetadata)
                    .disabled(Connectivity.shared.isOffline)
                    .help(Connectivity.shared.isOffline ? "Offline mode is on. Go online to edit your tags." : "")
                }
            } else {
                Text("Connect Track Actions in Settings to add or remove your own tags.")
                    .font(AppTypography.compactMetadata)
                    .foregroundStyle(.tertiary)
            }

            if let writeError {
                Text(writeError).font(AppTypography.compactMetadata).foregroundStyle(.red)
            }
        }
        .alert("Tags are public on Last.fm", isPresented: $showPublicNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Tags you add here are visible on your public Last.fm profile and contribute to the same shared aggregate data every tool (including this app's Top Tags chart) reads from.")
        }
        .alert("This tag applies to more than one album", isPresented: Binding(
            get: { albumWarning != nil }, set: { if !$0 { albumWarning = nil; pendingTags = [] } }
        )) {
            Button("Cancel", role: .cancel) { albumWarning = nil; pendingTags = [] }
            Button("Continue") {
                let tags = pendingTags
                albumWarning = nil
                pendingTags = []
                Task { await commitAdd(tags) }
            }
        } message: {
            Text(albumWarningMessage)
        }
    }

    private var addTagEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("Add tag…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(AppTypography.compactMetadata)
                    .focused($isTagFieldFocused)
                    .disabled(busy)
                    .onSubmit { Task { await handleAdd() } }
                Button("Add") { Task { await handleAdd() } }
                    .disabled(busy || draft.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel", role: .cancel) { cancelAddingTag() }
                    .disabled(busy)
                if busy {
                    ProgressView().controlSize(.small)
                }
            }

            if !matchingSuggestions.isEmpty {
                TagFlowLayout(spacing: 6) {
                    ForEach(matchingSuggestions, id: \.self) { suggestion in
                        Button(suggestion.capitalized) {
                            applySuggestion(suggestion)
                        }
                        .buttonStyle(.borderless)
                        .font(AppTypography.compactMetadata)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                    }
                }
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }

    private var matchingSuggestions: [String] {
        let query = currentDraftFragment
        guard !query.isEmpty else { return [] }
        let existing = Set(currentTags(yourTags).map(LastfmTagNormalization.normalize))
        return tagSuggestions
            .filter {
                let normalized = LastfmTagNormalization.normalize($0)
                return !existing.contains(normalized) && normalized != query && normalized.contains(query)
            }
            .sorted {
                let lhsPrefix = LastfmTagNormalization.normalize($0).hasPrefix(query)
                let rhsPrefix = LastfmTagNormalization.normalize($1).hasPrefix(query)
                return lhsPrefix == rhsPrefix ? $0.localizedStandardCompare($1) == .orderedAscending : lhsPrefix
            }
            .prefix(6)
            .map { $0 }
    }

    private var currentDraftFragment: String {
        let fragment = draft.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "," || $0.isNewline }).last ?? ""
        return LastfmTagNormalization.normalize(String(fragment))
    }

    private var albumWarningMessage: String {
        guard let albumWarning else { return "" }
        let others = albumWarning.otherAlbums.map { "\u{201c}\($0.name)\u{201d}" }.joined(separator: ", ")
        var msg = "This tag will also apply to \(others) since Last.fm tags aren't album-specific."
        if let sharpen = albumWarning.sharpen {
            func fmt(_ s: Int) -> String { "\(s / 60):\(String(format: "%02d", s % 60))" }
            msg += " \u{201c}\(sharpen.otherAlbum)\u{201d}'s version is \(fmt(sharpen.otherSeconds)) vs. this one's \(fmt(sharpen.thisSeconds)) — likely a different recording, not just a reissue."
        }
        return msg + " Continue?"
    }

    private func currentTags(_ state: TagsLoadState) -> [String] {
        if case .loaded(let result) = state, !result.inherited { return result.tags }
        return []
    }

    private func beginAddingTag() {
        writeError = nil
        tagSuggestions = availableTagSuggestions()
        isAddingTag = true
        Task { @MainActor in
            await Task.yield()
            isTagFieldFocused = true
        }
    }

    private func cancelAddingTag() {
        draft = ""
        writeError = nil
        isAddingTag = false
        isTagFieldFocused = false
    }

    private func availableTagSuggestions() -> [String] {
        var suggestions: [String] = []
        if let username = LastfmCredentialsStore.load()?.username {
            suggestions.append(contentsOf: PersonalTagVocabulary.tags(for: username))
        }
        if case .loaded(let result) = communityTags {
            suggestions.append(contentsOf: result.tags)
        }
        if case .loaded(let result) = yourTags {
            suggestions.append(contentsOf: result.tags)
        }
        if let artists = try? modelContext.fetch(FetchDescriptor<Artist>()) {
            suggestions.append(contentsOf: artists.compactMap(\.communityTags).flatMap { $0 })
        }

        var seen = Set<String>()
        return suggestions.filter { tag in
            let normalized = LastfmTagNormalization.normalize(tag)
            return !normalized.isEmpty && seen.insert(normalized).inserted
        }
    }

    private func applySuggestion(_ suggestion: String) {
        if let separator = draft.lastIndex(where: { $0 == "," || $0.isNewline }) {
            draft = String(draft[...separator]) + " " + suggestion
        } else {
            draft = suggestion
        }
        isTagFieldFocused = true
    }

    private func handleAdd() async {
        guard !busy else { return }
        let tags = LastfmTagNormalization.normalizeList([draft])
        guard !tags.isEmpty else { return }
        let existing = Set(currentTags(yourTags))
        let fresh = tags.filter { !existing.contains($0) }
        guard !fresh.isEmpty else {
            writeError = "Already tagged"
            draft = ""
            return
        }
        writeError = nil

        if entity == .track, let track {
            let descriptor = FetchDescriptor<Scrobble>()
            let scrobbles = (try? modelContext.fetch(descriptor).map(\.snapshot)) ?? []
            let warning = await AlbumScopeWarningEngine.check(
                scrobbles: scrobbles, client: DeezerAPIClient(), artist: artist, track: track, album: album
            )
            if warning.hasWarning {
                pendingTags = fresh
                albumWarning = warning
                return
            }
        }
        await commitAdd(fresh)
    }

    private func commitAdd(_ tags: [String]) async {
        guard let credentials = LastfmCredentialsStore.load(), let secret = credentials.apiSecret, let sessionKey = credentials.sessionKey else {
            writeError = "Connect Track Actions in Settings first."
            return
        }
        busy = true
        defer { busy = false }
        do {
            try await LastfmWriteClient.addTags(
                apiKey: credentials.apiKey, secret: secret, sessionKey: sessionKey, entity: entity,
                artist: artist, album: album, track: track, tags: tags
            )
            draft = ""
            isAddingTag = false
            isTagFieldFocused = false
            PersonalTagVocabulary.merge(tags, for: credentials.username)
            EntityTagsEngine.patchUserTags(context: modelContext, kind: entity, artist: artist, name: entity == .album ? album : track, adding: tags)
            let prior = Set(currentTags(yourTags))
            onTagsUpdated(Array(prior.union(tags)).sorted())
            if !UserDefaults.standard.bool(forKey: Self.publicNoticeSeenKey) {
                UserDefaults.standard.set(true, forKey: Self.publicNoticeSeenKey)
                showPublicNotice = true
            }
        } catch {
            writeError = "Failed to add tag: \(describeSyncError(error))"
        }
    }

    private func handleRemove(_ tag: String) {
        guard !busy else { return }
        guard let credentials = LastfmCredentialsStore.load(), let secret = credentials.apiSecret, let sessionKey = credentials.sessionKey else {
            writeError = "Connect Track Actions in Settings first."
            return
        }
        writeError = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                try await LastfmWriteClient.removeTag(
                    apiKey: credentials.apiKey, secret: secret, sessionKey: sessionKey, entity: entity,
                    artist: artist, album: album, track: track, tag: tag
                )
                EntityTagsEngine.patchUserTags(context: modelContext, kind: entity, artist: artist, name: entity == .album ? album : track, removing: tag)
                onTagsUpdated(currentTags(yourTags).filter { $0 != tag })
            } catch {
                writeError = "Failed to remove tag: \(describeSyncError(error))"
            }
        }
    }

    private func tagsSubsection(title: String, state: TagsLoadState, emptyText: String, color: Color, removable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).font(AppTypography.sectionTitle).foregroundStyle(.secondary)
                if case .loaded(let result) = state, result.inherited, !result.tags.isEmpty {
                    Text("from artist").font(AppTypography.supportingDense).foregroundStyle(.tertiary)
                }
            }
            switch state {
            case .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading…").font(AppTypography.compactMetadata).foregroundStyle(.tertiary)
                }
            case .loaded(let result):
                if result.tags.isEmpty {
                    Text(emptyText).font(AppTypography.compactMetadata).foregroundStyle(.tertiary)
                } else {
                    TagFlowLayout(spacing: 6) {
                        ForEach(result.tags, id: \.self) { tag in
                            HStack(spacing: 4) {
                                Text(tag.capitalized).font(AppTypography.compactMetadata)
                                if removable, !result.inherited, isConnected {
                                    Button {
                                        handleRemove(tag)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(busy)
                                }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(color.opacity(0.15), in: Capsule())
                            .foregroundStyle(color)
                        }
                    }
                }
            }
        }
    }
}
