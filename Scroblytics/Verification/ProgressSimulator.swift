import Foundation

#if DEBUG
/// `SCROBLYTICS_SIMULATE_PROGRESS=<seconds>`: announces, every so many seconds, the progress that the background lookups (tags, track
/// lengths, release dates) announce while a long backlog is being worked through, so a page that reloads on those announcements can be
/// measured without waiting for a real backlog. Only under a scratch store (`SCROBLYTICS_STORE_PATH`), and it changes no data.
enum ProgressSimulator {
    @MainActor
    static func startIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env["SCROBLYTICS_STORE_PATH"] != nil, let raw = env["SCROBLYTICS_SIMULATE_PROGRESS"], let every = Double(raw), every > 0 else { return }
        Task { @MainActor in
            var round = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(every))
                round += 1
                let center = NotificationCenter.default
                center.post(name: EntityTagsEngine.progressNotification, object: nil)
                center.post(name: DurationEngine.progressNotification, object: DurationEngine.Progress(remaining: 900_000 - round, isComplete: false))
                center.post(name: ReleaseDateEngine.progressNotification, object: ReleaseDateEngine.Progress(remaining: 900_000 - round, isComplete: false))
                FileHandle.standardError.write(Data("SIMULATED progress announcement \(round)\n".utf8))
            }
        }
    }
}
#endif
