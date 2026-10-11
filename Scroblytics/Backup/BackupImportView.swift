import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Native backup/restore and listening-history export.
struct BackupImportView: View {
    let modelContainer: ModelContainer
    var commandState: DataManagementCommandState? = nil

    @State private var errorMessage: String?
    @State private var isProcessing = false
    @State private var nativeDocument: NativeBackupDocument?
    @State private var isExporterPresented = false
    @State private var isNativeImporterPresented = false
    @State private var pendingRestore: NativeBackupFormat.Archive?
    @State private var pendingRestoreSummary: NativeBackupEngine.Summary?
    @State private var isRestoreConfirmationPresented = false
    @State private var statusMessage: String?
    @State private var historyDocument: ListeningHistoryCSVDocument?
    @State private var isHistoryExporterPresented = false
    @State private var processingMessage = "Reading backup…"
    @State private var handledRequest = 0

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Scroblytics backup") {
                    Text("Back up the data you create in this app: corrections, overrides, custom images, flagged tracks, saved queries, and preferences. Listening history and replaceable caches are restored through Last.fm sync instead.")
                        .font(AppTypography.supporting)
                        .foregroundStyle(.secondary)
                    HelpLinkButton(articleID: "data-backup", title: "What is and isn’t included")

                    HStack {
                        Button("Back Up…", systemImage: "square.and.arrow.up") { createNativeBackup() }
                            .disabled(isProcessing)
                        Button("Restore…", systemImage: "arrow.counterclockwise") { isNativeImporterPresented = true }
                            .disabled(isProcessing)
                    }
                }

                Section("Listening history") {
                    Text("Export every synced play as a portable CSV file. The export includes UTC and Unix timestamps so dates remain unambiguous in spreadsheets and other apps.")
                        .font(AppTypography.supporting)
                        .foregroundStyle(.secondary)

                    Button("Export History as CSV…", systemImage: "tablecells") { createHistoryExport() }
                        .disabled(isProcessing)
                }

                if let statusMessage {
                    Section { Label(statusMessage, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                }

                if isProcessing {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(processingMessage)
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(minHeight: 420, maxHeight: 560)
        .fileImporter(isPresented: $isNativeImporterPresented, allowedContentTypes: [.scroblyticsBackup, .json]) { result in
            switch result {
            case .success(let url): inspectNativeBackup(at: url)
            case .failure(let error): errorMessage = "Couldn't open that backup: \(error.localizedDescription)"
            }
        }
        .fileExporter(isPresented: $isExporterPresented, document: nativeDocument, contentType: .scroblyticsBackup, defaultFilename: nativeBackupFilename) { result in
            switch result {
            case .success: statusMessage = "Backup created."
            case .failure(let error): errorMessage = "Couldn't save the backup: \(error.localizedDescription)"
            }
            nativeDocument = nil
        }
        .fileExporter(isPresented: $isHistoryExporterPresented, document: historyDocument, contentType: .commaSeparatedText, defaultFilename: historyExportFilename) { result in
            switch result {
            case .success: statusMessage = "Listening history exported."
            case .failure(let error): errorMessage = "Couldn't save the CSV export: \(error.localizedDescription)"
            }
            historyDocument = nil
        }
        .alert("Restore this backup?", isPresented: $isRestoreConfirmationPresented) {
            Button("Cancel", role: .cancel) { pendingRestore = nil }
            Button("Restore", role: .destructive) { restoreNativeBackup() }
        } message: {
            Text("This replaces the app-created data covered by the backup. Your listening history and Last.fm connection are not changed.\n\n\(pendingRestoreSummary?.description ?? "")")
        }
        .onAppear { performRequestedAction() }
        .onChange(of: commandState?.request) { performRequestedAction() }
    }

    private func performRequestedAction() {
        guard let commandState, commandState.request != handledRequest else { return }
        handledRequest = commandState.request
        switch commandState.action {
        case .backup: createNativeBackup()
        case .restore: isNativeImporterPresented = true
        case .exportHistory: createHistoryExport()
        }
    }

    private var nativeBackupFilename: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "Scroblytics Backup \(formatter.string(from: Date())).scroblyticsbackup"
    }

    private var historyExportFilename: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "Scroblytics Listening History \(formatter.string(from: Date())).csv"
    }

    private func createHistoryExport() {
        errorMessage = nil
        statusMessage = nil
        processingMessage = "Preparing listening history…"
        isProcessing = true
        let exporter = ListeningHistoryCSVExporter(modelContainer: modelContainer)
        Task {
            do {
                historyDocument = try await offMain { try await exporter.makeDocument() }
                isHistoryExporterPresented = true
            } catch {
                errorMessage = "Couldn't create the CSV export: \(error.localizedDescription)"
            }
            isProcessing = false
        }
    }

    private func createNativeBackup() {
        errorMessage = nil
        statusMessage = nil
        processingMessage = "Preparing backup…"
        isProcessing = true
        do {
            nativeDocument = try NativeBackupEngine.makeDocument(context: modelContainer.mainContext)
            isExporterPresented = true
        } catch {
            errorMessage = "Couldn't create the backup: \(error.localizedDescription)"
        }
        isProcessing = false
    }

    private func inspectNativeBackup(at url: URL) {
        errorMessage = nil
        statusMessage = nil
        processingMessage = "Reading backup…"
        isProcessing = true
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer { if didStartAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            let document = NativeBackupDocument(data: try Data(contentsOf: url))
            let inspected = try NativeBackupEngine.inspect(document: document)
            pendingRestore = inspected.0
            pendingRestoreSummary = inspected.1
            isRestoreConfirmationPresented = true
        } catch {
            errorMessage = "Couldn't read the backup: \(error.localizedDescription)"
        }
        isProcessing = false
    }

    private func restoreNativeBackup() {
        guard let pendingRestore else { return }
        isProcessing = true
        errorMessage = nil
        do {
            try NativeBackupEngine.restore(pendingRestore, context: modelContainer.mainContext)
            statusMessage = "Backup restored."
            NotificationCenter.default.post(name: .libraryGapsDidChange, object: nil)
            self.pendingRestore = nil
        } catch {
            modelContainer.mainContext.rollback()
            errorMessage = "Couldn't restore the backup: \(error.localizedDescription)"
        }
        isProcessing = false
    }
}
