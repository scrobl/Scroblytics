import SwiftData
import SwiftUI

extension Notification.Name {
    /// A sync finished with a difference between Last.fm's total and what it found that checking the recent days could not settle.
    /// `object` is a `PendingRecheck`.
    static let syncRecheckPending = Notification.Name("SyncRecheckPending")
}

enum SyncRecheckStore {
    /// "Ignore": Last.fm's total as seen is taken as the baseline, so the difference is no longer asked about (until a full resync, which
    /// reads everything again, settles it).
    @MainActor
    static func ignore(_ pending: PendingRecheck, container: ModelContainer) {
        let context = container.mainContext
        guard let state = try? context.fetch(FetchDescriptor<SyncState>()).first else { return }
        state.remoteTotal = pending.remoteTotal
        try? context.save()
    }
}

/// Under the toolbar after a sync that could not account for a difference between Last.fm's play total and this Mac's: says how much it
/// differs and the likely reason, and offers a full check of the history (which can take many minutes), ignoring the difference, or
/// skipping it for now. Leaving it unanswered, or quitting, is the same as skipping: the next sync finds the same difference and asks again.
struct RecheckStrip: View {
    let container: ModelContainer
    let isSyncing: Bool
    let onCheckNow: () -> Void

    @State private var pending: PendingRecheck?
    init(container: ModelContainer, isSyncing: Bool, onCheckNow: @escaping () -> Void, pending: PendingRecheck? = nil) {
        self.container = container
        self.isSyncing = isSyncing
        self.onCheckNow = onCheckNow
        _pending = State(initialValue: pending)
    }
    #if DEBUG
    @State private var autoChoiceWaiting = false
    #endif

    var body: some View {
        VStack(spacing: 0) {
            if let pending, !isSyncing {
                // Side by side when there is room; the buttons drop below the text when there is not.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 10) {
                        icon
                        message(pending).frame(idealWidth: 560, maxWidth: .infinity, alignment: .leading)
                        buttons(pending)
                    }
                    HStack(alignment: .top, spacing: 10) {
                        icon
                        VStack(alignment: .leading, spacing: 8) {
                            message(pending)
                            buttons(pending)
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
        .onReceive(NotificationCenter.default.publisher(for: .syncRecheckPending)) { note in
            guard let found = note.object as? PendingRecheck else { return }
            pending = found
            #if DEBUG
            // The strip only shows once the sync has fully finished, so a scripted choice waits for that too.
            if isSyncing { autoChoiceWaiting = true } else { autoChoose(found) }
            #endif
        }
        #if DEBUG
        .onChange(of: isSyncing) { _, syncing in
            guard !syncing, autoChoiceWaiting, let found = pending else { return }
            autoChoiceWaiting = false
            autoChoose(found)
        }
        #endif
        // A new sync looks again: whatever is still unsettled is announced again when it ends.
        .onReceive(NotificationCenter.default.publisher(for: .scrobbleSyncDidStart)) { _ in pending = nil }
    }

    private var icon: some View {
        Image(systemName: "arrow.triangle.2.circlepath.circle.fill").foregroundStyle(.orange).padding(.top, 1)
    }

    private func message(_ pending: PendingRecheck) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(SyncRecheckPlan.explanation(pending))
            Text(SyncRecheckPlan.choices(remoteTotal: pending.remoteTotal)).foregroundStyle(.secondary).font(.caption)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func buttons(_ pending: PendingRecheck) -> some View {
        HStack(spacing: 8) {
            Button("Check now") { choose(.checkNow, pending) }
                .disabled(Connectivity.shared.isOffline)
                .help(Connectivity.shared.isOffline ? "Offline mode is on. Go online to check." : "Read your whole history from Last.fm and reconcile it")
            Button("Ignore") { choose(.ignore, pending) }
                .help("Keep things as they are. Last.fm’s total becomes the baseline until you run a Full Resync.")
            Button("Skip for now") { choose(.skip, pending) }
                .help("Ask again at the next sync")
        }
        .fixedSize()
    }

    private func choose(_ choice: RecheckChoice, _ found: PendingRecheck) {
        ActivityLog.record(.sync, SyncLogWording.choiceLine(choice, remoteTotal: found.remoteTotal))
        pending = nil
        switch choice {
        case .checkNow: onCheckNow()
        case .ignore: SyncRecheckStore.ignore(found, container: container)
        case .skip: break
        }
    }

    #if DEBUG
    /// With `SCROBLYTICS_RECHECK_CHOICE=now|ignore|skip`, presses that button a moment after the strip appears (for scripted runs);
    /// with anything else, or nothing, it is left unanswered.
    private func autoChoose(_ found: PendingRecheck) {
        guard let raw = ProcessInfo.processInfo.environment["SCROBLYTICS_RECHECK_CHOICE"] else { return }
        let choice: RecheckChoice?
        switch raw {
        case "now": choice = .checkNow
        case "ignore": choice = .ignore
        case "skip": choice = .skip
        default: choice = nil
        }
        guard let choice else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard pending == found else { return }
            choose(choice, found)
        }
    }
    #endif
}
