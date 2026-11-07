import SwiftUI

/// The words of the scrobbling warning, apart from the view so they can be checked.
enum ScrobblerWatchWording {
    /// "Music played 5 songs since Tuesday 3:12 PM that Last.fm didn’t get. Your scrobbler may have stopped."
    nonisolated static func headline(count: Int, since: Date?, now: Date = Date()) -> String {
        let songs = "\(count.formatted()) \(count == 1 ? "song" : "songs")"
        guard let since else { return "Music played \(songs) that Last.fm didn’t get. Your scrobbler may have stopped." }
        let recent = now.timeIntervalSince(since) < 6 * 86_400
        let when = recent ? since.formatted(.dateTime.weekday(.wide).hour().minute()) : since.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        return "Music played \(songs) since \(when) that Last.fm didn’t get. Your scrobbler may have stopped."
    }

    nonisolated static func detail(scrobblable: Int, count: Int) -> String {
        if scrobblable == 0 { return "Last.fm no longer takes plays this old, so none of them can be scrobbled now." }
        let which = scrobblable == count ? (count == 1 ? "It" : "All of them") : "\(scrobblable.formatted()) of them"
        return "\(which) can still be scrobbled: Last.fm takes plays from about the last 14 days."
    }
}

/// Under the toolbar when the scrobbling check (Settings › Sync) finds Music has played several songs Last.fm never got. Review opens
/// Unscrobbled Plays on the last 14 days; Dismiss keeps it away until things recover and the problem returns; Turn Off switches the check off.
struct ScrobblerWatchStrip: View {
    let onReview: () -> Void
    private let store = ScrobblerWatchStore.shared

    var body: some View {
        if store.isShowing, let verdict = store.verdict {
            ScrobblerWatchStripContent(
                count: verdict.count, since: verdict.firstMissed, scrobblable: verdict.stillScrobblable,
                onReview: onReview, onDismiss: { store.dismiss() }, onTurnOff: { store.turnOff() }
            )
        }
    }
}

struct ScrobblerWatchStripContent: View {
    let count: Int
    let since: Date?
    let scrobblable: Int
    let onReview: () -> Void
    let onDismiss: () -> Void
    let onTurnOff: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    icon
                    message.frame(idealWidth: 560, maxWidth: .infinity, alignment: .leading)
                    buttons
                }
                HStack(alignment: .top, spacing: 10) {
                    icon
                    VStack(alignment: .leading, spacing: 8) {
                        message
                        buttons
                    }
                    Spacer(minLength: 0)
                }
            }
            .font(.callout)
            .padding(.horizontal, 16).padding(.vertical, 6)
            .background(.regularMaterial)
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private var icon: some View {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).padding(.top, 1)
    }

    private var message: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ScrobblerWatchWording.headline(count: count, since: since))
            Text(ScrobblerWatchWording.detail(scrobblable: scrobblable, count: count)).foregroundStyle(.secondary).font(.caption)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Button("Review", action: onReview)
                .help("Open Unscrobbled Plays on the last 14 days")
            Button("Dismiss", action: onDismiss)
                .help("Hide this until scrobbling has recovered and the problem comes back")
            Button("Turn Off", action: onTurnOff)
                .help("Stop checking after each sync. You can turn it back on in Settings › Sync.")
        }
        .fixedSize()
    }
}

/// Settings › Sync › Scrobbling check: the switch (off until you turn it on), how many songs and how many days, and Check Now.
struct ScrobblerWatchSettingsSection: View {
    var store = ScrobblerWatchStore.shared

    var body: some View {
        Section("Scrobbling check") {
            Toggle("Warn me when Music plays aren’t being scrobbled", isOn: Binding(get: { store.settings.enabled }, set: { store.setEnabled($0) }))
            if store.settings.enabled {
                Stepper(value: Binding(get: { store.settings.threshold }, set: { store.setThreshold($0) }), in: ScrobblerWatch.thresholdRange) {
                    Text("Warn after \(store.settings.threshold) different \(store.settings.threshold == 1 ? "song" : "songs")")
                }
                Picker("Count plays from the last", selection: Binding(get: { store.settings.windowDays }, set: { store.setWindowDays($0) })) {
                    ForEach(ScrobblerWatch.windowChoices, id: \.self) { Text($0 == 1 ? "1 day" : "\($0) days").tag($0) }
                }
                HStack(alignment: .firstTextBaseline) {
                    Button("Check Now") { store.check(force: true) }.disabled(store.isChecking)
                    Text(store.statusText).font(AppTypography.supporting).foregroundStyle(store.problem == nil ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("After each sync, Scroblytics asks Music which songs it played in the last few days and compares them with your Last.fm history. If that many different songs are missing, a warning appears under the toolbar. It needs Music to be open and permission to control it (macOS asks the first time), looks only on this Mac, and sends no notifications.")
                .font(AppTypography.supporting).foregroundStyle(.secondary)
            HelpLinkButton(articleID: "tool-unscrobbled-plays", title: "About Unscrobbled Plays")
        }
    }
}
