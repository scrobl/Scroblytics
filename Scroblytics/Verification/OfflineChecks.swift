import Foundation
import SwiftData
import os

#if DEBUG
/// Fails every web request the way a disconnected Mac does, and counts how many were attempted.
final class FailingNetworkProtocol: URLProtocol {
    static let attempts = OSAllocatedUnfairLock(initialState: 0)

    override class func canInit(with request: URLRequest) -> Bool { request.url?.scheme?.hasPrefix("http") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.attempts.withLock { $0 += 1 }
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

/// `SCROBLYTICS_OFFLINE_CHECK=1`: Offline mode blocks every transport without sending a request, the connection-failure
/// prompt fires once per burst, and an interrupted artwork run records nothing as "no artwork". With
/// `SCROBLYTICS_STORE_PATH` pointing at a COPY of the store it also runs the artwork check on real rows.
enum OfflineChecks {
    static func runHeadlessIfRequested(container: ModelContainer) {
        guard ProcessInfo.processInfo.environment["SCROBLYTICS_OFFLINE_CHECK"] != nil else { return }
        HeadlessTask.run("OfflineChecks") {
            var failures = 0
            func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
                print("\(ok ? "PASS" : "FAIL")  \(name)\(ok || detail().isEmpty ? "" : " — " + detail())")
                if !ok { failures += 1 }
            }
            func attempts() -> Int { FailingNetworkProtocol.attempts.withLock { $0 } }
            URLProtocol.registerClass(FailingNetworkProtocol.self)
            // The artwork run below may touch this preference; put it back as it was.
            let fallbackKey = "artwork.fallbackPassForSyncAt"
            let savedFallback = UserDefaults.standard.object(forKey: fallbackKey)

            // 1. Every transport refuses while offline, and sends nothing.
            ConnectivityGate.set(offline: true)
            let before = attempts()
            let lastfm = LastfmAPIClient(apiKey: "test", username: "test")
            func throwsOffline(_ name: String, _ body: @Sendable () async throws -> Void) async {
                do { try await body(); check("\(name) refuses while offline", false, "it did not throw") }
                catch is OfflineError { check("\(name) refuses while offline", true) }
                catch { check("\(name) refuses while offline", false, "threw \(error)") }
            }
            await throwsOffline("Last.fm read") { _ = try await lastfm.fetchUserPlaycount() }
            await throwsOffline("Last.fm now playing") { _ = try await lastfm.fetchNowPlaying() }
            await throwsOffline("Last.fm write") { _ = try await LastfmWriteClient.getAuthToken(apiKey: "k", secret: "s") }
            await throwsOffline("Deezer") { _ = try await DeezerAPIClient().fetchArtistImageURL(artist: "Artist A") }
            await throwsOffline("Deezer tempo") { _ = try await DeezerAPIClient().fetchTrackBPM(artist: "Artist A", track: "Song A") }
            await throwsOffline("GetSongBPM") { _ = try await GetSongBPMClient(apiKey: "test").fetchFeatures(artist: "Artist A", track: "Song A") }
            await throwsOffline("MusicBrainz") { _ = try await MusicBrainzAPIClient().fetchAlbumReleaseDate(artist: "Artist A", album: "Album") }
            await throwsOffline("cloud Ask provider") { _ = try await AskHTTP.send(URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!), provider: "Claude") }
            check("no request was sent while offline", attempts() == before, "\(attempts() - before) attempts")

            // Local servers are not the internet: they are still tried.
            do { _ = try await AskHTTP.send(URLRequest(url: URL(string: "http://localhost:11434/api/chat")!), provider: "Ollama") } catch {}
            check("a server on this Mac is still tried while offline", attempts() == before + 1, "attempts \(attempts() - before)")
            check("Ask: a cloud engine is unavailable while offline", {
                var settings = AskSettings()
                settings.selected = .anthropic
                if case .unavailable = AskEngines.resolve(registry: .standard, settings: settings).availability { return true } else { return false }
            }())

            // 2. Online but with no connection: requests are attempted and reported as connection failures.
            ConnectivityGate.set(offline: false)
            let online = attempts()
            do { _ = try await lastfm.fetchUserPlaycount(); check("online request fails when disconnected", false) }
            catch let error as LastfmAPIError {
                if case .network = error { check("a disconnected request surfaces as a network error", attempts() == online + 1) }
                else { check("a disconnected request surfaces as a network error", false, "\(error)") }
            } catch { check("a disconnected request surfaces as a network error", false, "\(error)") }

            // 3. The classifier.
            let codes: [(URLError.Code, Bool)] = [
                (.notConnectedToInternet, true), (.networkConnectionLost, true), (.cannotFindHost, true), (.cannotConnectToHost, true),
                (.dnsLookupFailed, true), (.timedOut, true), (.dataNotAllowed, true), (.badServerResponse, false), (.cancelled, false), (.badURL, false),
            ]
            check("connection errors count, other errors don't", codes.allSatisfy { ConnectivityGate.isConnectivityFailure(URLError($0.0)) == $0.1 })
            check("an HTTP or API error is not a connection failure", !ConnectivityGate.isConnectivityError(LastfmAPIError.http(500)) && !ConnectivityGate.isConnectivityError(LastfmAPIError.api(code: 10, message: "x")))
            check("a wrapped connection error is recognised", ConnectivityGate.isConnectivityError(LastfmAPIError.network(URLError(.notConnectedToInternet))))
            check("loopback hosts are recognised", ConnectivityGate.isLoopback(host: "localhost") && ConnectivityGate.isLoopback(host: "127.0.0.1") && !ConnectivityGate.isLoopback(host: "api.deezer.com"))

            // 4. The prompt decider, with a fake clock.
            let t0 = Date(timeIntervalSince1970: 1_000_000)
            var d = ConnectivityPromptDecider()
            check("one failure raises nothing", !d.record(source: "Last.fm", now: t0))
            check("a second failure from another source within 2 s raises the prompt", d.record(source: "Deezer", now: t0.addingTimeInterval(1)))
            check("no second prompt while the first is open", !d.record(source: "Artwork", now: t0.addingTimeInterval(1.5)))
            d.answeredNotNow(now: t0.addingTimeInterval(2))
            check("“Not now” snoozes for 15 minutes", !d.record(source: "Last.fm", now: t0.addingTimeInterval(60)) && !d.record(source: "Deezer", now: t0.addingTimeInterval(61)))
            var d2 = ConnectivityPromptDecider()
            check("three failures from one source within 2 s raise it", [0.0, 0.5, 1.0].map { d2.record(source: "Last.fm", now: t0.addingTimeInterval($0)) } == [false, false, true])
            var d3 = ConnectivityPromptDecider()
            check("failures more than 2 s apart don't add up", [0.0, 3.0, 6.0].map { d3.record(source: "Last.fm", now: t0.addingTimeInterval($0)) } == [false, false, false])
            var d4 = ConnectivityPromptDecider()
            _ = d4.record(source: "Last.fm", now: t0)
            d4.recordSuccess()
            check("a success clears the streak", !d4.record(source: "Deezer", now: t0.addingTimeInterval(0.5)))
            var d5 = ConnectivityPromptDecider()
            d5.pathUnsatisfied = true
            check("with no network path, one failure is enough", d5.record(source: "Last.fm", now: t0))
            var d6 = ConnectivityPromptDecider()
            d6.answeredDontAsk()
            check("“Don’t ask again” silences it for the session", !d6.record(source: "A", now: t0) && !d6.record(source: "B", now: t0))

            // 5. An interrupted artwork run must not record anything as “no artwork”.
            let context = container.mainContext
            func resolvedAlbums() -> Int { (try? context.fetchCount(FetchDescriptor<Album>(predicate: #Predicate { $0.imageResolvedAt != nil }))) ?? -1 }
            func resolvedArtists() -> Int { (try? context.fetchCount(FetchDescriptor<Artist>(predicate: #Predicate { $0.imageResolvedAt != nil }))) ?? -1 }
            guard ProcessInfo.processInfo.environment["SCROBLYTICS_STORE_PATH"] != nil else {
                print("SKIPPED  artwork checks need SCROBLYTICS_STORE_PATH pointing at a COPY of the store")
                print(failures == 0 ? "ALL OFFLINE CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
                exit(failures == 0 ? 0 : 1)
            }
            // On the copy: make 40 albums and 10 artists look like they have never been looked up.
            for album in try context.fetch(FetchDescriptor<Album>()).filter({ $0.artist != nil }).prefix(40) { album.imageResolvedAt = nil; album.detectedImageFilename = nil }
            for artist in try context.fetch(FetchDescriptor<Artist>()).prefix(10) { artist.imageResolvedAt = nil; artist.detectedImageFilename = nil }
            try context.save()
            let albumsBefore = resolvedAlbums(), artistsBefore = resolvedArtists()
            let unresolvedAlbumsBefore = try context.fetchCount(FetchDescriptor<Album>(predicate: #Predicate { $0.imageResolvedAt == nil }))
            check("the copy now has albums and artists waiting for artwork", unresolvedAlbumsBefore >= 40)
            ConnectivityGate.set(offline: false)
            let run = Task { try? await ImageResolutionEngine.resolveAllUnresolved(container: container) }
            try? await Task.sleep(for: .seconds(14))
            run.cancel()
            _ = await run.value
            try? await Task.sleep(for: .seconds(1))
            context.rollback()
            check("a disconnected artwork run marks no album as resolved", resolvedAlbums() == albumsBefore, "\(albumsBefore) → \(resolvedAlbums())")
            check("a disconnected artwork run marks no artist as resolved", resolvedArtists() == artistsBefore, "\(artistsBefore) → \(resolvedArtists())")
            // While offline the track-length and release-date queues start nothing and send nothing.
            ConnectivityGate.set(offline: true)
            let queuesBefore = attempts()
            let sample = Array(try context.fetch(FetchDescriptor<Scrobble>(sortBy: [SortDescriptor(\.playedAt)])).prefix(60).map(\.snapshot))
            _ = await DurationEngine.resolveDurationLookup(context: context, client: DeezerAPIClient(), scrobbles: sample)
            let seeded = await ReleaseDateEngine.seedUnresolvedAlbums(context: context, musicBrainz: MusicBrainzAPIClient(), deezer: DeezerAPIClient())
            try? await Task.sleep(for: .seconds(2))
            check("offline: track lengths and release dates send nothing", attempts() == queuesBefore, "\(attempts() - queuesBefore) attempts")
            check("offline: the release-date sweep queues nothing", seeded == 0)
            // The earlier run's worker is detached from the cancelled task; switching to Offline mode is what stops it.
            try? await Task.sleep(for: .seconds(2))
            let offlineRun = attempts()
            do { try await ImageResolutionEngine.resolveAllUnresolved(container: container); check("an offline artwork run stops quietly", false, "it finished normally") }
            catch is CancellationError { check("an offline artwork run stops quietly", attempts() == offlineRun) }
            catch { check("an offline artwork run stops quietly", false, "threw \(error)") }
            check("an offline artwork run records nothing", resolvedAlbums() == albumsBefore && resolvedArtists() == artistsBefore)

            ConnectivityGate.set(offline: false)
            if let savedFallback { UserDefaults.standard.set(savedFallback, forKey: fallbackKey) } else { UserDefaults.standard.removeObject(forKey: fallbackKey) }
            print(failures == 0 ? "ALL OFFLINE CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }
}
#endif
