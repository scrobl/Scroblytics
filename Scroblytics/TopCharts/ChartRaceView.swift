import SwiftUI
import SwiftData

struct ChartRaceView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let modelContainer: ModelContainer
    let entity: TopChartsEntity
    let range: DateRange
    let metric: TopChartsMetric
    let onClose: () -> Void

    @State private var timeline: ChartRaceTimeline?
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var progress = 0.0
    @State private var isPlaying = false
    @State private var speed = 1.0
    @State private var rowLimit = 15
    @State private var playbackTask: Task<Void, Never>?

    private let playbackDuration = 36.0
    private let rowHeight: CGFloat = 52

    var body: some View {
        VStack(spacing: 0) {
            ChartRaceControls(
                isPlaying: isPlaying,
                isFinished: progress >= 1,
                speed: $speed,
                rowLimit: $rowLimit,
                onPlayPause: togglePlayback,
                onRestart: restart,
                onClose: onClose
            )
            Divider()

            Group {
                if isLoading {
                    ProgressView("Preparing chart race…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Couldn’t prepare chart race",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                } else if let timeline, !timeline.frames.isEmpty {
                    raceContent(timeline)
                } else {
                    ContentUnavailableView(
                        "No plays in this period",
                        systemImage: "chart.bar.xaxis",
                        description: Text("Try selecting a different date range.")
                    )
                }
            }
        }
        .task(id: loadID) {
            await load()
        }
        .onChange(of: speed) {
            if isPlaying { startPlayback() }
        }
        .onDisappear {
            playbackTask?.cancel()
        }
    }

    private var loadID: String {
        "\(entity.rawValue)|\(metric.rawValue)|\(range.from.timeIntervalSinceReferenceDate)|\(range.to.timeIntervalSinceReferenceDate)"
    }

    private func raceContent(_ timeline: ChartRaceTimeline) -> some View {
        GeometryReader { _ in
            let rows = timeline.rows(at: progress, limit: rowLimit)
            let date = timeline.date(at: progress)

            VStack(spacing: 12) {
                HStack {
                    Text(date, format: .dateTime.month(.abbreviated).day().year())
                        .font(AppTypography.sectionTitle)
                        .contentTransition(.numericText())
                    Spacer()
                    Text(metric == .scrobbles ? "Plays" : "Time listened")
                        .font(AppTypography.metadata)
                        .foregroundStyle(.secondary)
                }

                ScrollView {
                    ZStack(alignment: .topLeading) {
                        if progress == 0, !isPlaying {
                            ContentUnavailableView(
                                "Ready to race",
                                systemImage: "flag.checkered",
                                description: Text("Press Play or drag the timeline to explore how the chart changed.")
                            )
                            .frame(maxWidth: .infinity, minHeight: 220)
                        } else {
                            ForEach(rows) { row in
                                let index = rows.firstIndex(where: { $0.id == row.id }) ?? 0
                                ChartRaceRowView(
                                    rank: index + 1,
                                    entity: entity,
                                    row: row,
                                    metric: metric,
                                    maximumValue: timeline.maximumValue
                                )
                                .frame(height: rowHeight)
                                .offset(y: CGFloat(index) * rowHeight)
                                .transition(reduceMotion ? .opacity : .asymmetric(
                                    insertion: .opacity.combined(with: .offset(y: rowHeight)),
                                    removal: .opacity
                                ))
                            }
                        }
                    }
                    .frame(height: max(220, CGFloat(rowLimit) * rowHeight), alignment: .top)
                    .animation(reduceMotion ? .linear(duration: 0.12) : .smooth(duration: 0.32), value: rows.map(\.id))
                }

                Slider(
                    value: Binding(
                        get: { progress },
                        set: { value in
                            pause()
                            progress = value
                        }
                    ),
                    in: 0...1
                )
                .accessibilityLabel("Chart race position")
                .accessibilityValue(date.formatted(date: .abbreviated, time: .omitted))
            }
            .padding()
        }
    }

    @MainActor
    private func load() async {
        pause()
        progress = 0
        isLoading = true
        errorMessage = nil
        do {
            timeline = try await ChartRaceEngine.fetchTimeline(
                container: modelContainer,
                context: modelContext,
                entity: entity,
                range: range,
                metric: metric
            )
        } catch {
            timeline = nil
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            if progress >= 1 { progress = 0 }
            startPlayback()
        }
    }

    private func restart() {
        pause()
        progress = 0
        startPlayback()
    }

    private func pause() {
        playbackTask?.cancel()
        playbackTask = nil
        isPlaying = false
    }

    private func startPlayback() {
        playbackTask?.cancel()
        isPlaying = true
        let initialProgress = progress
        let startedAt = ContinuousClock.now
        let duration = max(0.1, playbackDuration / speed)

        playbackTask = Task { @MainActor in
            while !Task.isCancelled {
                let elapsed = startedAt.duration(to: .now)
                let seconds = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
                progress = min(1, initialProgress + seconds / duration)
                if progress >= 1 {
                    isPlaying = false
                    playbackTask = nil
                    return
                }
                try? await Task.sleep(for: reduceMotion ? .milliseconds(250) : .milliseconds(16))
            }
        }
    }
}

private struct ChartRaceControls: View {
    let isPlaying: Bool
    let isFinished: Bool
    @Binding var speed: Double
    @Binding var rowLimit: Int
    let onPlayPause: () -> Void
    let onRestart: () -> Void
    let onClose: () -> Void

    var body: some View {
        ViewThatFits {
            HStack(spacing: 12) {
                playbackButtons
                Spacer(minLength: 8)
                rowPicker
                speedPicker
                closeButton
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    playbackButtons
                    Spacer()
                    closeButton
                }
                HStack {
                    rowPicker
                    Spacer()
                    speedPicker
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var playbackButtons: some View {
        HStack(spacing: 8) {
            Button(action: onPlayPause) {
                Label(
                    isFinished ? "Replay" : (isPlaying ? "Pause" : "Play"),
                    systemImage: isFinished ? "arrow.counterclockwise" : (isPlaying ? "pause.fill" : "play.fill")
                )
            }
            .buttonStyle(.borderedProminent)
            .fixedSize()

            Button(action: onRestart) {
                Label("Restart", systemImage: "backward.end.fill")
            }
            .buttonStyle(.bordered)
            .fixedSize()
        }
    }

    private var rowPicker: some View {
        Picker("Visible rows", selection: $rowLimit) {
            ForEach([10, 15, 20, 25], id: \.self) { count in
                Text("\(count) rows").tag(count)
            }
        }
        .fixedSize()
    }

    private var speedPicker: some View {
        Picker("Playback speed", selection: $speed) {
            Text("0.5×").tag(0.5)
            Text("1×").tag(1.0)
            Text("2×").tag(2.0)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 150)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Label("Close race", systemImage: "xmark")
        }
        .labelStyle(.iconOnly)
        .help("Close chart race")
    }
}

private struct ChartRaceRowView: View {
    let rank: Int
    let entity: TopChartsEntity
    let row: ChartRaceRow
    let metric: TopChartsMetric
    let maximumValue: Int

    var body: some View {
        HStack(spacing: 10) {
            Text(rank.formatted())
                .font(AppTypography.tableRank)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 28, alignment: .trailing)

            EntityThumbnail(url: row.entity.imageURL, entity: entity)
                .frame(width: AppArtworkSizing.thumbnail, height: AppArtworkSizing.thumbnail)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.entity.name)
                            .font(AppTypography.contentTitle)
                            .lineLimit(1)
                        if let artist = row.entity.artist {
                            Text(artist)
                                .font(AppTypography.compactMetadata)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(valueLabel)
                        .font(AppTypography.tableValue)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: row.value))
                        .fixedSize()
                }

                GeometryReader { proxy in
                    Capsule()
                        .fill(.quaternary)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(Color.accentColor.gradient)
                                .frame(width: proxy.size.width * min(1, row.value / Double(max(1, maximumValue))))
                        }
                }
                .frame(height: 7)
            }
        }
        .padding(.horizontal, 2)
    }

    private var valueLabel: String {
        let value = Int(row.value.rounded())
        return metric == .scrobbles
            ? value.formatted()
            : DurationEngine.formatTimeListened(value)
    }
}
