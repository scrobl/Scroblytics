import Foundation
import SwiftData

/// The database answered, but not with an answer: Core Data's count returns `NSNotFound` (the largest integer) instead of throwing when
/// the store can't be read, which used to flow on as a "count" of 9,223,372,036,854,775,807 scrobbles.
struct StoreUnreadableError: LocalizedError {
    var errorDescription: String? { StoreProblem.describe(self) ?? "Scroblytics couldn’t read its database." }
}

extension ModelContext {
    /// `fetchCount`, except that Core Data's "couldn't count" answer (`NSNotFound`) is an error, never a number.
    func checkedCount<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) throws -> Int {
        let count = try fetchCount(descriptor)
        if count == NSNotFound || count < 0 { throw StoreUnreadableError() }
        return count
    }
}

/// What went wrong with the database file, in plain words and with the codes a support request needs (codes only, never data).
enum StoreProblem {
    enum Kind: Equatable {
        case diskFull, locked, ioError, corrupt, missing, permissions, unreadable
    }

    struct Classification: Equatable {
        var kind: Kind
        /// "NSCocoaErrorDomain 256, SQLite 10": no names, paths or music.
        var codes: String
    }

    /// The error itself, then its underlying errors.
    private static func chain(_ error: Error) -> [NSError] {
        var result: [NSError] = []
        var current: NSError? = error as NSError
        while let item = current, result.count < 6 {
            result.append(item)
            current = item.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return result
    }

    /// Cocoa codes that mean the store file could not be opened, read or written.
    private static func isStoreCocoaCode(_ code: Int) -> Bool {
        [4, 256, 257, 260, 513, 640].contains(code) || (134_000...134_999).contains(code)
    }

    /// Nil when the error is not about the database file.
    static func classify(_ error: Error) -> Classification? {
        if error is StoreUnreadableError { return Classification(kind: .unreadable, codes: "count unavailable") }
        let errors = chain(error)
        let sqlite = errors.first { $0.domain == "NSSQLiteErrorDomain" }?.code
            ?? errors.compactMap { $0.userInfo["NSSQLiteErrorDomain"] as? Int }.first
        let cocoa = errors.first { $0.domain == NSCocoaErrorDomain && isStoreCocoaCode($0.code) }
        guard sqlite != nil || cocoa != nil else { return nil }

        var codes: [String] = []
        if let cocoa { codes.append("\(cocoa.domain) \(cocoa.code)") }
        if let sqlite { codes.append("SQLite \(sqlite)") }
        let kind: Kind
        // SQLite's primary result code is the low byte of an extended one.
        switch (sqlite.map { $0 & 0xFF }, cocoa?.code) {
        case (13?, _), (_, 640?): kind = .diskFull
        case (5?, _), (6?, _): kind = .locked
        case (10?, _): kind = .ioError
        case (11?, _), (26?, _): kind = .corrupt
        case (14?, _), (_, 260?), (_, 4?): kind = .missing
        case (3?, _), (8?, _), (23?, _), (_, 257?), (_, 513?): kind = .permissions
        default: kind = .unreadable
        }
        return Classification(kind: kind, codes: codes.joined(separator: ", "))
    }

    /// A message for a person, or nil when the error isn't about the database.
    static func describe(_ error: Error) -> String? {
        guard let found = classify(error) else { return nil }
        let advice: String
        switch found.kind {
        case .diskFull: advice = "Your disk is full, so Scroblytics can’t save. Free some space and try again."
        case .locked: advice = "Another copy of Scroblytics (or another app) is using its database. Quit the other copy and try again."
        case .ioError: advice = "The disk reported an error while reading or writing Scroblytics’s database. Quit and reopen Scroblytics; if it keeps happening, check the disk."
        case .corrupt: advice = "Scroblytics’s database looks damaged. Quit Scroblytics and restore a backup, or use Help › Report a Problem…."
        case .missing: advice = "Scroblytics’s database file is missing or was moved while the app was running. Quit and reopen Scroblytics."
        case .permissions: advice = "macOS isn’t letting Scroblytics read or write its database file. Check the permissions of the Scroblytics folder in your Library, then quit and reopen the app."
        case .unreadable: advice = "Scroblytics couldn’t read its database just now. Quit and reopen Scroblytics; if it keeps happening, use Help › Report a Problem…."
        }
        return "\(advice) (\(found.codes))"
    }
}
