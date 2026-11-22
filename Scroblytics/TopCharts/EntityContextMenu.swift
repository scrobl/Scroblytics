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

/// A visible way into the menu, besides right-click. Every style shows the same items as right-click does, from one definition.
enum EntityMenuAffordance {
    /// Right-click only (what every screen had before).
    case none
    /// A small "…" badge in the top-right corner of what the menu belongs to: the same corner on every screen, so it is always
    /// where a person looks for it. Shown only while the pointer is over it (or it has keyboard focus), or always; VoiceOver can always
    /// reach it. `inset` is how far it sits in from the corner (more where the artwork is itself inset in a padded card).
    case corner(alwaysVisible: Bool = false, inset: CGFloat = 6)
    /// The view itself becomes a button that opens the menu (for a toolbar-style "…" beside other buttons).
    case menuButton

    /// Whether a corner badge should be showing: the pointer is over what it belongs to, or over the badge itself (which, once it is
    /// there, takes the pointer's tracking away from what is under it, so the two must count as one), or it has keyboard focus.
    static func isRevealed(pointerOverContent: Bool, pointerOverBadge: Bool, hasFocus: Bool) -> Bool {
        pointerOverContent || pointerOverBadge || hasFocus
    }

    /// Whether the badge is drawn right now: always, or while revealed.
    static func badgeIsVisible(alwaysVisible: Bool, revealed: Bool) -> Bool {
        alwaysVisible || revealed
    }

    /// How long after the pointer leaves both the tile and the badge it stays, so the hand-over between the two (during which neither
    /// reports the pointer for an instant) never makes it blink.
    static let hideDelay: Duration = .milliseconds(160)
}

/// Set by a tile whose artwork is only part of it (artwork beside text), so the "…" badge goes in the top-right corner of the artwork and
/// not of the whole tile. A tile that is all artwork says nothing and the badge goes in its own top-right corner.
struct EntityMenuArtworkWidthKey: PreferenceKey {
    static var defaultValue: CGFloat? { nil }
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = nextValue() ?? value }
}

extension View {
    /// Tells the "…" badge of the menu around this view how wide the artwork at its left edge is.
    func entityMenuArtworkWidth(_ width: CGFloat) -> some View {
        preference(key: EntityMenuArtworkWidthKey.self, value: width)
    }
}

enum EntityMenuBadgeGeometry {
    static let size: CGFloat = 22

    /// How far the badge sits in from the left edge of the tile: against the tile's right edge, or (for a tile whose artwork is
    /// `artworkWidth` wide at its left) against the artwork's right edge. Always `inset` from the top and from the edge.
    static func leadingOffset(tileWidth: CGFloat, artworkWidth: CGFloat?, inset: CGFloat) -> CGFloat {
        let edge = min(artworkWidth ?? tileWidth, tileWidth)
        return max(0, edge - size - inset)
    }
}

struct EntityContextMenuModifier: ViewModifier {
    let target: ImageTarget
    let currentImageURL: String?
    let onFixAlbumMatch: (() -> Void)?
    let onOpen: (() -> Void)?
    let onImageRefreshed: ((String) -> Void)?
    var extraActions: [EntityContextAction] = []
    var affordance: EntityMenuAffordance = .none

    @Environment(\.modelContext) private var modelContext
    @State private var hasCustomImage = false
    @State private var errorMessage: String?
    @State private var resyncMessage: String?
    @State private var isResyncing = false
    @State private var isRefreshingImage = false
    @State private var imageRefreshMessage: String?
    @State private var isPointerOver = false
    @State private var artworkWidth: CGFloat?
    @State private var tileWidth: CGFloat = 0
    @State private var isPointerOverBadge = false
    @State private var isRevealed = false
    @State private var hideTask: Task<Void, Never>?
    @State private var correctingSubject: NameCorrectionSubject?
    @FocusState private var badgeHasFocus: Bool

    /// The items, built once for right-click and for the "…" badge or button, so the two can never differ.
    private var menuItems: some View {
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
            isRefreshingImage: $isRefreshingImage,
            correctingSubject: $correctingSubject
        )
        .onAppear(perform: refreshState)
    }

    /// The "…" itself: it opens the same menu as right-click.
    private func badge(visible: Bool) -> some View {
        Menu { menuItems } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: EntityMenuBadgeGeometry.size, height: EntityMenuBadgeGeometry.size)
                .background(.black.opacity(0.62), in: Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .focused($badgeHasFocus)
        .onHover { isPointerOverBadge = $0 }
        .opacity(visible ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: visible)
        .accessibilityLabel("Actions for \(subject)")
        .help("Actions")
    }

    /// Shows the badge at once when the pointer (or focus) arrives, and hides it a moment after both have gone. It is never made
    /// untouchable while hidden: it sits where the pointer already is when it appears, and switching it off and on under the pointer made it flicker.
    private func updateReveal() {
        if EntityMenuAffordance.isRevealed(pointerOverContent: isPointerOver, pointerOverBadge: isPointerOverBadge, hasFocus: badgeHasFocus) {
            hideTask?.cancel()
            hideTask = nil
            isRevealed = true
        } else if isRevealed, hideTask == nil {
            hideTask = Task { @MainActor in
                try? await Task.sleep(for: EntityMenuAffordance.hideDelay)
                guard !Task.isCancelled else { return }
                isRevealed = false
                hideTask = nil
            }
        }
    }

    /// What the menu belongs to, for VoiceOver: "Actions for <track, album or artist>".
    private var subject: String { target.track ?? target.album ?? target.artist }

    @ViewBuilder
    private func presented(_ content: Content) -> some View {
        switch affordance {
        case .none:
            content
                .contextMenu { menuItems }
                .onDrop(of: [.image], isTargeted: nil, perform: receiveDrop)
        case .corner(let alwaysVisible, let inset):
            let visible = EntityMenuAffordance.badgeIsVisible(alwaysVisible: alwaysVisible, revealed: isRevealed)
            content
                .contextMenu { menuItems }
                .onDrop(of: [.image], isTargeted: nil, perform: receiveDrop)
                .onHover { isPointerOver = $0 }
                .onChange(of: isPointerOver) { updateReveal() }
                .onChange(of: isPointerOverBadge) { updateReveal() }
                .onChange(of: badgeHasFocus) { updateReveal() }
                .onPreferenceChange(EntityMenuArtworkWidthKey.self) { artworkWidth = $0 }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tileWidth = $0 }
                .overlay(alignment: .topLeading) {
                    badge(visible: visible)
                        .padding(.top, inset)
                        .padding(.leading, EntityMenuBadgeGeometry.leadingOffset(tileWidth: tileWidth, artworkWidth: artworkWidth, inset: inset))
                }
        case .menuButton:
            Menu { menuItems } label: { content }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Actions for \(subject)")
                .help("Actions")
        }
    }

    func body(content: Content) -> some View {
        presented(content)
            .sheet(item: $correctingSubject) { subject in NameCorrectionSheet(subject: subject) }
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
    @Binding var correctingSubject: NameCorrectionSubject?

    /// What "Correct Name…" is about, or nil where it doesn't apply (an album credited to "Various Artists" has no single artist to file it under).
    private var correctionSubject: NameCorrectionSubject? {
        switch target.kind {
        case .artist: return NameCorrectionSubject(kind: .artist, artist: target.artist, name: target.artist)
        case .album:
            guard let album = target.album, !album.isEmpty, !TextNormalization.isCompilationArtist(target.artist) else { return nil }
            return NameCorrectionSubject(kind: .album, artist: target.artist, name: album)
        case .track:
            guard let track = target.track, !track.isEmpty else { return nil }
            return NameCorrectionSubject(kind: .track, artist: target.artist, name: track)
        }
    }

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

        if let subject = correctionSubject {
            Button("Correct Name…") { correctingSubject = subject }
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
        extraActions: [EntityContextAction] = [],
        affordance: EntityMenuAffordance = .none
    ) -> some View {
        modifier(EntityContextMenuModifier(
            target: target,
            currentImageURL: currentImageURL,
            onFixAlbumMatch: onFixAlbumMatch,
            onOpen: onOpen,
            onImageRefreshed: onImageRefreshed,
            extraActions: extraActions,
            affordance: affordance
        ))
    }
}
