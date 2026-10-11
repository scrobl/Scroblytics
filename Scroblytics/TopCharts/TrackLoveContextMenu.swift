import SwiftUI
import SwiftData
import Observation

@ModelActor
private actor LovedTracksDataReader {
    func fetchKeys() throws -> Set<String> {
        Set(try modelContext.fetch(FetchDescriptor<LovedTrackEntry>()).map(\.cacheKey))
    }
}

@MainActor
@Observable
final class LovedTracksStore {
    private(set) var keys: Set<String> = []
    private(set) var hasLoaded = false

    func load(container: ModelContainer, force: Bool = false) async {
        guard force || !hasLoaded else { return }
        if let loadedKeys = try? await offMain({ try await LovedTracksDataReader(modelContainer: container).fetchKeys() }) {
            keys = loadedKeys
            hasLoaded = true
        }
    }

    func isLoved(artist: String, track: String) -> Bool {
        keys.contains(TextNormalization.lovedKey(artist: artist, track: track))
    }

    func setLoved(_ loved: Bool, artist: String, track: String) {
        let key = TextNormalization.lovedKey(artist: artist, track: track)
        if loved {
            keys.insert(key)
        } else {
            keys.remove(key)
        }
    }
}

struct TrackLovedIndicator: View {
    @Environment(LovedTracksStore.self) private var lovedTracksStore
    @Environment(FlaggedTracksStore.self) private var flaggedTracksStore

    let artist: String
    let track: String
    let initialValue: Bool
    let font: Font
    var enabled = true

    private var isLoved: Bool {
        enabled && lovedTracksStore.hasLoaded
            ? lovedTracksStore.isLoved(artist: artist, track: track)
            : (enabled && initialValue)
    }

    var body: some View {
        HStack(spacing: 4) {
            if isLoved {
                Image(systemName: "heart.fill")
                    .font(font)
                    .foregroundStyle(.red)
                    .help("Loved")
            }
            if enabled && flaggedTracksStore.isFlagged(artist: artist, track: track) {
                Image(systemName: "flag.fill")
                    .font(font)
                    .foregroundStyle(.orange)
                    .help("Flagged")
            }
            if enabled {
                TrackLibraryGapBadge(artist: artist, track: track, font: font)
            }
        }
    }
}

/// The "not in your Apple Music library" mark — a track whose saved Library Gaps status says it's missing from the
/// library. Used by `TrackLovedIndicator` (lists) and directly by the track page's header.
struct TrackLibraryGapBadge: View {
    @Environment(LibraryGapBadgeStore.self) private var store

    let artist: String
    let track: String
    let font: Font

    var body: some View {
        if store.isGap(artist: artist, track: track) {
            Image(systemName: "music.note.slash")
                .font(font)
                .foregroundStyle(.pink)
                .help("Not in your Apple Music library")
        }
    }
}

struct TrackFlaggedIndicator: View {
    @Environment(FlaggedTracksStore.self) private var flaggedTracksStore

    let artist: String
    let track: String
    let font: Font

    var body: some View {
        if flaggedTracksStore.isFlagged(artist: artist, track: track) {
            Image(systemName: "flag.fill")
                .font(font)
                .foregroundStyle(.orange)
                .help("Flagged")
        }
    }
}

private struct TrackLoveContextMenuModifier: ViewModifier {
    @Environment(\.modelContext) private var modelContext
    @Environment(LovedTracksStore.self) private var lovedTracksStore

    let artist: String
    let track: String

    @State private var isUpdating = false
    @State private var errorMessage: String?

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button {
                    Task { await toggleLoved() }
                } label: {
                    Label(isLoved ? "Unlove" : "Love", systemImage: isLoved ? "heart.slash" : "heart")
                }
                .disabled(isUpdating)
            }
            .alert("Couldn’t Update Loved Status", isPresented: isShowingError) {
                Button("OK", role: .cancel) {
                    errorMessage = nil
                }
            } message: {
                Text(errorMessage ?? "")
            }
    }

    private var isLoved: Bool {
        lovedTracksStore.isLoved(artist: artist, track: track)
    }

    private var isShowingError: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func toggleLoved() async {
        guard !isUpdating else { return }
        let wasLoved = isLoved
        isUpdating = true
        defer { isUpdating = false }

        do {
            try await LovedTracksEngine.toggle(
                context: modelContext,
                artist: artist,
                track: track,
                loved: wasLoved
            )
            lovedTracksStore.setLoved(!wasLoved, artist: artist, track: track)
        } catch {
            errorMessage = "Failed to \(wasLoved ? "unlove" : "love") “\(track)”: \(error.localizedDescription)"
        }
    }
}

extension View {
    func trackLoveContextMenu(artist: String, track: String) -> some View {
        modifier(TrackLoveContextMenuModifier(artist: artist, track: track))
    }
}
