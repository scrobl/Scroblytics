import SwiftUI
import SwiftData

extension Notification.Name {
    /// The Stop button (or a test) asked the running sync to stop. It keeps what it imported and can be resumed.
    static let syncStopRequested = Notification.Name("SyncStopRequested")
    /// A sync ended because it was stopped on purpose.
    static let scrobbleSyncDidStop = Notification.Name("ScrobbleSyncDidStop")
    /// The very first import ran to the end.
    static let firstImportDidFinish = Notification.Name("FirstImportDidFinish")
}

/// The slim strips under the sync bar: "Import paused" (with Resume) after a stop or an interruption, "Import
/// stopped" with the reason (and Retry, or Open Settings when the account needs fixing) when the first import fails,
/// and "Import complete" for a short while after the first one finishes.
struct ImportStatusStrips: View {
    let container: ModelContainer
    let isSyncing: Bool
    let onResume: () -> Void

    @Environment(HistoryStatus.self) private var history: HistoryStatus?

    private struct Done: Equatable { let scrobbles: Int; let sinceYear: Int? }

    @State private var done: Done?
    @State private var doneToken = UUID()

    var body: some View {
        VStack(spacing: 0) {
            if let history, !isSyncing {
                switch history.phase {
                case .paused:
                    strip(icon: "pause.circle.fill", tint: .orange) {
                        Text(history.hasCompletedSync
                            ? "Full resync paused. Everything imported so far is kept."
                            : history.scrobbleCount == 0
                            ? "Import paused before any scrobbles were imported."
                            : "Import paused after \(history.scrobbleCount.formatted()) \(history.scrobbleCount == 1 ? "scrobble" : "scrobbles"). Everything imported so far is kept.")
                    } trailing: {
                        Button("Resume", action: onResume)
                            .disabled(Connectivity.shared.isOffline)
                            .help(Connectivity.shared.isOffline ? "Offline mode is on. Go online to resume." : "Carry on from where it stopped")
                    }
                case .failed(let failure) where !history.hasCompletedSync:
                    strip(icon: "exclamationmark.triangle.fill", tint: .red) {
                        Text("Import stopped: \(failure.message) Everything imported so far is kept.")
                    } trailing: {
                        switch failure.kind {
                        case .retry:
                            Button("Retry", action: onResume).disabled(Connectivity.shared.isOffline)
                        case .fixAccount:
                            SettingsLink { Text("Open Settings") }
                        }
                    }
                default:
                    EmptyView()
                }
            }
            if let done {
                strip(icon: "checkmark.circle.fill", tint: .green) {
                    Text(Self.doneText(done))
                } trailing: {
                    Button("Dismiss") { self.done = nil }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .firstImportDidFinish)) { _ in showDone() }
    }

    private static func doneText(_ done: Done) -> String {
        if done.scrobbles == 0 {
            return "Import complete: this Last.fm account has no scrobbles yet. Anything you listen to will appear after the next sync."
        }
        let range = done.sinceYear.map { " from \($0) to today" } ?? ""
        return "Import complete: \(done.scrobbles.formatted()) scrobbles\(range). Artwork, tags and popularity fill in over the next hours."
    }

    private func strip<Content: View, Trailing: View>(
        icon: String, tint: Color, @ViewBuilder _ content: () -> Content, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            content()
            Spacer(minLength: 12)
            trailing()
        }
        .font(.callout)
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func showDone() {
        let context = container.mainContext
        let count = (try? context.fetchCount(FetchDescriptor<Scrobble>())) ?? 0
        var oldest = FetchDescriptor<Scrobble>(sortBy: [SortDescriptor(\.playedAt)])
        oldest.fetchLimit = 1
        let year = (try? context.fetch(oldest).first?.playedAt).map { Calendar.current.component(.year, from: $0) }
        done = Done(scrobbles: count, sinceYear: count > 0 ? year : nil)
        let token = UUID()
        doneToken = token
        Task {
            try? await Task.sleep(for: .seconds(20))
            if doneToken == token { done = nil }
        }
    }
}
