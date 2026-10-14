import Foundation
import Security

#if DEBUG
/// `SCROBLYTICS_KEYCHAIN_CHECK=1` (with `SCROBLYTICS_STORE_PATH` on a scratch path): how the app reads the Keychain. The saved
/// Last.fm account and the tempo key are each read once and remembered, a failed read is never remembered for later callers,
/// callers that queue behind a read share its answer, and "not saved" is told apart from "couldn't read". Every read goes to a stub
/// that replaces the Keychain, so nothing real is read, written or prompted for. Exits 0 on success.
enum KeychainChecks {
    /// Stands in for the Keychain: counts the reads and answers as told.
    final class Stub: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var response: (status: OSStatus, data: Data?)
        private var delay: TimeInterval

        init(status: OSStatus = errSecSuccess, data: Data? = nil, delay: TimeInterval = 0) {
            response = (status, data)
            self.delay = delay
        }

        var reads: Int { lock.lock(); defer { lock.unlock() }; return count }

        func answer(_ status: OSStatus, _ data: Data? = nil) {
            lock.lock(); response = (status, data); lock.unlock()
        }

        func read() -> (status: OSStatus, data: Data?) {
            lock.lock()
            count += 1
            let answer = response
            let wait = delay
            lock.unlock()
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            return answer
        }
    }

    static let accountJSON = Data(#"{"username":"listener","apiKey":"0123456789abcdef0123456789abcdef"}"#.utf8)

    @MainActor
    static func runHeadlessIfRequested() {
        guard ProcessInfo.processInfo.environment["SCROBLYTICS_KEYCHAIN_CHECK"] != nil else { return }
        Task { @MainActor in
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: String = "") {
                print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty || ok ? "" : "  [\(detail)]"))
                if !ok { failures += 1 }
            }
            func install(_ stub: Stub) { LastfmCredentialsStore.useRawReaderForTesting { stub.read() } }

            // MARK: What a read finds
            let expected = LastfmCredentials(username: "listener", apiKey: "0123456789abcdef0123456789abcdef", apiSecret: nil, sessionKey: nil)
            check("a saved account reads as connected", LastfmCredentialsStore.classify(status: errSecSuccess, data: accountJSON) == .connected(expected))
            check("nothing saved reads as not saved", LastfmCredentialsStore.classify(status: errSecItemNotFound, data: nil) == .notSaved)
            check("a locked keychain reads as unreadable, not as nothing saved", LastfmCredentialsStore.classify(status: errSecInteractionNotAllowed, data: nil) == .unreadable(errSecInteractionNotAllowed))
            check("a denied or cancelled prompt reads as unreadable", LastfmCredentialsStore.classify(status: errSecAuthFailed, data: nil) == .unreadable(errSecAuthFailed) && LastfmCredentialsStore.classify(status: errSecUserCanceled, data: nil) == .unreadable(errSecUserCanceled))
            check("an item that can't be decoded reads as unreadable", LastfmCredentialsStore.classify(status: errSecSuccess, data: Data("not json".utf8)) == .unreadable(errSecDecode) && LastfmCredentialsStore.classify(status: errSecSuccess, data: nil) == .unreadable(errSecDecode))

            // MARK: The account is read once
            let good = Stub(data: accountJSON)
            install(good)
            let loads = (0..<10).map { _ in LastfmCredentialsStore.load() }
            check("ten loads ask the Keychain once and all get the account", good.reads == 1 && loads.allSatisfy { $0 == expected }, "\(good.reads) reads")
            check("a good read leaves no problem", LastfmCredentialsStore.lastProblem == nil)
            LastfmCredentialsStore.dropCache()
            _ = LastfmCredentialsStore.load()
            check("dropping the memory makes the next load ask again, once", good.reads == 2)

            // MARK: A failure is never kept for later callers
            let locked = Stub(status: errSecInteractionNotAllowed)
            install(locked)
            let failed = (0..<3).map { _ in LastfmCredentialsStore.load() }
            check("three loads on a locked keychain each ask again (a failure isn't remembered)", locked.reads == 3 && failed.allSatisfy { $0 == nil }, "\(locked.reads) reads")
            check("and the problem is on record", LastfmCredentialsStore.lastProblem == errSecInteractionNotAllowed)
            locked.answer(errSecSuccess, accountJSON)
            let unlocked = LastfmCredentialsStore.load()
            check("once it is unlocked the next load succeeds and clears the problem", unlocked == expected && LastfmCredentialsStore.lastProblem == nil && locked.reads == 4)
            _ = (0..<5).map { _ in LastfmCredentialsStore.load() }
            check("and is then remembered", locked.reads == 4)

            // MARK: "Not saved" is not kept either, so saving an account is seen at once
            let empty = Stub(status: errSecItemNotFound)
            install(empty)
            _ = (0..<3).map { _ in LastfmCredentialsStore.load() }
            check("with nothing saved each load asks again, and there is no problem", empty.reads == 3 && LastfmCredentialsStore.lastProblem == nil)
            empty.answer(errSecSuccess, accountJSON)
            check("an account saved by another copy of the app is found on the next load", LastfmCredentialsStore.load() == expected)

            // MARK: Saving and clearing update the memory themselves
            let after = Stub(status: errSecItemNotFound)
            install(after)
            let saved = LastfmCredentials(username: "someone", apiKey: "ffffffffffffffffffffffffffffffff", apiSecret: "s", sessionKey: nil)
            LastfmCredentialsStore.noteSaved(saved)
            check("after a save the saved account is the known one, with no read", LastfmCredentialsStore.load() == saved && after.reads == 0)
            LastfmCredentialsStore.noteCleared()
            check("after a clear there is no account, and the next load asks the Keychain", LastfmCredentialsStore.load() == nil && after.reads == 1)

            // MARK: Callers that queue behind a read share it
            let slow = Stub(data: accountJSON, delay: 0.5)
            install(slow)
            let found = LockedBox<[LastfmCredentials?]>([])
            DispatchQueue.concurrentPerform(iterations: 8) { _ in
                for _ in 0..<20 { let value = LastfmCredentialsStore.load(); found.mutate { $0.append(value) } }
            }
            check("eight threads loading at once make one read (two at most, if one starts late) and all get the account", slow.reads <= 2 && found.value.count == 160 && found.value.allSatisfy { $0 == expected }, "\(slow.reads) reads")

            let slowLocked = Stub(status: errSecInteractionNotAllowed, delay: 0.5)
            install(slowLocked)
            let outcomes = LockedBox<[LastfmCredentialsStore.ReadResult]>([])
            DispatchQueue.concurrentPerform(iterations: 8) { _ in
                let result = LastfmCredentialsStore.read()
                outcomes.mutate { $0.append(result) }
            }
            check("eight threads hitting a locked keychain at once don't each prompt: one read (two at most), and all are told it is unreadable", slowLocked.reads <= 2 && outcomes.value.count == 8 && outcomes.value.allSatisfy { $0 == .unreadable(errSecInteractionNotAllowed) }, "\(slowLocked.reads) reads")

            // MARK: The tempo key
            func installKey(_ stub: Stub) { GetSongBPMKeychain.useRawReaderForTesting { stub.read() } }
            let noKey = Stub(status: errSecItemNotFound)
            installKey(noKey)
            let manyNil = (0..<1000).map { _ in GetSongBPMKeychain.key() }
            check("a thousand tempo lookups with no saved key ask the Keychain once, and 'no key' is remembered", noKey.reads == 1 && manyNil.allSatisfy { $0 == nil }, "\(noKey.reads) reads")
            let withKey = Stub(data: Data("  my-key \n".utf8))
            installKey(withKey)
            let keys = (0..<1000).map { _ in GetSongBPMKeychain.key() }
            check("a saved key is read once, trimmed, and remembered", withKey.reads == 1 && keys.allSatisfy { $0 == "my-key" }, "\(withKey.reads) reads, \(keys.first.map { String(describing: $0) } ?? "")")
            let blank = Stub(data: Data("   ".utf8))
            installKey(blank)
            check("a blank saved key counts as no key", GetSongBPMKeychain.key() == nil && blank.reads == 1)
            let lockedKey = Stub(status: errSecInteractionNotAllowed)
            installKey(lockedKey)
            let attempts = (0..<100).map { _ in GetSongBPMKeychain.key() }
            check("a failed read of the tempo key is remembered for a minute, so a loop of lookups doesn't prompt again and again", lockedKey.reads == 1 && attempts.allSatisfy { $0 == nil }, "\(lockedKey.reads) reads")
            check("the tempo key reads are serialized too", {
                let gate = Stub(data: Data("k".utf8), delay: 0.3)
                installKey(gate)
                let box = LockedBox<[String?]>([])
                DispatchQueue.concurrentPerform(iterations: 8) { _ in let v = GetSongBPMKeychain.key(); box.mutate { $0.append(v) } }
                return gate.reads <= 2 && box.value.allSatisfy { $0 == "k" } && box.value.count == 8
            }())

            print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }

    /// A value several threads can add to.
    final class LockedBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value
        init(_ value: Value) { stored = value }
        var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
        func mutate(_ change: (inout Value) -> Void) { lock.lock(); change(&stored); lock.unlock() }
    }
}
#endif
