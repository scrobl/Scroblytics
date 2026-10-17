import SwiftUI
import SwiftData

struct NowPlayingShelf: View {
    let track: NowPlayingTrack
    let onOpen: () -> Void
    let onDismiss: () -> Void

    @Environment(\.modelContext) private var modelContext
    /// The artwork every other screen shows for this track (your own image, a saved or inherited album image), falling back to what
    /// Last.fm reported for the play, which can be another edition's cover.
    @State private var resolvedImageURL: String?
    @AppStorage(ShareSettings.logoKey) private var logoRaw = LastfmLogoStyle.circle.rawValue

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    ArtworkImage(urlString: resolvedImageURL ?? track.imageURL, contentMode: .fill) {
                        ZStack {
                            Color.secondary.opacity(0.12)
                            Image(systemName: "music.note")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 48, height: 48)
                    .clipShape(.rect(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(.green)
                                .frame(width: 7, height: 7)
                                .accessibilityHidden(true)
                            Text("Now Playing")
                                .font(AppTypography.metadata)
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 4) {
                            Text(track.track)
                                .font(AppTypography.sectionTitle)
                                .lineLimit(1)
                            TrackFlaggedIndicator(
                                artist: track.artist,
                                track: track.track,
                                font: AppTypography.metadata
                            )
                        }

                        Text(detail)
                            .font(AppTypography.metadata)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 12)

                    LastfmMark(size: 22, style: LastfmLogoStyle(rawValue: logoRaw) ?? .circle)
                        .accessibilityHidden(true)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint("Opens track details")

            Button("Hide Now Playing", systemImage: "xmark", action: onDismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(.rect)
                .help("Hide Now Playing")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .task(id: track.id) { reloadImage() }
        .onReceive(NotificationCenter.default.publisher(for: .imageDidChange)) { _ in reloadImage() }
    }

    private func reloadImage() {
        let target = ImageTarget(kind: .track, artist: track.artist, album: track.album.isEmpty ? nil : track.album, track: track.track)
        resolvedImageURL = (try? ImageResolutionEngine.effectiveImageURL(for: target, context: modelContext, fallbackURL: track.imageURL)) ?? nil
    }

    private var detail: String {
        track.album.isEmpty ? track.artist : "\(track.artist) — \(track.album)"
    }

    private var accessibilityLabel: String {
        track.album.isEmpty
            ? "Now playing, \(track.track), by \(track.artist)"
            : "Now playing, \(track.track), by \(track.artist), from \(track.album)"
    }
}
