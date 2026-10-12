import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Opening Mail or the issue tracker, only when the person presses the button. Nothing is sent by the app: it hands the text to
/// the Mail app (or the clipboard) and the person sends it.
enum ReportMailer {
    enum Outcome: Equatable {
        case draftOpened
        case copiedAndOpenedMail
    }

    static func subject(version: String, build: String) -> String { "Scroblytics \(version) (\(build)) problem report" }

    /// A Mail draft addressed to the project, with the summary as its text and, if given, a crash report attached. When Mail's
    /// compose sheet isn't available, the summary goes on the clipboard and a plain `mailto:` opens with only the address and subject.
    @MainActor
    static func compose(summary: String, subject: String, attachment: URL?) -> Outcome {
        var items: [Any] = [summary]
        if let attachment { items.append(attachment) }
        if let service = NSSharingService(named: .composeEmail) {
            service.recipients = [AppIdentity.supportEmail]
            service.subject = subject
            if service.canPerform(withItems: items) {
                service.perform(withItems: items)
                return .draftOpened
            }
        }
        copy(summary)
        var parts = URLComponents()
        parts.scheme = "mailto"
        parts.path = AppIdentity.supportEmail
        parts.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: "Paste the diagnostic summary here (it is on your clipboard)."),
        ]
        if let url = parts.url { NSWorkspace.shared.open(url) }
        return .copiedAndOpenedMail
    }

    @MainActor
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The summary goes on the clipboard (no data in the address) and the issue page opens.
    @MainActor
    static func openIssue(summary: String) {
        copy(summary)
        NSWorkspace.shared.open(AppIdentity.issuesURL)
    }
}

/// Help › Report a Problem…: the crash reports macOS has kept, a summary of what the app knows, and ways to send it, every one a
/// button the person presses. Nothing is sent or uploaded by the app.
struct ReportProblemView: View {
    let modelContainer: ModelContainer
    @State private var summary = ""
    @State private var reports: [CrashReportFile] = []
    @State private var isLoading = true
    @State private var attachReport = true
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Report a Problem").font(.title2.bold())
            Text("Scroblytics sends nothing by itself. This window puts together a summary of what the app knows, and what to send is up to you: read it first, then copy it, save it, or start an email. It holds no Last.fm name, keys or music.")
                .font(AppTypography.supporting).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            GroupBox("Crash reports") {
                VStack(alignment: .leading, spacing: 8) {
                    if reports.isEmpty {
                        Text("None found. macOS writes one when an app quits unexpectedly.")
                            .font(AppTypography.supporting).foregroundStyle(.secondary)
                    } else {
                        ForEach(reports) { report in
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(report.name).font(.callout).lineLimit(1).truncationMode(.middle)
                                    Text(report.date.formatted(date: .abbreviated, time: .shortened)).font(AppTypography.supporting).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Show in Finder") { CrashReports.reveal(report) }
                                    .help("Opens a Finder window with this report selected, ready to attach to an email.")
                            }
                        }
                        Text("A crash report names your Mac account in its file paths. Send it by email rather than posting it publicly.")
                            .font(AppTypography.supporting).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }

            GroupBox("Diagnostic summary") {
                VStack(alignment: .leading, spacing: 8) {
                    ScrollView {
                        Text(isLoading ? "Gathering…" : summary)
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                    .frame(minHeight: 170)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    HStack {
                        Button("Copy") { ReportMailer.copy(summary); status = "Copied to the clipboard." }.disabled(isLoading)
                        Button("Save…", action: save).disabled(isLoading)
                        Button("Refresh") { Task { await refresh() } }.disabled(isLoading)
                        Spacer()
                        Button("Clear Activity Log", role: .destructive) {
                            ActivityLog.shared.clear()
                            ActivityLog.record(.app, "Activity log cleared by the user")
                            Task { await refresh(); status = "The activity log was cleared." }
                        }
                        .help("Deletes the small log of what the app did. It is rebuilt as you use the app.")
                    }
                }
                .padding(6)
            }

            if !reports.isEmpty {
                Toggle("Attach the newest crash report to the email", isOn: $attachReport)
                    .font(AppTypography.supporting)
            }
            HStack {
                Button("Email…") { sendEmail() }.disabled(isLoading).keyboardShortcut(.defaultAction)
                    .help("Opens a Mail draft to \(AppIdentity.supportEmail) with the summary. You choose whether to send it.")
                Button("Open GitHub Issue…") { ReportMailer.openIssue(summary: summary); status = "The summary is on your clipboard. Paste it into the issue; issues are public." }
                    .disabled(isLoading)
                    .help("Copies the summary and opens the issue page in your browser. Issues are public, so leave crash reports for email.")
                Spacer()
                if let status { Text(status).font(AppTypography.supporting).foregroundStyle(.secondary).lineLimit(2) }
            }
        }
        .padding(20)
        .frame(minWidth: 540, minHeight: 600)
        .task { await refresh() }
    }

    private func refresh() async {
        isLoading = true
        let gathered = await DiagnosticSummary.gather(container: modelContainer)
        summary = gathered.text
        reports = gathered.inputs.crashReports
        isLoading = false
    }

    private func sendEmail() {
        let info = Bundle.main.infoDictionary
        let subject = ReportMailer.subject(version: info?["CFBundleShortVersionString"] as? String ?? "?", build: info?["CFBundleVersion"] as? String ?? "?")
        let outcome = ReportMailer.compose(summary: summary, subject: subject, attachment: attachReport ? reports.first?.url : nil)
        status = outcome == .draftOpened ? "A Mail draft is open. Nothing is sent until you press Send." : "The summary is on your clipboard; paste it into the email."
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Scroblytics problem report.txt"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try summary.write(to: url, atomically: true, encoding: .utf8)
            status = "Saved."
        } catch {
            status = "Couldn’t save the file: \(error.localizedDescription)"
        }
    }
}

/// The one-line notice under the toolbar after the app quit unexpectedly.
struct CrashNoticeStrip: View {
    private let store = CrashNoticeStore.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if store.pending != nil {
            CrashNoticeLine(onReport: { openWindow(id: "report-problem"); store.dismiss() }, onDismiss: { store.dismiss() })
        }
    }
}

/// The strip's content, separate so it can be shown without a store (layout checks).
struct CrashNoticeLine: View {
    let onReport: () -> Void
    let onDismiss: () -> Void

    var body: some View {
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
            Text("Scroblytics quit unexpectedly last time.").foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button("Report a Problem…", action: onReport).buttonStyle(.link)
                .help("Opens a window that gathers a summary and the crash report. Nothing is sent unless you choose to.")
            Button(action: onDismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Hide this")
        }
    }
}

/// Settings › General › Support.
struct SupportSettingsSection: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Section("Support") {
            Text("If something goes wrong, Scroblytics can gather a summary and the latest crash report for you to send. It sends nothing by itself.")
                .font(AppTypography.supporting)
                .foregroundStyle(.secondary)
            HStack {
                Button("Report a Problem…") { openWindow(id: "report-problem") }
                HelpLinkButton(articleID: "report-a-problem", title: "How reporting works")
            }
        }
    }
}
