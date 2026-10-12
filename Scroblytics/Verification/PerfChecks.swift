import Foundation
import SwiftData

#if DEBUG
/// `SCROBLYTICS_PERF_CHECK=1` (with `SCROBLYTICS_STORE_PATH` on a scratch path): large-library behaviour.
/// 1. The artwork fallback index gives the same answer as the per-album query it replaced (and an independent in-memory scan), on made-up
///    scrobbles that include placeholder-only albums, mixed albums and albums whose newest pictures are all placeholders.
/// 2. On a store that already holds a big history (a scaled COPY, see docs/RELEASING.md), how long 300 per-album queries take against one
///    index build. That part only reports numbers and is skipped on a small store.
/// Exits 0 on success.
enum PerfChecks {
    @MainActor
    static func runHeadlessIfRequested(container: ModelContainer) {
        guard ProcessInfo.processInfo.environment["SCROBLYTICS_PERF_CHECK"] != nil else { return }
        Task { @MainActor in
            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: String = "") {
                print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty || ok ? "" : "  [\(detail)]"))
                if !ok { failures += 1 }
            }
            let context = container.mainContext
            let placeholderHash = "2a96cbd8b46e442fc41c2b86b821562f"
            let existing = (try? context.fetchCount(FetchDescriptor<Scrobble>())) ?? 0

            // MARK: Equivalence on made-up scrobbles (only into an otherwise empty scratch store)
            if existing == 0 {
                let placeholder = "https://lastfm.freetls.fastly.net/i/u/300x300/\(placeholderHash).png"
                func real(_ n: Int) -> String { "https://img.example/real\(n).jpg" }
                let base = Date(timeIntervalSince1970: 1_700_000_000)
                var all: [(artist: String, album: String, url: String?, at: Date)] = []
                var clock = 0
                func play(_ artist: String, _ album: String, _ url: String?) { clock += 1; all.append((artist, album, url, base.addingTimeInterval(Double(clock) * 60))) }
                // A: newest is real, older differ -> the newest real wins.
                play("Artist A", "Album One", real(1)); play("Artist A", "Album One", real(2)); play("Artist A", "Album One", real(3))
                // B: newest are placeholders, an older one is real -> still found (within the newest 50).
                play("Artist B", "Album Two", real(10)); for _ in 0..<5 { play("Artist B", "Album Two", placeholder) }
                // C: only placeholders and nil -> none.
                play("Artist C", "Album Three", placeholder); play("Artist C", "Album Three", nil)
                // D: same album name under another artist is a different album.
                play("Artist D", "Album One", real(20))
                // E: case differs, so it is a different album for the exact comparison the old query made.
                play("artist a", "album one", real(30))
                // F: no album at all.
                play("Artist F", "", real(40))
                // G: real picture only older than 60 plays (the old query looked at the newest 50 only).
                play("Artist G", "Album Four", real(50)); for _ in 0..<60 { play("Artist G", "Album Four", placeholder) }
                for row in all {
                    context.insert(Scrobble(artistName: row.artist, albumName: row.album, trackName: "Track", imageURL: row.url, playedAt: row.at, lastConfirmedAt: base))
                }
                try? context.save()

                let built = (try? LastfmArtworkIndex.build(context: context)) ?? (index: [:], scrobbles: -1)
                check("the index read every scrobble", built.scrobbles == all.count, "\(built.scrobbles) of \(all.count)")

                // Independent cross-check: newest real URL per exact (artist, album), by a plain scan.
                var expected: [String: String] = [:]
                for row in all.sorted(by: { $0.at > $1.at }) {
                    guard let url = row.url, !url.contains(placeholderHash) else { continue }
                    let key = LastfmArtworkIndex.key(artist: row.artist, album: row.album)
                    if expected[key] == nil { expected[key] = url }
                }
                check("the index equals an independent scan for every album", built.index.mapValues(\.absoluteString) == expected, "\(built.index.count) vs \(expected.count)")

                // The old per-album query, as it was.
                func oldQuery(_ artist: String, _ album: String) -> URL? {
                    var d = FetchDescriptor<Scrobble>(predicate: #Predicate { $0.artistName == artist && $0.albumName == album }, sortBy: [SortDescriptor(\.playedAt, order: .reverse)])
                    d.fetchLimit = 50
                    return ((try? context.fetch(d)) ?? []).compactMap(\.imageURL).first { !TextNormalization.isLastfmPlaceholderImage($0) }.flatMap(URL.init(string:))
                }
                let albums = Set(all.map { LastfmArtworkIndex.key(artist: $0.artist, album: $0.album) })
                var sameAsOld = true; var onlyNewer: [String] = []
                for key in albums {
                    let parts = key.components(separatedBy: "\u{1F}")
                    let old = oldQuery(parts[0], parts[1]); let new = built.index[key]
                    if old != new { if old == nil, new != nil { onlyNewer.append(parts[0]) } else { sameAsOld = false } }
                }
                check("wherever the old query found a picture the index finds the same one", sameAsOld)
                check("the only difference is an album whose real picture was older than its newest 50 plays (the index finds it)", onlyNewer == ["Artist G"], "\(onlyNewer)")
                check("an album with only placeholders or no picture has no entry", built.index[LastfmArtworkIndex.key(artist: "Artist C", album: "Album Three")] == nil)
                check("the same album name under another artist is kept apart", built.index[LastfmArtworkIndex.key(artist: "Artist D", album: "Album One")]?.absoluteString == real(20))
                check("spelling that differs only in case is a different album, as before", built.index[LastfmArtworkIndex.key(artist: "artist a", album: "album one")]?.absoluteString == real(30))
            } else {
                print("      (store already holds \(existing) scrobbles: skipping the made-up equivalence part)")
            }

            // MARK: Popularity tiers are rebuilt less often as the record count grows
            check("the popularity rebuild interval is 15 s for a small library", PopularityStore.snapshotRefreshInterval(recordCount: 0) == 15 && PopularityStore.snapshotRefreshInterval(recordCount: 5_000) == 15)
            check("it grows with the record count", PopularityStore.snapshotRefreshInterval(recordCount: 40_000) == 100)
            check("it never exceeds five minutes", PopularityStore.snapshotRefreshInterval(recordCount: 5_000_000) == 300)

            // MARK: Speed on a big history (a copy), numbers only
            func footprintMB() -> Double {
                var info = task_vm_info_data_t()
                var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
                let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
                return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
            }
            if existing >= 50_000 {
                let pairs = ((try? context.fetch({ () -> FetchDescriptor<Scrobble> in var d = FetchDescriptor<Scrobble>(sortBy: [SortDescriptor(\.playedAt, order: .reverse)]); d.fetchLimit = 4_000; return d }())) ?? [])
                var seen = Set<String>(); var albums: [(String, String)] = []
                for s in pairs where !s.albumName.isEmpty && seen.insert(LastfmArtworkIndex.key(artist: s.artistName, album: s.albumName)).inserted { albums.append((s.artistName, s.albumName)) }
                albums = Array(albums.prefix(300))
                let memBefore = footprintMB()
                let t0 = Date()
                var held: [[Scrobble]] = []
                for (artist, album) in albums {
                    var d = FetchDescriptor<Scrobble>(predicate: #Predicate { $0.artistName == artist && $0.albumName == album }, sortBy: [SortDescriptor(\.playedAt, order: .reverse)])
                    d.fetchLimit = 50
                    held.append((try? context.fetch(d)) ?? [])
                }
                let memAfterQueries = footprintMB()
                held.removeAll()
                let perQuery = Date().timeIntervalSince(t0) / Double(max(albums.count, 1))
                let t1 = Date()
                let built = try? LastfmArtworkIndex.build(context: context)
                let buildTime = Date().timeIntervalSince(t1)
                let memAfterIndex = footprintMB()
                print(String(format: "      memory: %.0f MB before, %.0f MB after %d old-style queries, %.0f MB after the index pass", memBefore, memAfterQueries, albums.count, memAfterIndex))
                print(String(format: "      %d scrobbles: old query %.0f ms per album (%d albums timed); one index pass %.2f s for all %d albums", existing, perQuery * 1000, albums.count, buildTime, built?.index.count ?? 0))
                check("one index pass is far cheaper than looking up the albums one at a time", buildTime < perQuery * Double(max(albums.count, 1)) * 2 || buildTime < 5, "\(buildTime)s vs \(perQuery * Double(albums.count))s")
            }

            // Rabbit Hole's library index (tracks, artists, "plays next" habits) on a big history.
            if existing >= 50_000 {
                let snapshots = QueryIdentity.canonicalizingArtists((try? context.fetch(FetchDescriptor<Scrobble>(sortBy: [SortDescriptor(\.playedAt)])).map(\.snapshot)) ?? [])
                let before = footprintMB()
                let started = Date()
                let library = RabbitHoleLibrary.build(scrobbles: snapshots)
                let seconds = Date().timeIntervalSince(started)
                print(String(format: "      Rabbit Hole index over %d scrobbles: %d tracks in %.2f s, memory %+.0f MB", snapshots.count, library.tracks.count, seconds, footprintMB() - before))
                check("the Rabbit Hole index builds in a few seconds even on a huge history", seconds < 10, "\(seconds)s")
            }

            print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }
}
#endif
