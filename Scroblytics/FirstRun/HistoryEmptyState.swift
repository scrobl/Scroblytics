import SwiftUI

/// What a screen shows when there is no history at all: the reason, in plain words, and the next step as a button.
/// When there is history (the screen is only empty for its own filter or range), the screen's own message is shown.
struct HistoryEmptyState<Fallback: View>: View {
    @Environment(HistoryStatus.self) private var history: HistoryStatus?
    @ViewBuilder let fallback: () -> Fallback

    var body: some View {
        if let reason = history?.emptyReason {
            content(for: reason)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
        } else {
            fallback()
        }
    }

    @ViewBuilder
    private func content(for reason: HistoryStatus.EmptyReason) -> some View {
        switch reason {
        case .noAccount:
            ContentUnavailableView {
                Label("Add your Last.fm account", systemImage: "person.crop.circle.badge.plus")
            } description: {
                Text("Scroblytics needs your Last.fm username and API key to import your listening history.")
            } actions: {
                SettingsLink { Text("Open Settings") }
            }
        case .importing:
            VStack(spacing: 12) {
                ProgressView()
                Text("Importing your history…").font(.title3.weight(.semibold))
                Text("This page fills in as your history arrives.").foregroundStyle(.secondary)
            }
        case .interrupted:
            ContentUnavailableView {
                Label("Import paused", systemImage: "pause.circle")
            } description: {
                Text("Nothing is lost. Resume to carry on importing your history.")
            } actions: {
                Button("Resume") { NotificationCenter.default.post(name: .syncRequested, object: nil) }
            }
        case .failed(let failure):
            ContentUnavailableView {
                Label("Import stopped", systemImage: "exclamationmark.triangle")
            } description: {
                Text(failure.message)
            } actions: {
                switch failure.kind {
                case .retry: Button("Retry") { NotificationCenter.default.post(name: .syncRequested, object: nil) }
                case .fixAccount: SettingsLink { Text("Open Settings") }
                }
            }
        case .accountHasNoScrobbles:
            ContentUnavailableView {
                Label("No scrobbles on this Last.fm account yet", systemImage: "music.note.list")
            } description: {
                Text("Once you’ve listened to something and Last.fm has scrobbled it, press Sync and it will show up here.")
            } actions: {
                Button("Sync") { NotificationCenter.default.post(name: .syncRequested, object: nil) }
            }
        }
    }
}

/// A slim note under a page's header while the first import is unfinished: the numbers below are not the whole picture.
struct PartialDataNoteBar: View {
    @Environment(HistoryStatus.self) private var history: HistoryStatus?

    var body: some View {
        if let history, history.isPartial {
            HStack(spacing: 8) {
                Image(systemName: "hourglass").foregroundStyle(.orange)
                Text("Your history isn’t fully imported yet (\(history.scrobbleCount.formatted()) scrobbles so far), so these numbers are partial.")
                Spacer(minLength: 0)
            }
            .font(.callout)
            .padding(.horizontal, 16).padding(.vertical, 6)
            .background(.regularMaterial)
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}

extension View {
    /// Shows `PartialDataNoteBar` at the top of the page while the first import is unfinished.
    func partialDataNote() -> some View {
        safeAreaInset(edge: .top, spacing: 0) { PartialDataNoteBar() }
    }
}
