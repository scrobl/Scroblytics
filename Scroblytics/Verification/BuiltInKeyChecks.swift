import CryptoKit
import Foundation
import SwiftData

#if DEBUG
/// `SCROBLYTICS_BUILTINKEY_CHECK=1` (with `SCROBLYTICS_STORE_PATH` on a scratch path): the Last.fm key built into the app. The pair is read
/// from the build, never stored in the Keychain; an account on it is saved with no key and read back with the current pair filled in; an
/// account with the person's own key reads as before; moving between the two keeps the username, drops the session that belonged to the
/// other key and never touches anything else; signed requests use the built-in secret; and the diagnostics never show either value.
/// The Keychain is replaced by stubs, so nothing real is read, written or prompted for. Exits 0 on success.
enum BuiltInKeyChecks {
    private static let builtInKey = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private static let builtInSecret = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    private static let ownKey = "cccccccccccccccccccccccccccccccc"
    private static let ownSecret = "dddddddddddddddddddddddddddddddd"

    /// The stand-in Last.fm answer: records the `api_key` each request carried and replies with whatever `answer` holds. It runs on the
    /// URL loading thread, so it is built here, outside the main-actor check closure.
    nonisolated private static func responder(seenKeys: KeychainChecks.LockedBox<[String]>, answer: KeychainChecks.LockedBox<(status: Int, body: String)>) -> (URLRequest) -> (status: Int, body: String)? {
        { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            seenKeys.mutate { $0.append(items.first { $0.name == "api_key" }?.value ?? "") }
            return answer.value
        }
    }

    @MainActor
    static func runHeadlessIfRequested(container: ModelContainer) {
        guard ProcessInfo.processInfo.environment["SCROBLYTICS_BUILTINKEY_CHECK"] != nil else { return }
        Task { @MainActor in
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: String = "") {
                print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty || ok ? "" : "  [\(detail)]"))
                if !ok { failures += 1 }
            }
            let pair = LastfmBuiltInKey.Pair(key: builtInKey, secret: builtInSecret)
            LastfmBuiltInKey.useForTesting(.pair(pair))

            // A stub Keychain: what `save` writes is what the next `load` reads back.
            let stub = KeychainChecks.Stub(status: errSecItemNotFound)
            let writes = KeychainChecks.LockedBox<[Data]>([])
            func installKeychain(saved: Data? = nil) {
                stub.answer(saved == nil ? errSecItemNotFound : errSecSuccess, saved)
                writes.mutate { $0.removeAll() }
                LastfmCredentialsStore.useRawReaderForTesting { stub.read() }
                LastfmCredentialsStore.useRawWriterForTesting { data in
                    writes.mutate { $0.append(data) }
                    stub.answer(errSecSuccess, data)
                }
            }
            func json(_ data: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }
            func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

            // MARK: The pair comes from the build
            check("an Info.plist value is used when it is real", LastfmBuiltInKey.cleaned("  \(builtInKey)\n") == builtInKey)
            check("a missing, blank or unexpanded value is no key", LastfmBuiltInKey.cleaned(nil) == nil && LastfmBuiltInKey.cleaned("") == nil && LastfmBuiltInKey.cleaned("   ") == nil && LastfmBuiltInKey.cleaned("$(LASTFM_API_KEY)") == nil)
            check("the pair is available and recognised as the built-in one", LastfmBuiltInKey.pair == pair && LastfmBuiltInKey.isAvailable && LastfmBuiltInKey.isBuiltIn(key: builtInKey) && !LastfmBuiltInKey.isBuiltIn(key: ownKey))
            LastfmBuiltInKey.useForTesting(.unavailable)
            check("a build without a pair says so", LastfmBuiltInKey.pair == nil && !LastfmBuiltInKey.isAvailable && !LastfmBuiltInKey.isBuiltIn(key: builtInKey))
            LastfmBuiltInKey.useForTesting(.pair(pair))

            // MARK: What is stored
            let onBuiltIn = LastfmCredentials.builtIn(username: "listener", sessionKey: "session-1")
            check("an account on the built-in key carries the effective key and secret", onBuiltIn.apiKey == builtInKey && onBuiltIn.apiSecret == builtInSecret && onBuiltIn.usesBuiltInKey && onBuiltIn.sessionKey == "session-1")
            let storedBuiltIn = (try? LastfmCredentialsStore.encodedForStorage(onBuiltIn)) ?? Data()
            let builtInFields = json(storedBuiltIn)
            check("it is stored with an empty key, no secret and its session", builtInFields["apiKey"] as? String == "" && builtInFields["apiSecret"] == nil && builtInFields["sessionKey"] as? String == "session-1" && builtInFields["username"] as? String == "listener")
            check("neither the built-in key nor its secret appears in what is stored", !text(storedBuiltIn).contains(builtInKey) && !text(storedBuiltIn).contains(builtInSecret))
            let ownAccount = LastfmCredentials(username: "listener", apiKey: ownKey, apiSecret: ownSecret, sessionKey: "session-2")
            let ownFields = json((try? LastfmCredentialsStore.encodedForStorage(ownAccount)) ?? Data())
            check("an account on the person's own key keeps that key and secret", ownFields["apiKey"] as? String == ownKey && ownFields["apiSecret"] as? String == ownSecret && ownFields["sessionKey"] as? String == "session-2")

            // MARK: What is read back
            installKeychain(saved: storedBuiltIn)
            let readBuiltIn = LastfmCredentialsStore.load()
            check("a built-in account reads back with the current pair filled in", readBuiltIn == onBuiltIn, "\(String(describing: readBuiltIn))")
            LastfmBuiltInKey.useForTesting(.pair(.init(key: "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", secret: "ffffffffffffffffffffffffffffffff")))
            installKeychain(saved: storedBuiltIn)
            check("a later release can replace the pair without anyone saving again", LastfmCredentialsStore.load()?.apiKey == "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" && LastfmCredentialsStore.load()?.usesBuiltInKey == true)
            LastfmBuiltInKey.useForTesting(.pair(pair))
            installKeychain(saved: KeychainChecks.accountJSON)
            let old = LastfmCredentialsStore.load()
            check("an account saved before the built-in key existed reads as the person's own", old?.usesBuiltInKey == false && old?.apiKey == "0123456789abcdef0123456789abcdef" && old?.apiSecret == nil)
            LastfmBuiltInKey.useForTesting(.unavailable)
            installKeychain(saved: storedBuiltIn)
            let noPair = LastfmCredentialsStore.load()
            check("a built-in account in a build without the pair still reads (with no key), so the app can say what is wrong", noPair?.usesBuiltInKey == true && noPair?.apiKey == "" && noPair?.apiSecret == nil && noPair?.username == "listener")
            LastfmBuiltInKey.useForTesting(.pair(pair))

            // MARK: Saving
            installKeychain()
            try? LastfmCredentialsStore.save(onBuiltIn)
            check("saving a built-in account writes no key or secret", writes.value.count == 1 && !text(writes.value[0]).contains(builtInKey) && !text(writes.value[0]).contains(builtInSecret))
            check("and what was saved reads back as the same account", LastfmCredentialsStore.load() == onBuiltIn)

            // MARK: Moving between the two keys
            installKeychain(saved: try? LastfmCredentialsStore.encodedForStorage(ownAccount))
            check("an own-key account is offered the move", LastfmKeyMode.offersBuiltInSwitch(LastfmCredentialsStore.load()))
            check("a built-in account, no account, and a build without the pair are not offered it", !LastfmKeyMode.offersBuiltInSwitch(onBuiltIn) && !LastfmKeyMode.offersBuiltInSwitch(nil))
            let moved = try? LastfmKeyMode.switchToBuiltIn()
            check("moving to the built-in key keeps the username and drops the own key, secret and session", moved?.username == "listener" && moved?.usesBuiltInKey == true && moved?.sessionKey == nil && moved?.apiKey == builtInKey && moved?.apiSecret == builtInSecret)
            check("what it saved has no key, secret or session", writes.value.count == 1 && json(writes.value[0])["apiKey"] as? String == "" && json(writes.value[0])["apiSecret"] == nil && json(writes.value[0])["sessionKey"] == nil && !text(writes.value[0]).contains(ownKey) && !text(writes.value[0]).contains(ownSecret))
            check("after the move it is no longer offered, and moving again changes nothing", !LastfmKeyMode.offersBuiltInSwitch(LastfmCredentialsStore.load()) && ((try? LastfmKeyMode.switchToBuiltIn()) != nil) && writes.value.count == 1)
            let back = try? LastfmKeyMode.useOwnKey("  \(ownKey)\n", secret: " \(ownSecret) ")
            check("moving to an own key trims it, keeps the username and drops the session", back?.usesBuiltInKey == false && back?.apiKey == ownKey && back?.apiSecret == ownSecret && back?.sessionKey == nil && back?.username == "listener")
            check("an own key can be saved without its secret", (try? LastfmKeyMode.useOwnKey(ownKey))?.apiSecret == nil)
            var blankThrew = false
            do { _ = try LastfmKeyMode.useOwnKey("   ") } catch LastfmKeyMode.SwitchError.blankKey { blankThrew = true } catch {}
            check("a blank own key is refused and writes nothing", blankThrew && writes.value.count == 3)
            LastfmBuiltInKey.useForTesting(.unavailable)
            installKeychain(saved: try? LastfmCredentialsStore.encodedForStorage(ownAccount))
            var noPairThrew = false
            do { _ = try LastfmKeyMode.switchToBuiltIn() } catch LastfmKeyMode.SwitchError.noBuiltInKey { noPairThrew = true } catch {}
            check("without a built-in pair the move is refused and writes nothing", noPairThrew && writes.value.isEmpty && !LastfmKeyMode.offersBuiltInSwitch(LastfmCredentialsStore.load()))
            LastfmBuiltInKey.useForTesting(.pair(pair))
            installKeychain()
            var noAccountThrew = false
            do { _ = try LastfmKeyMode.switchToBuiltIn() } catch LastfmKeyMode.SwitchError.noAccount { noAccountThrew = true } catch {}
            check("with no saved account there is nothing to move", noAccountThrew && writes.value.isEmpty)

            // MARK: Signed requests use the built-in secret
            let params = ["method": "track.love", "api_key": builtInKey, "sk": "session-1", "artist": "Artist A", "track": "Track 1"]
            let reference = Insecure.MD5.hash(data: Data(("api_key\(builtInKey)artistArtist Amethodtrack.lovesksession-1trackTrack 1" + builtInSecret).utf8)).map { String(format: "%02x", $0) }.joined()
            check("a request signed with the built-in secret matches an independent computation", LastfmSigning.sign(params: params, secret: onBuiltIn.apiSecret ?? "") == reference)

            // MARK: Checking an account with Last.fm (stand-in transport)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [FirstRunChecks.StubTransport.self]
            let session = URLSession(configuration: configuration)
            let seenKeys = KeychainChecks.LockedBox<[String]>([])
            let answer = KeychainChecks.LockedBox<(status: Int, body: String)>((200, #"{"user": {"name": "SomeOne", "playcount": "12"}}"#))
            FirstRunChecks.StubTransport.responder = responder(seenKeys: seenKeys, answer: answer)
            func reply(_ code: Int, _ text: String) { answer.mutate { $0 = (403, "{\"error\": \(code), \"message\": \"\(text)\"}") } }
            func invalidText(_ o: LastfmAccountCheck.Outcome) -> String { if case .invalid(let text) = o { return text }; return "" }
            let viaBuiltIn = await LastfmAccountCheck.validate(username: "  someone ", apiKey: nil, session: session)
            check("a username alone is checked with the built-in key", viaBuiltIn == .valid(.init(username: "SomeOne", scrobbles: 12)) && seenKeys.value == [builtInKey], "\(viaBuiltIn) \(seenKeys.value)")
            let viaOwn = await LastfmAccountCheck.validate(username: "someone", apiKey: ownKey, session: session)
            check("an own key is checked with that key", viaOwn == .valid(.init(username: "SomeOne", scrobbles: 12)) && seenKeys.value == [builtInKey, ownKey])
            let blank = await LastfmAccountCheck.validate(username: "  ", apiKey: nil, session: session)
            check("a blank username is refused before anything is sent", invalidText(blank).contains("Enter your Last.fm username") && seenKeys.value.count == 2)
            reply(10, "Invalid API key")
            let refusedBuiltIn = invalidText(await LastfmAccountCheck.validate(username: "someone", apiKey: nil, session: session))
            let refusedOwn = invalidText(await LastfmAccountCheck.validate(username: "someone", apiKey: ownKey, session: session))
            check("a refused built-in key says it isn't the person's doing and offers their own key", refusedBuiltIn == LastfmAccountCheck.builtInKeyRefused && refusedBuiltIn.contains("isn’t something you did wrong") && !refusedBuiltIn.contains("shared secret"), refusedBuiltIn)
            check("a refused own key still says the key isn't recognised", refusedOwn.contains("doesn’t recognise this API key") && refusedOwn.contains("shared secret"), refusedOwn)
            reply(26, "Suspended API key")
            let suspendedBuiltIn = invalidText(await LastfmAccountCheck.validate(username: "someone", apiKey: nil, session: session))
            let suspendedOwn = invalidText(await LastfmAccountCheck.validate(username: "someone", apiKey: ownKey, session: session))
            check("a suspended built-in key gets the same plain words, an own key the suspension", suspendedBuiltIn == LastfmAccountCheck.builtInKeyRefused && suspendedOwn.contains("suspended"))
            reply(6, "User not found")
            let unknownUser = invalidText(await LastfmAccountCheck.validate(username: "nobody", apiKey: nil, session: session))
            check("an unknown user is still named when the built-in key is used", unknownUser.contains("“nobody”"))
            answer.mutate { $0 = (200, #"{"user": {"name": "SomeOne", "playcount": "12"}}"#) }
            LastfmBuiltInKey.useForTesting(.unavailable)
            let before = seenKeys.value.count
            let missing = invalidText(await LastfmAccountCheck.validate(username: "someone", apiKey: nil, session: session))
            check("a build without the pair says so and sends nothing", missing == LastfmAccountCheck.builtInMissing && seenKeys.value.count == before, missing)
            LastfmBuiltInKey.useForTesting(.pair(pair))

            // MARK: A key whose owner has no Last.fm Pro (error 33): a failure, never a saved "nothing found"
            let lookups = LastfmAPIClient(apiKey: ownKey, username: "someone", session: session)
            let tracklists = FetchDescriptor<AlbumTracklistCacheEntry>()
            @MainActor func savedTracklists() -> Int { (try? container.mainContext.fetchCount(tracklists)) ?? -1 }
            let savedBefore = savedTracklists()
            for code in [33, 10, 26, 2] {
                reply(code, "Refused")
                var thrown: [Int] = []
                do { _ = try await lookups.fetchArtistPopularityStats(artist: "Artist A") } catch LastfmAPIError.api(let got, _) { thrown.append(got) } catch {}
                do { _ = try await lookups.fetchAlbumPopularityStats(artist: "Artist A", album: "Album One") } catch LastfmAPIError.api(let got, _) { thrown.append(got) } catch {}
                do { _ = try await lookups.fetchTrackPopularityStats(artist: "Artist A", track: "Track 1") } catch LastfmAPIError.api(let got, _) { thrown.append(got) } catch {}
                do { _ = try await AlbumTurnoverEngine.getCachedTracklist(context: container.mainContext, client: lookups, artist: "Artist A", album: "Album \(code)") } catch LastfmAPIError.api(let got, _) { thrown.append(got) } catch {}
                check("error \(code) fails popularity and tracklist lookups and saves nothing", thrown == [code, code, code, code] && savedTracklists() == savedBefore, "\(thrown), saved \(savedTracklists() - savedBefore)")
                check("error \(code) is not taken as an answer", !LastfmAPIError.api(code: code, message: "").isGenuineMiss && !EntityTagsEngine.isGenuineMiss(LastfmAPIError.api(code: code, message: "")))
            }
            reply(6, "Not found")
            var statsAnswered = false
            do { statsAnswered = try await lookups.fetchArtistPopularityStats(artist: "Artist A") == nil } catch {}
            let missList = try? await AlbumTurnoverEngine.getCachedTracklist(context: container.mainContext, client: lookups, artist: "Artist A", album: "Unknown Album")
            var missWasAnswer = false
            if case .noMatch? = missList { missWasAnswer = true }
            check("'not found' is still an answer, and is saved", statsAnswered && missWasAnswer && savedTracklists() == savedBefore + 1, "\(statsAnswered) \(savedTracklists() - savedBefore)")
            let proRequired = LastfmAPIError.api(code: 33, message: "Pro Required")
            check("the codes that refuse the key", [10, 26, 33].allSatisfy { LastfmAPIError.api(code: $0, message: "").isKeyRefusal } && [4, 6, 17, 29].allSatisfy { !LastfmAPIError.api(code: $0, message: "").isKeyRefusal })
            reply(33, "Pro Required")
            let noProBuiltIn = invalidText(await LastfmAccountCheck.validate(username: "someone", apiKey: nil, session: session))
            let noProOwn = invalidText(await LastfmAccountCheck.validate(username: "someone", apiKey: ownKey, session: session))
            check("checking an account: the built-in key says it isn't the person's doing, an own key needs Pro", noProBuiltIn == LastfmAccountCheck.builtInKeyRefused && noProOwn.contains("Last.fm Pro") && noProOwn.contains("built-in key"), "\(noProOwn)")
            installKeychain(saved: storedBuiltIn); _ = LastfmCredentialsStore.load()
            check("a sync refused for want of Pro on the built-in key says so", describeSyncError(proRequired) == LastfmAccountCheck.builtInKeyRefused)
            installKeychain(saved: try? LastfmCredentialsStore.encodedForStorage(ownAccount)); _ = LastfmCredentialsStore.load()
            let noProSync = describeSyncError(proRequired)
            check("…and on an own key it says Pro is needed and offers the built-in key", noProSync.contains("Last.fm Pro") && noProSync.contains("built-in key") && !noProSync.contains("error 33"), noProSync)
            LastfmBuiltInKey.useForTesting(.unavailable)
            check("without a built-in key it is not offered", !describeSyncError(proRequired).contains("built-in key"))
            LastfmBuiltInKey.useForTesting(.pair(pair))
            check("unrecognised and suspended keys no longer blame Pro", [10, 26].allSatisfy { !describeSyncError(LastfmAPIError.api(code: $0, message: "")).contains("Pro") })
            let failure = HistoryStatus.Failure(error: proRequired)
            check("a failed import offers Settings and the built-in key", failure.kind == .fixAccount && failure.keyRejected)
            check("the status strip's line names the code", proRequired.lookupsPausedMessage.contains("error 33"))
            answer.mutate { $0 = (200, #"{"user": {"name": "SomeOne", "playcount": "12"}}"#) }

            // MARK: What a failed sync says, and what is offered
            installKeychain(saved: storedBuiltIn); _ = LastfmCredentialsStore.load()
            let refusedError = LastfmAPIError.api(code: 10, message: "Invalid API key")
            check("a sync refused on the built-in key says so", describeSyncError(refusedError) == LastfmAccountCheck.builtInKeyRefused)
            installKeychain(saved: try? LastfmCredentialsStore.encodedForStorage(ownAccount)); _ = LastfmCredentialsStore.load()
            let ownRefused = describeSyncError(refusedError)
            check("a sync refused on an own key keeps its wording and offers the built-in key", ownRefused.contains("doesn’t recognise this API key") && ownRefused.contains("built-in key"), ownRefused)
            LastfmBuiltInKey.useForTesting(.unavailable)
            check("without a built-in key nothing is offered", !describeSyncError(refusedError).contains("built-in key"))
            LastfmBuiltInKey.useForTesting(.pair(pair))
            check("a refused key is marked, other account errors are not", HistoryStatus.Failure(error: refusedError).keyRejected && HistoryStatus.Failure(error: LastfmAPIError.api(code: 26, message: "")).keyRejected && !HistoryStatus.Failure(error: LastfmAPIError.api(code: 17, message: "")).keyRejected && !HistoryStatus.Failure(error: LastfmAPIError.api(code: 29, message: "")).keyRejected)
            installKeychain(saved: try? LastfmCredentialsStore.encodedForStorage(ownAccount))
            check("the app knows an account is on its own key", HistoryStatus(container: container).usesOwnKey)
            installKeychain(saved: storedBuiltIn)
            check("and when it is not", !HistoryStatus(container: container).usesOwnKey)
            installKeychain()
            check("and when there is no account", !HistoryStatus(container: container).usesOwnKey)

            // MARK: The form (Welcome and Settings), through the same stand-in transport
            URLProtocol.registerClass(FirstRunChecks.StubTransport.self)
            defer { URLProtocol.unregisterClass(FirstRunChecks.StubTransport.self) }
            let form = LastfmAccountForm()
            form.username = "someone"
            check("with a built-in key a username is enough", !form.asksForOwnKey && form.canSubmit)
            form.usesOwnKey = true
            check("choosing an own key asks for it", form.asksForOwnKey && !form.canSubmit)
            form.apiKey = "  \(ownKey) "
            check("…and then it can be submitted", form.canSubmit)
            LastfmBuiltInKey.useForTesting(.unavailable)
            form.usesOwnKey = false; form.apiKey = ""
            check("a build without the pair always asks for a key", form.asksForOwnKey && !form.canSubmit)
            LastfmBuiltInKey.useForTesting(.pair(pair))

            // Saved with the built-in key, with an earlier session for the same account.
            installKeychain(saved: try? LastfmCredentialsStore.encodedForStorage(LastfmCredentials.builtIn(username: "SomeOne", sessionKey: "kept-session")))
            let builtInForm = LastfmAccountForm()
            builtInForm.username = "someone"
            let savedBuiltIn = await builtInForm.testAndSave()
            check("saving the same account on the built-in key keeps its write access", savedBuiltIn && writes.value.count == 1 && json(writes.value[0])["apiKey"] as? String == "" && json(writes.value[0])["sessionKey"] as? String == "kept-session", "\(builtInForm.phase)")
            // An own-key account moved to the built-in key through the form loses what belonged to the other key.
            installKeychain(saved: try? LastfmCredentialsStore.encodedForStorage(LastfmCredentials(username: "SomeOne", apiKey: ownKey, apiSecret: ownSecret, sessionKey: "old-session")))
            let moveForm = LastfmAccountForm()
            moveForm.username = "someone"
            let moved2 = await moveForm.testAndSave()
            check("moving to the built-in key through the form drops the own key, secret and session", moved2 && json(writes.value.last ?? Data())["apiKey"] as? String == "" && json(writes.value.last ?? Data())["apiSecret"] == nil && json(writes.value.last ?? Data())["sessionKey"] == nil)
            // And the other way.
            installKeychain(saved: try? LastfmCredentialsStore.encodedForStorage(LastfmCredentials.builtIn(username: "SomeOne", sessionKey: "built-in-session")))
            let ownForm = LastfmAccountForm()
            ownForm.username = "someone"; ownForm.usesOwnKey = true; ownForm.apiKey = ownKey
            let savedOwn = await ownForm.testAndSave()
            check("saving an own key stores it, with no session carried over from the built-in key", savedOwn && json(writes.value.last ?? Data())["apiKey"] as? String == ownKey && json(writes.value.last ?? Data())["sessionKey"] == nil)
            // Re-saving the same own key keeps its write access.
            installKeychain(saved: try? LastfmCredentialsStore.encodedForStorage(LastfmCredentials(username: "SomeOne", apiKey: ownKey, apiSecret: ownSecret, sessionKey: "own-session")))
            let again = LastfmAccountForm()
            again.username = "someone"; again.usesOwnKey = true; again.apiKey = ownKey
            _ = await again.testAndSave()
            check("saving the same own key again keeps its secret and session", json(writes.value.last ?? Data())["apiSecret"] as? String == ownSecret && json(writes.value.last ?? Data())["sessionKey"] as? String == "own-session")
            // What the form loads.
            installKeychain(saved: storedBuiltIn)
            let loadBuiltIn = LastfmAccountForm(); loadBuiltIn.loadSaved()
            check("the form loads a built-in account without a key", !loadBuiltIn.usesOwnKey && loadBuiltIn.apiKey.isEmpty && loadBuiltIn.username == "listener")
            installKeychain(saved: try? LastfmCredentialsStore.encodedForStorage(ownAccount))
            let loadOwn = LastfmAccountForm(); loadOwn.loadSaved()
            check("and an own-key account with its key", loadOwn.usesOwnKey && loadOwn.apiKey == ownKey)
            FirstRunChecks.StubTransport.responder = { _ in nil }

            // MARK: Diagnostics never show the pair
            let summary = await DiagnosticSummary.gather(container: container, loadCredentials: { LastfmCredentials.builtIn(username: "listener42", sessionKey: "session-1") })
            check("the summary says which key the account uses", summary.text.contains("Last.fm key: built in") && summary.inputs.usesBuiltInKey == true)
            check("and holds neither the key, the secret, the session nor the username", !summary.text.contains(builtInKey) && !summary.text.contains(builtInSecret) && !summary.text.contains("session-1") && !summary.text.contains("listener42"))
            let cleaned = DiagnosticRedactor.clean("GET /2.0/?api_key=\(builtInKey) secret \(builtInSecret) listener42", secrets: [.init(value: builtInKey, label: "key"), .init(value: builtInSecret, label: "key"), .init(value: "listener42", label: "username")])
            check("the redactor removes the pair and the username from a log line", !cleaned.contains(builtInKey) && !cleaned.contains(builtInSecret) && !cleaned.contains("listener42"), cleaned)
            let own = await DiagnosticSummary.gather(container: container, loadCredentials: { ownAccount })
            check("an account on its own key says so", own.text.contains("Last.fm key: the person's own") && own.inputs.usesBuiltInKey == false)

            LastfmBuiltInKey.useForTesting(.none)
            LastfmCredentialsStore.useRawWriterForTesting(nil)
            print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }
}
#endif
