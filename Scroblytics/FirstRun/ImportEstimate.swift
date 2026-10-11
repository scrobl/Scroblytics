import Foundation

/// A rough "how long is left" for a long import, said the way a person would.
enum ImportEstimate {
    /// Not offered until the pace has settled: a few seconds in and a few hundred scrobbles imported.
    static let minimumElapsed: TimeInterval = 5
    static let minimumProcessed = 400

    /// `processed` and `total` count scrobbles checked so far and expected overall; `baselineProcessed` is how many
    /// had been checked when timing began and `elapsed` the seconds since then. Nil while it is too early to say.
    static func remainingText(processed: Int, total: Int, baselineProcessed: Int = 0, elapsed: TimeInterval) -> String? {
        let done = processed - baselineProcessed
        guard total > processed, done >= minimumProcessed, elapsed >= minimumElapsed else { return nil }
        let rate = Double(done) / elapsed
        guard rate > 0 else { return nil }
        let seconds = Double(total - processed) / rate
        switch seconds {
        case ..<60:
            return "less than a minute left"
        case ..<(90 * 60):
            return "about \(max(1, Int((seconds / 60).rounded()))) min left"
        case ..<(24 * 3600):
            let minutes = Int((seconds / 300).rounded()) * 5
            let (h, m) = (minutes / 60, minutes % 60)
            return m == 0 ? "about \(h) h left" : "about \(h) h \(m) min left"
        default:
            return "more than a day left"
        }
    }
}
