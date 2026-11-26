import AppKit
import SwiftData
import SwiftUI

/// The strip under the toolbar that says it's time to back up. It also hosts the quiet task that makes the automatic backup (when
/// that is on) and works out whether a reminder is due, a little after launch and then every few hours.
struct BackupReminderStrip: View {
    let container: ModelContainer
    @State private var scheduler = BackupScheduler.shared

    var body: some View {
        VStack(spacing: 0) {
            // A task needs something to hang on even when no strip is showing.
            Color.clear.frame(height: 0).task {
                #if DEBUG
                // A run on a scratch or copied store (the headless checks) must not write backups or save settings.
                if ProcessInfo.processInfo.environment["SCROBLYTICS_STORE_PATH"] != nil { return }
                #endif
                await scheduler.runLoop(container: container)
            }
            if let reminder = scheduler.reminder {
                BackupReminderLine(
                    reminder: reminder,
                    onBackUp: { Task { await scheduler.backUpNow(context: container.mainContext) } },
                    onLater: { scheduler.snooze() },
                    onTurnOff: { scheduler.turnOffReminders() }
                )
            }
        }
    }
}

/// The strip's content, separate so it can be shown without a store (layout checks).
struct BackupReminderLine: View {
    let reminder: BackupReminder
    let onBackUp: () -> Void
    let onLater: () -> Void
    let onTurnOff: () -> Void

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

    private var isFailure: Bool {
        if case .automaticFailed = reminder { return true }
        return false
    }

    private var message: some View {
        Label {
            Text(reminder.text).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: isFailure ? "exclamationmark.triangle.fill" : "externaldrive.badge.timemachine")
                .foregroundStyle(isFailure ? Color.orange : Color.accentColor)
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button("Back Up Now", action: onBackUp).buttonStyle(.link)
                .help("Saves a backup of what you created in Scroblytics (not your listening history, which comes back by syncing).")
            if isFailure {
                SettingsLink { Text("Settings") }.buttonStyle(.link)
                    .help("Opens Settings, where the automatic backup folder can be changed.")
            }
            Button("Remind Me in a Week", action: onLater).buttonStyle(.link)
            if !isFailure {
                Button("Turn Off Reminders", action: onTurnOff).buttonStyle(.link)
                    .help("Stops these reminders. You can turn them on again in Settings.")
            }
        }
    }
}

/// Settings › General › Backup: when the last backup was made, a Back Up Now button, the reminder, the optional automatic backup,
/// and the safety copies kept before an update.
struct BackupSettingsSection: View {
    @Environment(\.modelContext) private var context
    @State private var scheduler: BackupScheduler
    @State private var copies: [(url: URL, modified: Date, bytes: Int64)] = []
    @State private var confirmsDelete = false
    @State private var newestAutomatic: (modified: Date, bytes: Int64)?

    init(scheduler: BackupScheduler = .shared) { _scheduler = State(initialValue: scheduler) }

    static var safetyFolder: URL { StoreSafetyCopy.folder(in: StoreLocation.url().deletingLastPathComponent()) }

    var body: some View {
        Group {
            backupSection
            safetyCopySection
        }
        .onAppear { reloadCopies(); reloadNewestAutomatic() }
        .onChange(of: scheduler.lastBackupAt) { reloadNewestAutomatic() }
        .onChange(of: scheduler.folderPath) { reloadNewestAutomatic() }
    }

    private var backupSection: some View {
        Section("Backup") {
            Text(lastBackupText)
                .font(AppTypography.supporting)
                .foregroundStyle(.secondary)
            HStack {
                Button("Back Up Now…") { Task { await scheduler.backUpNow(context: context) } }
                    .disabled(scheduler.isWorking)
                HelpLinkButton(articleID: "data-backup", title: "What a backup contains")
                Spacer()
                if scheduler.isWorking { ProgressView().controlSize(.small) }
            }
            if let message = scheduler.message {
                Text(message).font(AppTypography.supporting).foregroundStyle(.secondary)
            }

            Toggle("Remind me when it’s been a while", isOn: $scheduler.remindersOn)
            Text("A line under the toolbar appears when you’ve created something worth keeping and your last backup is over a month old (or two weeks after you first create something, if you’ve never backed up).")
                .font(AppTypography.supporting)
                .foregroundStyle(.secondary)

            Toggle("Back up automatically every week", isOn: Binding(
                get: { scheduler.automaticOn },
                set: { scheduler.setAutomatic($0) }
            ))
            Text("Writes a dated backup file into a folder you choose, only when something has changed since the last one, and keeps the newest three it made (it never touches other files). Backups include your custom pictures, so they can be large. Choose a folder that is itself backed up or on another disk, such as iCloud Drive or an external drive. Nothing is sent anywhere by Scroblytics.")
                .font(AppTypography.supporting)
                .foregroundStyle(.secondary)
            if scheduler.automaticOn || scheduler.folderPath != nil {
                HStack {
                    Text(scheduler.folderPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "No folder chosen")
                        .font(AppTypography.supporting)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose Folder…") { scheduler.chooseFolder() }
                    if let folder = scheduler.folderURL {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    }
                }
            }
            if let newest = newestAutomatic {
                Text("Newest in that folder: \(newest.modified.formatted(date: .abbreviated, time: .shortened)), \(ByteCountFormatter.string(fromByteCount: newest.bytes, countStyle: .file)). Up to three are kept.")
                    .font(AppTypography.supporting)
                    .foregroundStyle(.secondary)
            }
            if let error = scheduler.automaticError, scheduler.automaticOn {
                Label("Automatic backup couldn’t run: \(error)", systemImage: "exclamationmark.triangle.fill")
                    .font(AppTypography.supporting)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var safetyCopySection: some View {
        Section("Safety copies before updates") {
            safetyCopyRows
        }
    }

    @ViewBuilder
    private var safetyCopyRows: some View {
        Text("Before the first launch of a new version, Scroblytics saves a full copy of its database (your listening history too) and keeps it for two weeks, never fewer than the two newest. If an update ever goes wrong, quit Scroblytics and put a copy back as Scroblytics.store in its folder in Application Support.")
            .font(AppTypography.supporting)
            .foregroundStyle(.secondary)
        HStack {
            Text(safetyCopyText)
                .font(AppTypography.supporting)
            Spacer()
            Button("Show in Finder") {
                let folder = Self.safetyFolder
                if let newest = copies.first?.url {
                    NSWorkspace.shared.activateFileViewerSelecting([newest])
                } else if FileManager.default.fileExists(atPath: folder.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
            }
            .disabled(copies.isEmpty)
            Button("Delete Safety Copies…") { confirmsDelete = true }
                .disabled(copies.isEmpty)
        }
        .confirmationDialog("Delete the safety copies?", isPresented: $confirmsDelete) {
            Button("Delete \(copies.count) Safety \(copies.count == 1 ? "Copy" : "Copies")", role: .destructive) {
                StoreSafetyCopy.deleteAll(in: Self.safetyFolder)
                reloadCopies()
            }
        } message: {
            Text("These are copies of your database made before updates. Deleting them can’t be undone; the database Scroblytics is using isn’t touched.")
        }
    }

    private func reloadNewestAutomatic() {
        newestAutomatic = scheduler.folderURL.flatMap { AutomaticBackupEngine.files(in: $0).first }.map { ($0.modified, $0.bytes) }
    }

    private func reloadCopies() {
        copies = StoreSafetyCopy.copies(in: Self.safetyFolder)
    }

    private var lastBackupText: String {
        guard let last = scheduler.lastBackupAt else { return "You haven’t made a backup yet." }
        let how = scheduler.lastKind == "automatic" ? "automatic" : "by you"
        return "Last backup: \(last.formatted(date: .abbreviated, time: .shortened)) (\(how))."
    }

    private var safetyCopyText: String {
        guard let newest = copies.first else { return "No safety copy yet." }
        let bytes = copies.reduce(Int64(0)) { $0 + $1.bytes }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return "\(copies.count) safety \(copies.count == 1 ? "copy" : "copies"), newest \(newest.modified.formatted(date: .abbreviated, time: .shortened)), \(size) in all."
    }
}
