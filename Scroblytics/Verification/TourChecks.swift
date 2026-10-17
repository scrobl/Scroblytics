import Foundation

#if DEBUG
/// `SCROBLYTICS_TEST_TOUR=<minutes>` (with `SCROBLYTICS_STORE_PATH` on a COPY of a library and `SCROBLYTICS_OFFLINE=1`, optionally
/// `SCROBLYTICS_TEST_TOUR_LOG=<file>`): drives the window by itself for that long, the way a person would move through it, and reports
/// how long the main thread was ever unresponsive during each step. Meant for the macOS 15 test, where nobody can click: it goes through
/// every tab, opens an artist, album and track in the Library stack and leaves and returns to it, and opens several tools and leaves and
/// returns to those. Then it logs a summary and quits. A crash shows as a log that never says "TOUR done".
enum Tour {
    static var minutes: Double? {
        ProcessInfo.processInfo.environment["SCROBLYTICS_TEST_TOUR"].flatMap(Double.init)
    }

    private static let lock = NSLock()
    static func log(_ line: String) {
        let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(line)"
        print(stamped)
        guard let path = ProcessInfo.processInfo.environment["SCROBLYTICS_TEST_TOUR_LOG"] else { return }
        lock.lock(); defer { lock.unlock() }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile(); handle.write(Data((stamped + "\n").utf8)); try? handle.close()
        } else {
            try? (stamped + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// Pings the main thread every 100 ms from another thread and records how late each answer comes back.
    final class StallMonitor: @unchecked Sendable {
        private let lock = NSLock()
        private var _phase = "start"
        private var running = false
        private(set) var worst: [String: Double] = [:]
        private(set) var stalls: [(phase: String, ms: Double)] = []

        var phase: String {
            get { lock.lock(); defer { lock.unlock() }; return _phase }
            set { lock.lock(); _phase = newValue; lock.unlock() }
        }

        func start() {
            lock.lock(); running = true; lock.unlock()
            Thread.detachNewThread { [self] in
                while true {
                    lock.lock(); let go = running; lock.unlock()
                    if !go { return }
                    let sent = DispatchTime.now()
                    let done = DispatchSemaphore(value: 0)
                    DispatchQueue.main.async { done.signal() }
                    done.wait()
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - sent.uptimeNanoseconds) / 1e6
                    lock.lock()
                    let current = _phase
                    if ms > (worst[current] ?? 0) { worst[current] = ms }
                    if ms >= 500 { stalls.append((current, ms)) }
                    lock.unlock()
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
        }

        func stop() { lock.lock(); running = false; lock.unlock() }
        var snapshot: (worst: [String: Double], stalls: [(phase: String, ms: Double)]) {
            lock.lock(); defer { lock.unlock() }
            return (worst, stalls)
        }
    }
}
#endif
