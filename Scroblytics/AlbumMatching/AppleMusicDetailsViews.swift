import SwiftUI

/// Settings › Sync › Apple Music library details: the switch (off until turned on), Refresh Now, what was last read, the Last.fm songs that were left out
/// because the library had more than one possible partner for them, and a way to forget what was read.
struct AppleMusicDetailsSettingsSection: View {
    var store = AppleMusicDetailsStore.shared
    @State private var showingUnmatched = false
    @State private var confirmingForget = false

    var body: some View {
        Section("Apple Music library details") {
            Toggle("Keep date added, genre, tempo and length from Apple Music", isOn: Binding(get: { store.enabled }, set: { store.setEnabled($0) }))
            if store.enabled {
                HStack(alignment: .firstTextBaseline) {
                    Button("Refresh Now") { store.refresh(force: true) }.disabled(store.isReading)
                    Text(store.statusText)
                        .font(AppTypography.supporting).foregroundStyle(store.problem == nil ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !store.unmatched.isEmpty {
                    Button("Songs that couldn’t be matched (\(store.unmatched.count.formatted()))…") { showingUnmatched = true }
                        .help("Last.fm songs the library has more than one possible partner for. Nothing is taken from Music for them.")
                }
            }
            if store.readAt != nil {
                Button("Forget What Was Read…", role: .destructive) { confirmingForget = true }
            }
            Text("Reads from your Music library, while Music is open and after a sync, when each song was added to it, its genre, its tempo tag and its length, and keeps them on this Mac. Query can then ask about them, song, album and artist pages show them, and a tempo tag or length fills in where none was found online. It reads when the number of songs changes or the last read is over 12 hours old. Songs are matched to Last.fm by exact title; where the library has several possible partners, nothing is taken. Nothing leaves your Mac.")
                .font(AppTypography.supporting).foregroundStyle(.secondary)
            HelpLinkButton(articleID: "apple-music-details", title: "About Apple Music library details")
        }
        .sheet(isPresented: $showingUnmatched) { AppleMusicUnmatchedSheet(songs: store.unmatched) }
        .confirmationDialog("Forget what was read from Apple Music?", isPresented: $confirmingForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive) { store.forget() }
        } message: {
            Text("Date added and genre disappear from Query and the pages, and Apple Music tempos are no longer used, until the library is read again.")
        }
    }
}

/// The Last.fm songs that were skipped because the library had several possible partners, most played first.
struct AppleMusicUnmatchedSheet: View {
    let songs: [AppleMusicDetailsIndex.Unmatched]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Songs that couldn’t be matched").font(AppTypography.sectionTitle)
            Text("Each of these Last.fm songs has no identical title in your Music library, and the library has more than one title it could be, so nothing was taken from Music for it. Make the titles agree (or fix the scrobble) and they match at the next read.")
                .font(AppTypography.supporting).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List(songs) { song in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("\(song.artist) — \(song.track)").lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(song.plays.formatted()) \(song.plays == 1 ? "play" : "plays")").font(AppTypography.compactMetadata).foregroundStyle(.secondary)
                    }
                    Text("Could be: " + song.candidates.joined(separator: "  ·  ")).font(AppTypography.compactMetadata).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .listStyle(.bordered)
            .frame(minHeight: 220, maxHeight: 360)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent) }
        }
        .padding(20)
        .frame(width: 560)
    }
}
