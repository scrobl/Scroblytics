#if DEBUG
import SwiftUI

/// Which source a Debug build came from, so an in-progress build can be told apart from another one carrying the same version number.
/// The "Stamp debug build" build phase writes `build-stamp.txt` (git branch, then build time in seconds) into Debug builds only.
struct BuildStamp: Equatable {
    let branch: String
    let builtAt: Date

    init?(text: String) {
        let lines = text.split(separator: "\n")
        guard lines.count >= 2, let seconds = TimeInterval(lines[1]) else { return nil }
        branch = String(lines[0])
        builtAt = Date(timeIntervalSince1970: seconds)
    }

    /// Read once, so a running copy keeps its own stamp even if a newer build replaces the files on disk.
    static let current: BuildStamp? = Bundle.main.url(forResource: "build-stamp", withExtension: "txt")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        .flatMap(BuildStamp.init(text:))

    var label: String { "Debug build · \(branch) · built \(builtAt.formatted(date: .abbreviated, time: .shortened))" }
}

/// One line at the top of the window naming the branch and build time.
struct BuildStampStrip: View {
    var body: some View {
        if let stamp = BuildStamp.current {
            Text(stamp.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
                .background(.bar)
        }
    }
}
#endif
