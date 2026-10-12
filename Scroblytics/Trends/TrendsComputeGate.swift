import Foundation

/// Lets at most `limit` Trends chart computations run at once, at low priority. A computation that was asked for and then replaced (the
/// range changed, or background data moved on) is skipped if it hasn't started, so they never pile up and keep every core busy;
/// one already running finishes first.
actor TrendsComputeGate {
    static let shared = TrendsComputeGate()
    static let limit = 2

    private var running = 0

    func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T? {
        while running >= Self.limit {
            if Task.isCancelled { return nil }
            try? await Task.sleep(for: .milliseconds(40))
        }
        guard !Task.isCancelled else { return nil }
        running += 1
        let result = await Task.detached(priority: .utility) { work() }.value
        running -= 1
        return result
    }
}
