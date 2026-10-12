import AppKit
import SwiftData
import SwiftUI

struct AppleMusicPlaylistTrack: Hashable, Sendable {
    let artist: String
    let track: String
    let album: String
}

enum AppleMusicPlaylistBuilder {
    @MainActor
    static func tracks(
        for entries: [TopChartEntry],
        entity: TopChartsEntity,
        range: DateRange,
        metric: TopChartsMetric,
        container: ModelContainer,
        context: ModelContext,
        perEntityLimit: Int = 50,
        totalLimit: Int = 1_000
    ) async throws -> [AppleMusicPlaylistTrack] {
        let scrobbles = try await ScrobbleHistoryCache.shared.snapshots(container: container)
        let durations = DurationEngine.loadSnapshot(context: context).secondsLookup
        return await Task.detached(priority: .userInitiated) {
            let inRange = scrobbles.filter { $0.playedAt >= range.from && $0.playedAt <= range.to }
            var output: [AppleMusicPlaylistTrack] = []
            var exportedKeys = Set<String>()

            for entry in entries where output.count < totalLimit {
                let matching = inRange.filter { scrobble in
                    switch entity {
                    case .artist:
                        return scrobble.artistName == entry.name
                    case .album:
                        guard let artist = entry.artist else { return false }
                        return scrobble.albumName == entry.name
                            && TextNormalization.trackMatchesArtistContext(
                                trackArtist: scrobble.artistName,
                                context: artist
                            )
                    case .track:
                        return scrobble.trackName == entry.name && scrobble.artistName == entry.artist
                    }
                }

                struct Candidate {
                    var track: AppleMusicPlaylistTrack
                    var score: Int
                    var latestPlay: Date
                }
                var candidates: [String: Candidate] = [:]
                for scrobble in matching {
                    let key = "\(TextNormalization.artistIdentityKey(scrobble.artistName))\u{0}\(TextNormalization.normalizeTrackTitle(scrobble.trackName))"
                    let score = metric == .scrobbles
                        ? 1
                        : durations[DurationEngine.cacheKey(artist: scrobble.artistName, track: scrobble.trackName), default: 0]
                    if var candidate = candidates[key] {
                        candidate.score += score
                        if scrobble.playedAt > candidate.latestPlay {
                            candidate.latestPlay = scrobble.playedAt
                            candidate.track = AppleMusicPlaylistTrack(
                                artist: scrobble.artistName,
                                track: scrobble.trackName,
                                album: scrobble.albumName
                            )
                        }
                        candidates[key] = candidate
                    } else {
                        candidates[key] = Candidate(
                            track: AppleMusicPlaylistTrack(
                                artist: scrobble.artistName,
                                track: scrobble.trackName,
                                album: scrobble.albumName
                            ),
                            score: score,
                            latestPlay: scrobble.playedAt
                        )
                    }
                }

                let ranked = candidates.values.sorted { lhs, rhs in
                    if lhs.score != rhs.score { return lhs.score > rhs.score }
                    return lhs.track.track.localizedStandardCompare(rhs.track.track) == .orderedAscending
                }
                for candidate in ranked.prefix(perEntityLimit) {
                    let key = "\(TextNormalization.artistIdentityKey(candidate.track.artist))\u{0}\(TextNormalization.normalizeTrackTitle(candidate.track.track))"
                    guard exportedKeys.insert(key).inserted else { continue }
                    output.append(candidate.track)
                    if output.count == totalLimit { break }
                }
            }
            return output
        }.value
    }
}

enum AppleMusicPlaylistExporter {
    enum Mode: String, Sendable {
        case new
        case existing
    }

    struct Result: Sendable {
        let added: Int
        let notFound: [String]
    }

    enum ExportError: Error, LocalizedError {
        case noTracks
        case notAuthorized
        case scriptFailed(String)

        var errorDescription: String? {
            switch self {
            case .noTracks:
                "There are no tracks to export."
            case .notAuthorized:
                "Scroblytics isn’t authorized to control Music.app. Grant access in System Settings > Privacy & Security > Automation."
            case .scriptFailed(let message):
                "Couldn’t create the Apple Music playlist: \(message)"
            }
        }
    }

    private static let fieldSeparator = "\u{241F}"
    private static let entrySeparator = "\u{241E}"

    static func playlistExists(named name: String) async throws -> Bool {
        let script = """
        on run argv
          set playlistName to item 1 of argv
          tell application "Music"
            return (count of (every user playlist whose name is playlistName)) as string
          end tell
        end run
        """
        let output = try await runAppleScript(script, arguments: [name])
        return (Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0
    }

    static func export(
        name: String,
        tracks: [AppleMusicPlaylistTrack],
        mode: Mode
    ) async throws -> Result {
        guard !tracks.isEmpty else { throw ExportError.noTracks }
        let trackList = tracks.map { track in
            "{tn:\"\(escape(track.track.trimmingCharacters(in: .whitespacesAndNewlines)))\", ta:\"\(escape(track.artist.trimmingCharacters(in: .whitespacesAndNewlines)))\", al:\"\(escape(track.album.trimmingCharacters(in: .whitespacesAndNewlines)))\"}"
        }.joined(separator: ", ")

        let script = """
        on trimText(t)
          set t to t as string
          repeat while (length of t > 0) and (t begins with " ")
            set t to text 2 thru (length of t) of t
          end repeat
          repeat while (length of t > 0) and (t ends with " ")
            set t to text 1 thru ((length of t) - 1) of t
          end repeat
          return t
        end trimText

        on run argv
          set playlistName to item 1 of argv
          set exportMode to item 2 of argv
          set trackList to {\(trackList)}
          set addedCount to 0
          set notFoundList to {}
          tell application "Music"
            set targetPlaylist to missing value
            if exportMode is "existing" then
              set matchingPlaylists to (every user playlist whose name is playlistName)
              if (count of matchingPlaylists) > 0 then set targetPlaylist to item 1 of matchingPlaylists
            end if
            if targetPlaylist is missing value then
              set targetPlaylist to make new user playlist with properties {name:playlistName}
            end if
            repeat with trackInfo in trackList
              set targetName to tn of trackInfo
              set targetArtist to ta of trackInfo
              set targetAlbum to al of trackInfo
              set candidates to {}
              try
                set foundCandidates to (search library playlist 1 for targetName only songs)
                if foundCandidates is not missing value then set candidates to foundCandidates
              end try
              set bestTrack to missing value
              set fallbackTrack to missing value
              repeat with candidate in candidates
                set candidateName to ""
                set candidateArtist to ""
                try
                  set candidateName to name of candidate
                  set candidateArtist to artist of candidate
                end try
                if my trimText(candidateName) is targetName and my trimText(candidateArtist) is targetArtist then
                  if fallbackTrack is missing value then set fallbackTrack to candidate
                  if targetAlbum is not "" then
                    set candidateAlbum to ""
                    try
                      set candidateAlbum to album of candidate
                    end try
                    if my trimText(candidateAlbum) is targetAlbum then
                      set bestTrack to candidate
                      exit repeat
                    end if
                  else
                    set bestTrack to candidate
                    exit repeat
                  end if
                end if
              end repeat
              if bestTrack is missing value then set bestTrack to fallbackTrack
              if bestTrack is not missing value then
                duplicate bestTrack to targetPlaylist
                set addedCount to addedCount + 1
              else
                set end of notFoundList to (targetArtist & " - " & targetName)
              end if
            end repeat
          end tell
          set AppleScript's text item delimiters to "\(entrySeparator)"
          set notFoundText to notFoundList as string
          set AppleScript's text item delimiters to ""
          return (addedCount as string) & "\(fieldSeparator)" & notFoundText
        end run
        """

        let output = try await runAppleScript(script, arguments: [name, mode.rawValue])
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: fieldSeparator)
        let added = parts.first.flatMap(Int.init) ?? 0
        let notFound = parts.count > 1 && !parts[1].isEmpty
            ? parts[1].components(separatedBy: entrySeparator)
            : []
        return Result(added: added, notFound: notFound)
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func runAppleScript(_ script: String, arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script] + arguments
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            process.terminationHandler = { process in
                let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if process.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else if error.contains("-1743") || error.localizedCaseInsensitiveContains("not authorized") || error.localizedCaseInsensitiveContains("not allowed") {
                    continuation.resume(throwing: ExportError.notAuthorized)
                } else {
                    continuation.resume(throwing: ExportError.scriptFailed(error.isEmpty ? "exit \(process.terminationStatus)" : error))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: ExportError.scriptFailed(error.localizedDescription))
            }
        }
    }
}

struct AppleMusicPlaylistExportButton: View {
    let defaultPlaylistName: String
    let tracks: @MainActor () async throws -> [AppleMusicPlaylistTrack]

    @State private var playlistName = ""
    @State private var pendingTracks: [AppleMusicPlaylistTrack] = []
    @State private var isNamingPlaylist = false
    @State private var isCheckingOrExporting = false
    @State private var isResolvingConflict = false
    @State private var result: AppleMusicPlaylistExporter.Result?
    @State private var errorMessage: String?

    var body: some View {
        Button {
            playlistName = defaultPlaylistName
            isNamingPlaylist = true
        } label: {
            Label("Create Apple Music Playlist", systemImage: "music.note.list")
        }
        .disabled(isCheckingOrExporting)
        .sheet(isPresented: $isNamingPlaylist) {
            AppleMusicPlaylistNameSheet(
                playlistName: $playlistName,
                isWorking: isCheckingOrExporting,
                onCancel: { isNamingPlaylist = false },
                onExport: requestExport
            )
            .interactiveDismissDisabled(isCheckingOrExporting)
            .confirmationDialog(
                "Playlist Already Exists",
                isPresented: $isResolvingConflict,
                titleVisibility: .visible
            ) {
                Button("Add to Existing") { performExport(mode: .existing) }
                Button("Create New Playlist") { performExport(mode: .new) }
                Button("Cancel", role: .cancel) { pendingTracks = [] }
            } message: {
                Text("A playlist named “\(playlistName)” already exists in Music.app. Add these tracks to it, or create another playlist with the same name?")
            }
        }
        .sheet(isPresented: Binding(
            get: { result != nil },
            set: { if !$0 { result = nil } }
        )) {
            if let result {
                AppleMusicPlaylistResultSheet(
                    playlistName: playlistName,
                    result: result,
                    onCopyMissing: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result.notFound.joined(separator: "\n"), forType: .string)
                    },
                    onDismiss: { self.result = nil }
                )
            }
        }
        .alert("Export Failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func requestExport() {
        let name = playlistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        isCheckingOrExporting = true
        Task {
            do {
                pendingTracks = try await tracks()
                guard !pendingTracks.isEmpty else { throw AppleMusicPlaylistExporter.ExportError.noTracks }
                let exists = (try? await AppleMusicPlaylistExporter.playlistExists(named: name)) ?? false
                isCheckingOrExporting = false
                if exists {
                    isResolvingConflict = true
                } else {
                    performExport(mode: .new)
                }
            } catch {
                isCheckingOrExporting = false
                isNamingPlaylist = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func performExport(mode: AppleMusicPlaylistExporter.Mode) {
        let name = playlistName.trimmingCharacters(in: .whitespacesAndNewlines)
        let tracks = pendingTracks
        isResolvingConflict = false
        isCheckingOrExporting = true
        Task {
            do {
                let exportResult = try await AppleMusicPlaylistExporter.export(name: name, tracks: tracks, mode: mode)
                pendingTracks = []
                isCheckingOrExporting = false
                isNamingPlaylist = false
                result = exportResult
            } catch {
                pendingTracks = []
                isCheckingOrExporting = false
                isNamingPlaylist = false
                errorMessage = error.localizedDescription
            }
        }
    }

}

private struct AppleMusicPlaylistResultSheet: View {
    let playlistName: String
    let result: AppleMusicPlaylistExporter.Result
    let onCopyMissing: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Apple Music Playlist", systemImage: "checkmark.circle.fill")
                .font(AppTypography.sectionTitle)
                .foregroundStyle(.green)

            Text("Added \(result.added.formatted()) of \((result.added + result.notFound.count).formatted()) tracks to “\(playlistName)”.")
                .font(AppTypography.contentTitle)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            if !result.notFound.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Not in your library (\(result.notFound.count.formatted()))")
                        .font(AppTypography.metadata)
                        .foregroundStyle(.secondary)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(Array(result.notFound.enumerated()), id: \.offset) { _, name in
                                Text(name)
                                    .font(AppTypography.metadata)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 240)
                }
            }

            HStack {
                if !result.notFound.isEmpty {
                    Button("Copy Missing Names", action: onCopyMissing)
                }
                Spacer()
                Button("OK", action: onDismiss)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 620)
    }
}

private struct AppleMusicPlaylistNameSheet: View {
    @Binding var playlistName: String
    let isWorking: Bool
    let onCancel: () -> Void
    let onExport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export to Apple Music")
                .font(AppTypography.sectionTitle)
            Text("Creates a playlist from matching tracks already in your Music.app library. Tracks that aren’t in your library are skipped.")
                .font(AppTypography.metadata)
                .foregroundStyle(.secondary)
            TextField("Playlist name", text: $playlistName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(onExport)
                .disabled(isWorking)
            HStack {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                    Text("Exporting…")
                        .font(AppTypography.metadata)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .disabled(isWorking)
                Button("Export", action: onExport)
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking || playlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
