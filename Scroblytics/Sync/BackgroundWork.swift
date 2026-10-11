import SwiftUI
import Observation

/// One place that knows which background jobs are running and how far along
/// they are, so the app can show a single quiet status line instead of each
/// warmer being invisible. Purely a display model — the engines still own
/// their own queues and never wait on this.
@MainActor
@Observable
final class BackgroundWorkStore {
    enum Job: CaseIterable, Hashable {
        case artwork, durations, tempos, releaseDates, lovedTracks, popularity, tags, tagWrites

        var label: String {
            switch self {
            case .artwork: "artwork"
            case .durations: "track lengths"
            case .tempos: "tempos"
            case .releaseDates: "release dates"
            case .lovedTracks: "loved tracks"
            case .popularity: "popularity"
            case .tags: "tags"
            case .tagWrites: "tag changes"
            }
        }
    }

    struct State {
        var remaining = 0
        var total = 0
        var failed = 0
    }

    /// Jobs with work left.
    private(set) var active: [Job: State] = [:]
    /// Items a finished run couldn't resolve — kept visible (they're retried
    /// next launch) rather than silently forgotten.
    private(set) var failures: [Job: Int] = [:]
    private(set) var errors: [Job: String] = [:]

    var isVisible: Bool { !active.isEmpty || !failures.isEmpty || !errors.isEmpty }

    /// `remaining == 0` finishes the job. `total` only ever grows within a run,
    /// since queues gain work while running (a page scrolled into view).
    func report(_ job: Job, remaining: Int, total: Int? = nil, failed: Int = 0) {
        guard remaining > 0 else {
            finish(job, failed: failed)
            return
        }
        var state = active[job] ?? State()
        state.remaining = remaining
        state.total = max(state.total, total ?? remaining, remaining)
        state.failed = failed
        active[job] = state
        failures[job] = nil
    }

    func finish(_ job: Job, failed: Int = 0) {
        active[job] = nil
        failures[job] = failed > 0 ? failed : nil
    }

    func fail(_ job: Job, _ message: String) { errors[job] = message }
    func clearError(_ job: Job) { errors[job] = nil }

    fileprivate var totalRemaining: Int { active.values.reduce(0) { $0 + $1.remaining } }
    fileprivate var totalWork: Int { active.values.reduce(0) { $0 + $1.total } }
    fileprivate var totalFailedThisRun: Int { active.values.reduce(0) { $0 + $1.failed } }

    fileprivate func labels(of jobs: [Job]) -> String {
        jobs.map(\.label).formatted(.list(type: .and, width: .narrow))
    }

    fileprivate var activeJobs: [Job] { Job.allCases.filter { active[$0] != nil } }
    fileprivate var failedJobs: [Job] { Job.allCases.filter { failures[$0] != nil } }
}

/// A quiet, non-blocking status line for background work. Same material/
/// divider treatment as `SyncProgressBanner`, but slimmer and deliberately
/// inert: unlike a sync it never disables anything, since a first warm of a
/// large library runs for about an hour. Hover for the per-job breakdown.
struct BackgroundWorkStrip: View {
    let store: BackgroundWorkStore

    var body: some View {
        if store.isVisible {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text(summary).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                if !store.active.isEmpty, store.totalWork > 0 {
                    ProgressView(
                        value: Double(max(0, store.totalWork - store.totalRemaining)),
                        total: Double(store.totalWork)
                    )
                    .progressViewStyle(.linear)
                    .frame(width: 90)
                    .controlSize(.small)
                }
            }
            .font(.caption)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .background(.regularMaterial)
            .overlay(alignment: .bottom) { Divider() }
            .help(breakdown)
            .accessibilityElement(children: .combine)
        }
    }

    private var summary: String {
        if let (job, message) = store.errors.sorted(by: { $0.key.label < $1.key.label }).first {
            return "\(job.label.capitalized): \(message)"
        }
        if !store.active.isEmpty {
            var text = "Resolving \(store.labels(of: store.activeJobs)) · \(store.totalRemaining.formatted()) left"
            if store.totalFailedThisRun > 0 { text += " · \(store.totalFailedThisRun.formatted()) couldn’t be resolved" }
            return text
        }
        let failed = store.failures.values.reduce(0, +)
        return "\(failed.formatted()) \(store.labels(of: store.failedJobs)) lookups couldn’t be resolved — they’ll be retried next launch"
    }

    private var breakdown: String {
        var lines = BackgroundWorkStore.Job.allCases.compactMap { job -> String? in
            guard let state = store.active[job] else { return nil }
            return "\(job.label.capitalized): \(state.remaining.formatted()) of \(state.total.formatted()) left"
        }
        lines += BackgroundWorkStore.Job.allCases.compactMap { job in
            store.failures[job].map { "\(job.label.capitalized): \($0.formatted()) couldn’t be resolved" }
        }
        return lines.joined(separator: "\n")
    }
}
