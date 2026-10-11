import SwiftUI

/// A slim notice under the toolbar while Offline mode is on (and, once the Mac is connected again, a quiet nudge to go
/// back online). Same material and divider as the sync banner and the background-work strip.
struct OfflineStrip: View {
    var body: some View {
        let connectivity = Connectivity.shared
        if connectivity.isOffline {
            HStack(spacing: 8) {
                Image(systemName: connectivity.backOnlineHintVisible ? "wifi" : "wifi.slash")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                Text(connectivity.backOnlineHintVisible
                     ? "You’re back online. Offline mode is still on, so nothing is syncing."
                     : "Offline mode is on — syncing and online lookups are paused.")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button("Go Online") { connectivity.setOffline(false) }
                    .buttonStyle(.link)
                if connectivity.backOnlineHintVisible {
                    Button { connectivity.dismissBackOnlineHint() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Hide this reminder")
                }
            }
            .font(.caption)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .background(.regularMaterial)
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityElement(children: .combine)
        }
    }
}

extension View {
    /// The "can't reach the internet — switch to Offline mode?" question, shown once per burst of connection failures.
    func connectivityPrompt() -> some View {
        modifier(ConnectivityPromptModifier())
    }
}

private struct ConnectivityPromptModifier: ViewModifier {
    func body(content: Content) -> some View {
        let connectivity = Connectivity.shared
        content.alert(
            "Can’t reach the internet",
            isPresented: Binding(get: { connectivity.promptPending }, set: { if !$0 { connectivity.answerNotNow() } })
        ) {
            Button("Switch to Offline Mode") { connectivity.answerSwitchToOffline() }
            Button("Not Now", role: .cancel) { connectivity.answerNotNow() }
            Button("Don’t Ask Again This Session") { connectivity.answerDontAskAgain() }
        } message: {
            Text("Scroblytics couldn’t connect to the services it uses. Offline mode stops syncing and every online lookup, and keeps everything already on your Mac working. You can switch it on or off any time from the toolbar or the Library menu.")
        }
    }
}

/// The toolbar's Offline mode switch: dimmed wifi when online, an orange slashed wifi while offline.
struct OfflineToggleButton: View {
    var body: some View {
        let connectivity = Connectivity.shared
        Button {
            connectivity.toggle()
        } label: {
            Label(connectivity.isOffline ? "Go Online" : "Offline Mode", systemImage: connectivity.isOffline ? "wifi.slash" : "wifi")
        }
        .labelStyle(.iconOnly)
        .foregroundStyle(connectivity.isOffline ? Color.orange : Color.secondary)
        .help(connectivity.isOffline ? "Offline mode is on. Click to go online." : "Go offline: stop all network activity")
    }
}
