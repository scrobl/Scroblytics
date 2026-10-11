import SwiftUI
import SwiftData

/// Shows the welcome screen instead of the app's tabs while there is no Last.fm account and no history, and the app
/// itself otherwise. Which one is decided from what the app holds (`HistoryStatus`, which keeps itself current), never
/// from a stored flag, so it follows an account being added or removed. "Skip for now" lets someone into the empty app
/// for the rest of the session only. The status is made once, when the window first appears.
struct FirstRunGate<Content: View>: View {
    let modelContainer: ModelContainer
    @ViewBuilder let content: () -> Content

    @State private var history: HistoryStatus?
    @State private var skipped = false

    private var showsWelcome: Bool { history?.firstRunState == .noAccount && !skipped }

    var body: some View {
        Group {
            if let history {
                Group {
                    if showsWelcome {
                        WelcomeView(onSkip: { skipped = true })
                    } else {
                        content()
                    }
                }
                // Screens with nothing to show ask this why, and the import strips read the import's phase from it.
                .environment(history)
                #if DEBUG
                // A test profile reports what the window shows, so a scripted run can confirm it without a screenshot.
                .onChange(of: showsWelcome, initial: true) { _, shows in
                    if TestProfile.name != nil { FileHandle.standardError.write(Data("FIRSTRUN window=\(shows ? "welcome" : "app") state=\(history.firstRunState)\n".utf8)) }
                }
                #endif
            } else {
                Color.clear
            }
        }
        .task {
            if history == nil { history = HistoryStatus(container: modelContainer) }
        }
    }
}
