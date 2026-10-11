import SwiftUI
import SwiftData
import AppKit

/// App-wide ⌘F search: a grouped command palette with native keyboard
/// navigation and navigation destinations.
struct GlobalSearchOverlay: View {
    @Environment(\.modelContext) private var modelContext
    @Binding var isPresented: Bool
    let onSelect: (SearchResult) -> Void
    var allowedKinds: Set<SearchResultKind>? = nil

    @State private var query = ""
    @State private var candidates: GlobalSearchEngine.Candidates?
    @State private var results: [SearchResult] = []
    @State private var selectedIndex = 0
    @FocusState private var isFieldFocused: Bool
    @State private var keyMonitor: Any?

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.40)
                    .ignoresSafeArea()
                    .onTapGesture { isPresented = false }

                VStack(alignment: .leading, spacing: 0) {
                    searchField
                    Divider()
                    searchContent
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(.separator.opacity(0.5), lineWidth: 1)
                }
                .frame(width: min(640, max(0, proxy.size.width - 32)))
                .frame(maxHeight: max(0, proxy.size.height - 32))
                .shadow(radius: 24)
            }
        }
        .task { await loadCandidates() }
        .onChange(of: query) { _, _ in updateResults() }
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                switch event.keyCode {
                case 125: moveSelection(1); return nil
                case 126: moveSelection(-1); return nil
                case 36: commitSelection(); return nil
                case 53: isPresented = false; return nil
                default: return event
                }
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(allowedKinds == [.track] ? "Search tracks…" : "Search artists, albums, tracks…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($isFieldFocused)
                .frame(minWidth: 0)
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Close Search")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    @ViewBuilder
    private var searchContent: some View {
        if candidates == nil {
            ProgressView("Loading your library…")
                .frame(maxWidth: .infinity, minHeight: 96)
        } else if trimmedQuery.isEmpty {
            Text("Start typing to search your scrobble history.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 96)
        } else if results.isEmpty {
            Text("No results for “\(trimmedQuery)”.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 96)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(SearchResultKind.allCases.enumerated()), id: \.element) { kindIndex, kind in
                            let sectionResults = results.filter { $0.kind == kind }
                            if !sectionResults.isEmpty {
                                if hasVisibleSection(before: kindIndex) {
                                    Divider().padding(.vertical, 4)
                                }
                                Text(kind.pluralLabel)
                                    .font(AppTypography.tableHeading.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .padding(.horizontal, 16)
                                    .padding(.top, 8)
                                    .padding(.bottom, 4)
                                ForEach(sectionResults) { result in
                                    let index = results.firstIndex(of: result) ?? 0
                                    Button {
                                        selectedIndex = index
                                        commitSelection()
                                    } label: {
                                        resultRow(result, isSelected: index == selectedIndex)
                                    }
                                    .buttonStyle(.plain)
                                    .entityContextMenu(target: imageTarget(for: result))
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 520)
                .onChange(of: selectedIndex) { _, newValue in
                    guard results.indices.contains(newValue) else { return }
                    proxy.scrollTo(results[newValue].id, anchor: .center)
                }
            }
        }
    }

    private func hasVisibleSection(before kindIndex: Int) -> Bool {
        SearchResultKind.allCases.prefix(kindIndex).contains { kind in
            results.contains { $0.kind == kind }
        }
    }

    private func loadCandidates() async {
        let container = modelContext.container
        let imageLookup = (try? ImageResolutionEngine.imageLookup(context: modelContext)) ?? [:]
        let snapshots = try? await offMain {
            try await ScrobbleSnapshotReader(modelContainer: container).fetchSortedSnapshots()
        }
        if let snapshots {
            candidates = await Task.detached(priority: .userInitiated) {
                GlobalSearchEngine.makeCandidates(
                    scrobbles: QueryIdentity.canonicalizingArtists(snapshots),
                    imageLookup: imageLookup
                )
            }.value
        } else {
            candidates = GlobalSearchEngine.Candidates(artists: [], albums: [], tracks: [])
        }
        updateResults()
        await Task.yield()
        isFieldFocused = true
    }

    private func updateResults() {
        guard let candidates else { return }
        let matches = GlobalSearchEngine.filter(candidates: candidates, query: query)
        results = matches.filter { allowedKinds?.contains($0.kind) ?? true }
        selectedIndex = 0
    }

    private func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = max(0, min(results.count - 1, selectedIndex + delta))
    }

    private func commitSelection() {
        guard results.indices.contains(selectedIndex) else { return }
        let result = results[selectedIndex]
        isPresented = false
        onSelect(result)
    }

    private func resultRow(_ result: SearchResult, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            EntityThumbnail(url: result.imageURL, entity: result.kind.entity)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .font(AppTypography.contentTitle)
                    .lineLimit(1)
                if let subtitle = result.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(AppTypography.compactMetadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            Text("\(result.playCount.formatted()) plays")
                .font(AppTypography.compactMetadata.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if result.kind == .track, let track = result.track {
                TrackLovedIndicator(
                    artist: track.artist, track: track.name,
                    initialValue: false, font: AppTypography.metadata
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
    }

    private func imageTarget(for result: SearchResult) -> ImageTarget {
        switch result.kind {
        case .artist:
            return ImageTarget(kind: .artist, artist: result.artist?.name ?? result.title, album: nil, track: nil)
        case .album:
            return ImageTarget(
                kind: .album, artist: result.album?.artist ?? "",
                album: result.album?.name ?? result.title, track: nil
            )
        case .track:
            return ImageTarget(
                kind: .track, artist: result.track?.artist ?? "",
                album: result.track?.album, track: result.track?.name ?? result.title
            )
        }
    }
}
