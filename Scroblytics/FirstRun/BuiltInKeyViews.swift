import SwiftUI

/// "Use built-in key": moves a saved account from the person's own Last.fm key to the key built into the app (keeping the username and
/// every bit of data) and carries on. Shown beside a failure caused by a refused key.
struct UseBuiltInKeyButton: View {
    let onResume: () -> Void

    var body: some View {
        Button("Use built-in key") {
            if (try? LastfmKeyMode.switchToBuiltIn()) != nil { onResume() }
        }
        .help("Switch to the key built into Scroblytics. Your username, history and everything else stay as they are; Track Actions need approving once more.")
    }
}

/// Offered once to everyone who is on their own Last.fm key: Scroblytics now has its own, so theirs (and the Last.fm Pro it needs) is
/// no longer required. One click moves them; nothing changes unless they click, and "Not now" is remembered.
struct BuiltInKeyOfferStrip: View {
    @Environment(HistoryStatus.self) private var history: HistoryStatus?
    @AppStorage("lastfm.builtInKeyOfferDismissed") private var dismissed = false
    @State private var failed = false

    var body: some View {
        if let history, history.hasAccount, history.usesOwnKey, LastfmBuiltInKey.isAvailable, !dismissed {
            HStack(spacing: 10) {
                Image(systemName: "key.fill").foregroundStyle(.tint)
                Text(failed
                     ? "Couldn’t switch the key. You can try again in Settings › Sync."
                     : "Scroblytics now has its own Last.fm key, so yours (and the Last.fm Pro it needs) isn’t required any more. Switching keeps all your data.")
                    .fixedSize(horizontal: false, vertical: true)
                    .help("If you use Track Actions (loving tracks, editing tags, scrobbling), Last.fm asks you to approve them once more after the switch.")
                Spacer(minLength: 12)
                Button("Switch") {
                    do { try LastfmKeyMode.switchToBuiltIn() } catch { failed = true }
                }
                Button("Not now") { dismissed = true }
            }
            .font(.callout)
            .padding(.horizontal, 16).padding(.vertical, 6)
            .background(.regularMaterial)
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}
