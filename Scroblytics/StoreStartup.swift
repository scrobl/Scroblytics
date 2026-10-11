import AppKit
import SwiftData
import SwiftUI
import os

/// Why the database couldn't be opened at launch, in plain words, and what to do about it.
struct StoreStartupFailure: Sendable {
    enum Cause: Sendable, Equatable { case diskFull, permission, newerVersion, damaged, other }

    let cause: Cause
    let headline: String
    let advice: String
    /// The technical error, for copying into a bug report.
    let details: String
    let storePath: String

    /// Every (domain, code) in the error and the errors it carries, outermost first. SwiftData wraps the Cocoa error that
    /// says what went wrong in a private field, so that is looked for too, and SQLite's own code is read from the
    /// `NSSQLiteErrorDomain` entry Core Data adds.
    nonisolated static func codes(in error: Error) -> [(domain: String, code: Int)] {
        var found: [(String, Int)] = []
        func visit(_ ns: NSError, depth: Int) {
            guard depth < 8 else { return }
            found.append((ns.domain, ns.code))
            if let sqlite = ns.userInfo["NSSQLiteErrorDomain"] as? Int { found.append(("NSSQLiteErrorDomain", sqlite)) }
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError { visit(underlying, depth: depth + 1) }
        }
        visit(error as NSError, depth: 0)
        for child in Mirror(reflecting: error).children {
            var value = child.value
            while case let mirror = Mirror(reflecting: value), mirror.displayStyle == .optional, let inner = mirror.children.first?.value { value = inner }
            if let nested = value as? Error { visit(nested as NSError, depth: 1) }
        }
        return found
    }

    nonisolated static func cause(of error: Error) -> Cause {
        let codes = codes(in: error)
        func has(_ domain: String, _ test: (Int) -> Bool) -> Bool { codes.contains { $0.domain == domain && test($0.code) } }
        if has(NSCocoaErrorDomain, { $0 == NSFileWriteOutOfSpaceError }) || has(NSPOSIXErrorDomain, { $0 == Int(ENOSPC) }) { return .diskFull }
        if has(NSCocoaErrorDomain, { $0 == NSFileWriteNoPermissionError || $0 == NSFileReadNoPermissionError })
            || has(NSPOSIXErrorDomain, { $0 == Int(EACCES) || $0 == Int(EPERM) || $0 == Int(EROFS) }) { return .permission }
        // Core Data's migration and model-version errors: made by another version, or can't be upgraded.
        if has(NSCocoaErrorDomain, { (134100...134199).contains($0) }) { return .newerVersion }
        // SQLite: 11 = corrupt, 26 = not a database file.
        if has("NSSQLiteErrorDomain", { $0 == 11 || $0 == 26 }) || has(NSCocoaErrorDomain, { $0 == NSFileReadCorruptFileError }) { return .damaged }
        return .other
    }

    nonisolated static func describe(_ error: Error, storePath: String) -> StoreStartupFailure {
        let cause = cause(of: error)
        let headline: String
        let advice: String
        switch cause {
        case .diskFull:
            headline = "Your disk is full."
            advice = "Scroblytics needs a little free space to open its database. Free up some space, then open Scroblytics again."
        case .permission:
            headline = "Scroblytics isn’t allowed to open its database."
            advice = "The database file or its folder can’t be read or written by your account. Check the file’s permissions in Finder (Get Info › Sharing & Permissions), then open Scroblytics again."
        case .newerVersion:
            headline = "This database was made by a different version of Scroblytics."
            advice = "It may have been written by a newer version, or it can’t be upgraded automatically. Open it with the newer version of Scroblytics, or restore a backup (File › Data Management) after starting over."
        case .damaged:
            headline = "The database file looks damaged."
            advice = "Nothing was changed. If you have a backup of your edits (File › Data Management), you can restore it after starting over: quit Scroblytics, move the database file to your Desktop, and open Scroblytics again. Your Last.fm history will be imported again."
        case .other:
            headline = "Scroblytics couldn’t open its database."
            advice = "Nothing was changed or deleted. Quit and open Scroblytics again. If it keeps happening, copy the details below and share them when you ask for help."
        }
        return StoreStartupFailure(cause: cause, headline: headline, advice: advice, details: "\(error)\n\n\((error as NSError).domain) \((error as NSError).code)", storePath: storePath)
    }
}

enum StoreStartup {
    private static let log = Logger(subsystem: AppIdentity.bundleID, category: "Startup")

    /// Opens the database. When that fails the app still starts, on an empty in-memory stand-in that is never saved, and
    /// shows an explanation instead of crashing. Nothing is ever deleted or moved.
    static func open(schema: Schema, configuration: ModelConfiguration, storePath: String?) -> (container: ModelContainer, failure: StoreStartupFailure?) {
        do {
            return (try ModelContainer(for: schema, configurations: [configuration]), nil)
        } catch {
            let path = storePath ?? URL.applicationSupportDirectory.appending(path: "default.store").path
            let failure = StoreStartupFailure.describe(error, storePath: path)
            log.error("Couldn't open the database at \(path, privacy: .public): \(String(describing: error), privacy: .public)")
            #if DEBUG
            FileHandle.standardError.write(Data("STARTUP database failure cause=\(failure.cause) path=\(path)\nSTARTUP details: \(failure.details.replacingOccurrences(of: "\n", with: " | "))\nSTARTUP codes: \(StoreStartupFailure.codes(in: error))\n".utf8))
            #endif
            let memory = ModelConfiguration(isStoredInMemoryOnly: true)
            // An in-memory store with the same schema cannot fail for file reasons.
            return (try! ModelContainer(for: schema, configurations: [memory]), failure)
        }
    }
}

/// Shown instead of the app when the database can't be opened.
struct StoreErrorView: View {
    let failure: StoreStartupFailure

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .font(.system(size: 52)).foregroundStyle(.orange)
                Text(failure.headline).font(.title.bold()).multilineTextAlignment(.center)
                Text(failure.advice).font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Text("Scroblytics has not deleted or changed anything.").foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button("Show Database in Finder", action: revealInFinder)
                    Button("Copy Details", action: copyDetails)
                    Button("Quit Scroblytics") { NSApp.terminate(nil) }
                        .buttonStyle(.borderedProminent)
                }
                DisclosureGroup("Details") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(failure.storePath).font(.caption.monospaced())
                        Text(failure.details).font(.caption.monospaced())
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .frame(maxWidth: 560)
            }
            .frame(maxWidth: 600)
            .padding(40)
            .frame(maxWidth: .infinity)
        }
    }

    private func revealInFinder() {
        let url = URL(fileURLWithPath: failure.storePath)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    private func copyDetails() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(failure.headline)\n\(failure.storePath)\n\n\(failure.details)", forType: .string)
    }
}
