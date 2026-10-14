import SwiftUI

/// Which look the Artist, Album and Track detail pages use. The classic pages stay in the app unchanged; the new ones are chosen
/// here, so the choice can be flipped back at any time (Settings › General) and the new pages can be removed without touching
/// the classic ones. Anything unknown stored here reads as classic.
enum DetailPageStyle: String, CaseIterable, Identifiable, Sendable {
    case classic, new

    static let key = "detail.pages.style"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .classic: "Classic"
        case .new: "New (preview)"
        }
    }

    /// The style for a stored value; a DEBUG test can force one with `override` (the `SCROBLYTICS_DETAIL_STYLE` variable).
    static func resolve(stored: String?, override: String? = nil) -> DetailPageStyle {
        #if DEBUG
        if let override, let forced = DetailPageStyle(rawValue: override) { return forced }
        #endif
        return stored.flatMap(DetailPageStyle.init(rawValue:)) ?? .classic
    }

    static var current: DetailPageStyle {
        resolve(stored: UserDefaults.standard.string(forKey: key), override: ProcessInfo.processInfo.environment["SCROBLYTICS_DETAIL_STYLE"])
    }

    /// For a view that watches the stored value with `@AppStorage(DetailPageStyle.key)`.
    static func resolve(storedValue: String) -> DetailPageStyle {
        resolve(stored: storedValue, override: ProcessInfo.processInfo.environment["SCROBLYTICS_DETAIL_STYLE"])
    }
}

/// Settings › General: the switch between the classic and the new detail pages.
struct DetailPageStyleSettingsSection: View {
    @AppStorage(DetailPageStyle.key) private var style = DetailPageStyle.classic.rawValue

    var body: some View {
        Section("Detail pages") {
            Picker("Artist, album and track pages", selection: $style) {
                ForEach(DetailPageStyle.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)

            Text("A denser layout with the facts, tags and (for albums) the full tracklist together. It's a preview: switch back to Classic at any time, nothing about your data changes.")
                .font(AppTypography.supporting)
                .foregroundStyle(.secondary)
        }
    }
}

/// What the new detail pages show until each page is built: a way back and a note, so the switch can be tried safely.
struct DetailPagePlaceholder: View {
    let navigation: DetailNavigationCoordinator
    let artist: ArtistIdentity?
    let album: AlbumIdentity?
    let title: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DetailBreadcrumbBar(navigation: navigation, artist: artist, album: album, current: title)
                ContentUnavailableView(
                    "New layout in progress",
                    systemImage: "square.grid.2x2",
                    description: Text("This page isn't built yet. Switch back to Classic in Settings › General.")
                )
                .frame(maxWidth: .infinity, minHeight: 240)
            }
            .padding()
        }
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .navigationTitle(title)
    }
}
