import SwiftUI

/// The strip under the toolbar that says a newer version exists. It also runs the quiet daily check when the window appears.
struct UpdateStrip: View {
    private let store = UpdateStore.shared

    var body: some View {
        VStack(spacing: 0) {
            // A task needs something to hang on even when no strip is showing.
            // Not at the very first moment: the app has more important things to do while it opens (and a short run of the app,
            // as the headless checks make, never touches the network or the saved settings).
            Color.clear.frame(height: 0).task {
                #if DEBUG
                // A run on a scratch or copied store (the headless checks) must not reach the network or save settings.
                if ProcessInfo.processInfo.environment["SCROBLYTICS_STORE_PATH"] != nil { return }
                #endif
                try? await Task.sleep(for: .seconds(8))
                await store.checkAutomaticallyIfDue()
            }
            if let release = store.announced {
                UpdateStripLine(current: store.current, release: release,
                                onView: { store.viewRelease(release) }, onSkip: { store.skip(release) }, onDismiss: { store.dismissForNow() })
            }
        }
    }
}

/// The strip's content, separate so it can be shown without a store (layout checks).
struct UpdateStripLine: View {
    let current: AppVersion
    let release: ReleaseInfo
    let onView: () -> Void
    let onSkip: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        // One line when it fits; otherwise the buttons drop beneath the sentence.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { message.fixedSize(horizontal: true, vertical: false); Spacer(minLength: 12); actions }
            VStack(alignment: .leading, spacing: 4) { message.fixedSize(horizontal: false, vertical: true); actions }
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var message: some View {
        Label {
            Text("Scroblytics \(release.version.description) is available (you have \(current.description)).")
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "arrow.down.circle").foregroundStyle(Color.accentColor)
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button("View Release", action: onView).buttonStyle(.link)
                .help("Opens the release page in your browser. Nothing is downloaded or installed by the app.")
            Button("Skip This Version", action: onSkip).buttonStyle(.link)
                .help("Stops announcing this version. A newer one will still be announced.")
            Button(action: onDismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Hide this until the next launch")
        }
    }
}

/// Settings › General › Updates.
struct UpdateSettingsSection: View {
    @State private var store = UpdateStore.shared
    @State private var lastResult: String?

    var body: some View {
        Section("Updates") {
            Toggle("Check for updates automatically", isOn: $store.automaticChecks)
            Text("Once a day Scroblytics asks GitHub whether a newer version has been released, and tells you if so. It sends only the app’s name and version, as any web request does, and never downloads or installs anything. Offline mode stops it.")
                .font(AppTypography.supporting)
                .foregroundStyle(.secondary)
            HStack {
                Button("Check Now") {
                    Task {
                        switch await store.checkNow() {
                        case .upToDate: lastResult = "You’re up to date (\(store.current))."
                        case .available(let release): lastResult = "Version \(release.version) is available."
                        case .offline: lastResult = "Offline mode is on."
                        case .failed(let reason): lastResult = reason
                        }
                    }
                }
                .disabled(store.isChecking)
                if store.isChecking { ProgressView().controlSize(.small) }
                Spacer()
                Text(statusText).font(AppTypography.supporting).foregroundStyle(.secondary)
            }
        }
    }

    private var statusText: String {
        if let lastResult { return lastResult }
        if let last = store.lastCheckedAt { return "Last checked \(last.formatted(date: .abbreviated, time: .shortened))." }
        return "Not checked yet."
    }
}
