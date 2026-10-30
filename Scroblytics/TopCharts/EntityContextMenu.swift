import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct TargetedSyncActivity: Sendable {
    let id: UUID
    let title: String
}

/// An item a screen adds at the top of the common menu (after Open), for what only that screen can do with the row.
struct EntityContextAction: Identifiable {
    let id = UUID()
    let title: String
    var isDestructive = false
    let action: () -> Void
}

struct EntityContextMenuModifier: ViewModifier {
    let target: ImageTarget
    let currentImageURL: String?
    let onFixAlbumMatch: (() -> Void)?
    let onOpen: (() -> Void)?
    let onImageRefreshed: ((String) -> Void)?
    var extraActions: [EntityContextAction] = []

    @Environment(\.modelContext) private var modelContext
    @State private var hasCustomImage = false
    @State private var errorMessage: String?
    @State private var resyncMessage: String?
    @State private var isResyncing = false
    @State private var isRefreshingImage = false
    @State private var imageRefreshMessage: String?

    func body(content: Content) -> some View {
        content
            .contextMenu {
                EntityContextMenuItems(
                    target: target,
                    currentImageURL: currentImageURL,
                    onFixAlbumMatch: onFixAlbumMatch,
                    onOpen: onOpen,
                    onImageRefreshed: onImageRefreshed,
                    extraActions: extraActions,
                    hasCustomImage: $hasCustomImage,
                    errorMessage: $errorMessage,
                    resyncMessage: $resyncMessage,
                    isResyncing: $isResyncing,
                    imageRefreshMessage: $imageRefreshMessage,
                    isRefreshingImage: $isRefreshingImage
                )
                .onAppear(perform: refreshState)
            }
            .onDrop(of: [.image], isTargeted: nil, perform: receiveDrop)
            .alert("Error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .alert("Image Refresh", isPresented: Binding(
                get: { imageRefreshMessage != nil },
                set: { if !$0 { imageRefreshMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(imageRefreshMessage ?? "")
            }
            .alert("Resync Complete", isPresented: Binding(
                get: { resyncMessage != nil },
                set: { if !$0 { resyncMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(resyncMessage ?? "")
            }
    }

    private func refreshState() {
        do {
            hasCustomImage = try ImageResolutionEngine.hasCustomImage(for: target, context: modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func receiveDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }) else {
            return false
        }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
            Task { @MainActor in
                if let error {
                    errorMessage = error.localizedDescription
                } else if let data {
                    setCustomImage(data)
                } else {
                    errorMessage = ImageStoreError.invalidImage.localizedDescription
                }
            }
        }
        return true
    }

    private func setCustomImage(_ data: Data) {
        do {
            try ImageStore.shared.setCustomImage(data: data, for: target, context: modelContext)
            hasCustomImage = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct EntityContextMenuItems: View {
    let target: ImageTarget
    let currentImageURL: String?
    let onFixAlbumMatch: (() -> Void)?
    let onOpen: (() -> Void)?
    let onImageRefreshed: ((String) -> Void)?
    let extraActions: [EntityContextAction]

    @Environment(\.modelContext) private var modelContext
    @Environment(LovedTracksStore.self) private var lovedTracksStore
    @Environment(FlaggedTracksStore.self) private var flaggedTracksStore
    @Environment(PopularityStore.self) private var popularityStore
    @Binding var hasCustomImage: Bool
    @Binding var errorMessage: String?
    @Binding var resyncMessage: String?
    @Binding var isResyncing: Bool
    @Binding var imageRefreshMessage: String?
    @Binding var isRefreshingImage: Bool

    var body: some View {
        if let onOpen {
            Button("Open", action: onOpen)
            Divider()
        }

        if !extraActions.isEmpty {
            ForEach(extraActions) { item in
                Button(item.title, role: item.isDestructive ? .destructive : nil, action: item.action)
            }
            Divider()
        }

        if target.kind == .track, let track = target.track,
           LastfmCredentialsStore.load()?.sessionKey != nil {
            Button(isLoved(track: track) ? "Unlove Track" : "Love Track") {
                toggleLove(track: track)
            }
            .disabled(Connectivity.shared.isOffline)
            Divider()
        }

        if target.kind == .track, let track = target.track {
            Button(isFlagged(track: track) ? "Unflag Track" : "Flag Track") {
                toggleFlag(track: track)
            }
            Divider()
        }

        if target.kind == .album, let onFixAlbumMatch {
            Button("Fix Album Match…", action: onFixAlbumMatch)
            Divider()
        }

        if LastfmCredentialsStore.load() != nil {
            Button(resyncLabel, action: resync)
                .disabled(isResyncing || Connectivity.shared.isOffline)
            Divider()
        }

        Button(isRefreshingImage ? "Refreshing Image…" : "Refresh Image", action: refreshImage)
            .disabled(isRefreshingImage || Connectivity.shared.isOffline)
        Divider()

        Button("Copy Image", action: copyImage)
            .disabled(currentImageURL == nil)

        Button("Paste Image", action: pasteImage)
            .disabled(!ImageStore.shared.hasImageOnPasteboard())

        Button("Set Custom Image…", action: chooseCustomImage)

        if hasCustomImage {
            Button("Reset to Detected", action: resetToDetected)
        }

        if target.kind == .track, let track = target.track {
            Divider()
            Button("View Lyrics on Genius") {
                openGeniusLyrics(track: track)
            }
        }

        Divider()
        Button("View in Apple Music") {
            let target = target
            Task { await AppleMusicLinks.open(kind: target.kind, artist: target.artist, album: target.album, track: target.track) }
        }
        .disabled(Connectivity.shared.isOffline)
        .help(Connectivity.shared.isOffline ? "Offline mode is on. Go online to open this in Apple Music." : "Opens this \(target.kind.rawValue)’s page in the Music app")

        if let username = LastfmCredentialsStore.load()?.username {
            Button("View in Last.fm") {
                openLastfm(username: username)
            }
        }
    }

    private func toggleLove(track: String) {
        let currentlyLoved = isLoved(track: track)
        Task {
            do {
                try await LovedTracksEngine.toggle(
                    context: modelContext,
                    artist: target.artist,
                    track: track,
                    loved: currentlyLoved
                )
                lovedTracksStore.setLoved(!currentlyLoved, artist: target.artist, track: track)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func isLoved(track: String) -> Bool {
        LovedTracksEngine.isLoved(
            context: modelContext,
            artist: target.artist,
            track: track
        )
    }

    private func isFlagged(track: String) -> Bool {
        flaggedTracksStore.isFlagged(artist: target.artist, track: track, album: target.album)
    }

    private func toggleFlag(track: String) {
        do {
            try flaggedTracksStore.toggle(context: modelContext, artist: target.artist, track: track, album: target.album)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var resyncLabel: String {
        switch target.kind {
        case .artist: "Resync This Artist"
        case .album: "Resync This Album"
        case .track: "Resync This Track"
        }
    }

    private func resync() {
        guard let credentials = LastfmCredentialsStore.load() else { return }
        let scope: TargetedSyncScope
        switch target.kind {
        case .artist: scope = .artist
        case .album: scope = .album
        case .track: scope = .track
        }

        isResyncing = true
        let activity = TargetedSyncActivity(id: UUID(), title: targetedSyncTitle)
        NotificationCenter.default.post(name: .targetedSyncDidStart, object: activity)
        Task {
            defer {
                isResyncing = false
                NotificationCenter.default.post(name: .targetedSyncDidFinish, object: activity)
            }
            do {
                let engine = SyncEngine(modelContainer: modelContext.container)
                let summary = try await offMain(priority: .userInitiated) {
                    try await engine.resync(
                        credentials: credentials,
                        scope: scope,
                        artist: target.artist,
                        album: target.album,
                        track: target.track
                    )
                }
                popularityStore.refresh(popularityLookups)
                let changes = summary.added + summary.updated + summary.removed
                if changes == 0 {
                    resyncMessage = summary.isComplete
                        ? "This item is already up to date."
                        : "The most recent matching plays are up to date. The scan was limited because this item has a very large history."
                } else {
                    var parts: [String] = []
                    if summary.added > 0 { parts.append("\(summary.added) added") }
                    if summary.updated > 0 { parts.append("\(summary.updated) updated") }
                    if summary.removed > 0 { parts.append("\(summary.removed) removed") }
                    let suffix = summary.isComplete ? "." : ". The scan was limited to the most recent matching plays."
                    resyncMessage = parts.joined(separator: ", ").capitalized + suffix
                }
                if changes > 0 {
                    NotificationCenter.default.post(name: .scrobbleSyncDidComplete, object: summary)
                }
            } catch {
                errorMessage = "Resync failed: \(error.localizedDescription)"
            }
        }
    }

    /// The Resync action also re-fetches popularity for the resynced scope:
    /// the artist, plus the album
    /// and/or track when the scope names one.
    private var popularityLookups: [PopularityLookup] {
        var lookups: [PopularityLookup] = [.artist(target.artist)]
        if let album = target.album, target.kind != .artist {
            lookups.append(.album(artist: target.artist, name: album))
        }
        if target.kind == .track, let track = target.track {
            lookups.append(.track(artist: target.artist, name: track))
        }
        return lookups
    }

    private var targetedSyncTitle: String {
        switch target.kind {
        case .artist:
            "Resyncing artist “\(target.artist)”…"
        case .album:
            "Resyncing album “\(target.album ?? target.artist)”…"
        case .track:
            "Resyncing track “\(target.track ?? target.artist)”…"
        }
    }

    private func refreshImage() {
        guard !hasCustomImage else {
            imageRefreshMessage = "This item uses custom artwork. Choose Reset to Detected before refreshing its automatically detected image."
            return
        }

        isRefreshingImage = true
        Task {
            defer { isRefreshingImage = false }
            do {
                let refreshedURL = try await ImageResolutionEngine.resolve(
                    target: target,
                    context: modelContext,
                    deezer: DeezerAPIClient(),
                    force: true
                )
                guard let refreshedURL,
                      let url = URL(string: refreshedURL),
                      let image = NSImage(contentsOf: url),
                      image.isValid else {
                    throw ImageStoreError.invalidImage
                }

                // Album-backed track refreshes save and notify as an album first.
                // Notify again with the originally displayed target only after the
                // persisted file has been decoded successfully, so detail headers
                // and rows reload at the correct identity and point in the task.
                onImageRefreshed?(refreshedURL)
                NotificationCenter.default.post(name: .imageDidChange, object: target)
                imageRefreshMessage = "The artwork was downloaded again and loaded successfully."
            } catch {
                errorMessage = "Image refresh failed: \(error.localizedDescription)"
            }
        }
    }

    private func copyImage() {
        Task {
            do {
                try await ImageStore.shared.copyImage(at: currentImageURL)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func pasteImage() {
        do {
            let data = try ImageStore.shared.imageDataOnPasteboard()
            try ImageStore.shared.setCustomImage(data: data, for: target, context: modelContext)
            hasCustomImage = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func chooseCustomImage() {
        let panel = NSOpenPanel()
        panel.title = "Choose Image"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ImageStore.shared.setCustomImage(data: Data(contentsOf: url), for: target, context: modelContext)
            hasCustomImage = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func resetToDetected() {
        do {
            try ImageStore.shared.clearCustomImage(for: target, context: modelContext)
            hasCustomImage = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func openGeniusLyrics(track: String) {
        let query = "\(target.artist) \(track)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "https://genius.com/search?q=\(query)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openLastfm(username: String) {
        var parts = [
            lastfmURLSegment(username),
            "library",
            "music",
            lastfmURLSegment(target.artist),
        ]
        if let track = target.track, !track.isEmpty {
            let album = target.album.flatMap { $0.isEmpty ? nil : $0 }
            parts.append(album.map(lastfmURLSegment) ?? "_")
            parts.append(lastfmURLSegment(track))
        } else if let album = target.album, !album.isEmpty {
            parts.append(lastfmURLSegment(album))
        }

        if let url = URL(string: "https://www.last.fm/user/\(parts.joined(separator: "/"))") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Last.fm library routes use form-style spaces (`+`) within individually
    /// encoded path segments. Encoding each segment also prevents artist,
    /// album, or track punctuation from changing the route structure.
    private func lastfmURLSegment(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .addingPercentEncoding(withAllowedCharacters: allowed)?
            .replacingOccurrences(of: "%20", with: "+") ?? ""
    }
}

extension View {
    func entityContextMenu(
        target: ImageTarget,
        currentImageURL: String? = nil,
        onFixAlbumMatch: (() -> Void)? = nil,
        onOpen: (() -> Void)? = nil,
        onImageRefreshed: ((String) -> Void)? = nil,
        extraActions: [EntityContextAction] = []
    ) -> some View {
        modifier(EntityContextMenuModifier(
            target: target,
            currentImageURL: currentImageURL,
            onFixAlbumMatch: onFixAlbumMatch,
            onOpen: onOpen,
            onImageRefreshed: onImageRefreshed,
            extraActions: extraActions
        ))
    }
}
