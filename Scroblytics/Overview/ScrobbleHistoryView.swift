import SwiftData
import SwiftUI

struct ScrobbleHistoryRoute: Hashable {}

private struct ScrobbleHistoryCursor: Sendable {
    let playedAt: Date
    let artist: String
    let track: String
}

private struct ScrobbleHistoryRow: Identifiable, Sendable {
    let artist: String
    let album: String?
    let track: String
    let imageURL: String?
    let playedAt: Date

    var id: String {
        "\(playedAt.timeIntervalSince1970)\u{0}\(artist)\u{0}\(track)"
    }
}

private struct ScrobbleHistoryPage: Sendable {
    let rows: [ScrobbleHistoryRow]
    let nextCursor: ScrobbleHistoryCursor?
    let hasMore: Bool
}

@ModelActor
private actor ScrobbleHistoryReader {
    func count() throws -> Int {
        try modelContext.checkedCount(FetchDescriptor<Scrobble>())
    }

    func page(
        after cursor: ScrobbleHistoryCursor?,
        startingBefore upperBound: Date?,
        limit: Int
    ) throws -> ScrobbleHistoryPage {
        var descriptor: FetchDescriptor<Scrobble>

        if let cursor {
            let playedAt = cursor.playedAt
            let artist = cursor.artist
            let track = cursor.track
            descriptor = FetchDescriptor<Scrobble>(
                predicate: #Predicate {
                    $0.playedAt < playedAt
                        || ($0.playedAt == playedAt && $0.artistName < artist)
                        || ($0.playedAt == playedAt && $0.artistName == artist && $0.trackName < track)
                },
                sortBy: [
                    SortDescriptor(\.playedAt, order: .reverse),
                    SortDescriptor(\.artistName, order: .reverse),
                    SortDescriptor(\.trackName, order: .reverse)
                ]
            )
        } else if let upperBound {
            descriptor = FetchDescriptor<Scrobble>(
                predicate: #Predicate { $0.playedAt < upperBound },
                sortBy: [
                    SortDescriptor(\.playedAt, order: .reverse),
                    SortDescriptor(\.artistName, order: .reverse),
                    SortDescriptor(\.trackName, order: .reverse)
                ]
            )
        } else {
            descriptor = FetchDescriptor<Scrobble>(
                sortBy: [
                    SortDescriptor(\.playedAt, order: .reverse),
                    SortDescriptor(\.artistName, order: .reverse),
                    SortDescriptor(\.trackName, order: .reverse)
                ]
            )
        }

        descriptor.fetchLimit = limit + 1
        let fetched = try modelContext.fetch(descriptor)
        let hasMore = fetched.count > limit
        let rows = fetched.prefix(limit).map {
            ScrobbleHistoryRow(
                artist: $0.artistName,
                album: $0.albumName.isEmpty ? nil : $0.albumName,
                track: $0.trackName,
                imageURL: $0.imageURL,
                playedAt: $0.playedAt
            )
        }
        let nextCursor = rows.last.map {
            ScrobbleHistoryCursor(playedAt: $0.playedAt, artist: $0.artist, track: $0.track)
        }
        return ScrobbleHistoryPage(rows: rows, nextCursor: nextCursor, hasMore: hasMore)
    }
}

struct ScrobbleHistoryView: View {
    let modelContainer: ModelContainer

    @State private var rows: [ScrobbleHistoryRow] = []
    @State private var cursor: ScrobbleHistoryCursor?
    @State private var totalCount: Int?
    @State private var hasMore = true
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var jumpDate = Date()
    @State private var upperBound: Date?
    @State private var showsDatePicker = false
    @State private var listIdentity = UUID()

    private let pageSize = 200

    var body: some View {
        Group {
            if rows.isEmpty && isLoading {
                ProgressView("Loading scrobbles…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty, let errorMessage {
                ContentUnavailableView {
                    Label("Couldn’t Load Scrobbles", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") {
                        Task { await resetAndLoad() }
                    }
                }
            } else {
                historyList
                    .id(listIdentity)
            }
        }
        .navigationTitle("Scrobble History")
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            if rows.isEmpty {
                await loadInitialData()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .scrobbleSyncDidComplete)) { _ in
            Task {
                await resetAndLoad()
                await loadTotalCount()
            }
        }
    }

    private var historyList: some View {
        List {
            HStack {
                Text(countText)
                    .font(AppTypography.sectionTitle)
                Spacer()
                if upperBound != nil {
                    Button("Return to Latest") {
                        Task { await resetAndLoad(startingBefore: nil) }
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    showsDatePicker.toggle()
                } label: {
                    Label("Jump to Date", systemImage: "calendar")
                }
                .popover(isPresented: $showsDatePicker, arrowEdge: .trailing) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Jump to date")
                            .font(.headline)
                        DatePicker(
                            "Date",
                            selection: $jumpDate,
                            in: ...Date(),
                            displayedComponents: .date
                        )
                        .labelsHidden()
                        Button("Jump") {
                            showsDatePicker = false
                            Task { await jump(to: jumpDate) }
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                    .padding()
                }
            }
            .listRowSeparator(.hidden)

            ForEach(rows) { row in
                NavigationLink(
                    value: TrackIdentity(
                        artist: row.artist,
                        name: row.track,
                        album: row.album,
                        imageURL: row.imageURL
                    )
                ) {
                    ScrobbleHistoryListRow(row: row)
                }
                .drillDownHighlight()
                .entityContextMenu(
                    target: ImageTarget(
                        kind: .track,
                        artist: row.artist,
                        album: row.album,
                        track: row.track
                    ),
                    currentImageURL: row.imageURL
                )
            }

            if hasMore {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Spacer()
                }
                .listRowSeparator(.hidden)
                .task(id: cursor?.playedAt) {
                    await loadNextPage()
                }
            } else if !rows.isEmpty {
                Text("\(rows.count.formatted()) scrobbles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
            }

            if let errorMessage, !rows.isEmpty {
                HStack {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry") {
                        Task { await loadNextPage() }
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private var countText: String {
        if let totalCount {
            return "\(totalCount.formatted()) scrobbles"
        }
        return "Scrobbles"
    }

    @MainActor
    private func loadInitialData() async {
        await loadTotalCount()
        await loadNextPage()
    }

    @MainActor
    private func loadTotalCount() async {
        let container = modelContainer
        do {
            totalCount = try await offMain {
                try await ScrobbleHistoryReader(modelContainer: container).count()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func loadNextPage() async {
        guard hasMore, !isLoading else { return }
        isLoading = true
        errorMessage = nil

        do {
            let currentCursor = cursor
            let currentUpperBound = upperBound
            let limit = pageSize
            let container = modelContainer
            let page = try await offMain {
                try await ScrobbleHistoryReader(modelContainer: container)
                    .page(after: currentCursor, startingBefore: currentUpperBound, limit: limit)
            }
            rows.append(contentsOf: page.rows)
            cursor = page.nextCursor
            hasMore = page.hasMore
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    @MainActor
    private func resetAndLoad(startingBefore newUpperBound: Date? = nil) async {
        rows = []
        cursor = nil
        upperBound = newUpperBound
        hasMore = true
        errorMessage = nil
        listIdentity = UUID()
        await loadNextPage()
    }

    @MainActor
    private func jump(to date: Date) async {
        let startOfDay = Calendar.current.startOfDay(for: date)
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay) ?? date
        await resetAndLoad(startingBefore: nextDay)
    }
}

private struct ScrobbleHistoryListRow: View {
    let row: ScrobbleHistoryRow

    var body: some View {
        HStack(spacing: 12) {
            ArtworkImage(urlString: row.imageURL, contentMode: .fill) {
                Color.clear
                    .overlay {
                        Image(systemName: "music.note")
                            .foregroundStyle(.tertiary)
                    }
            }
            .frame(width: AppArtworkSizing.thumbnail, height: AppArtworkSizing.thumbnail)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(row.track)
                        .font(AppTypography.contentTitle)
                        .lineLimit(1)
                    TrackLovedIndicator(
                        artist: row.artist,
                        track: row.track,
                        initialValue: false,
                        font: AppTypography.metadata
                    )
                }
                Text(row.album.map { "\(row.artist) · \($0)" } ?? row.artist)
                    .font(AppTypography.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Text(row.playedAt, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                .font(AppTypography.metadata)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
