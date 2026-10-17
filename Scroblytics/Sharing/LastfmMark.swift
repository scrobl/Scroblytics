import SwiftUI

/// Which Last.fm mark the app shows: the red circle (the artwork Last.fm uses for itself), its "last.fm" wordmark, a simple badge drawn
/// in code, or none. In front of a name on a shared card, and on the Now Playing bar. Chosen in Settings › General › Sharing.
enum LastfmLogoStyle: String, CaseIterable, Identifiable, Sendable {
    case circle, wordmark, badge, none

    var id: String { rawValue }
    var label: String {
        switch self {
        case .circle: "Last.fm logo (red circle)"
        case .wordmark: "Last.fm wordmark"
        case .badge: "Simple badge"
        case .none: "None"
        }
    }
}

/// A small Last.fm mark in the chosen style. The badge is drawn here (white "as" on Last.fm red) so it needs no image file; the circle
/// and the wordmark are artwork from the asset catalog. The wordmark is a single-colour shape drawn in the surrounding text colour, so
/// it reads on a dark card and in either appearance of the app. `size` is the circle's and badge's side; the wordmark is a little
/// shorter than that, at its own proportions.
struct LastfmMark: View {
    var size: CGFloat = 28
    /// False draws the badge in the surrounding secondary style instead of red (for quiet chrome).
    var isRed = true
    var style = LastfmLogoStyle.badge

    /// Width over height of the wordmark artwork.
    static let wordmarkAspect: CGFloat = 352.0 / 96.0

    private static let red = Color(red: 0.835, green: 0.063, blue: 0.027)

    var body: some View {
        switch style {
        case .none:
            EmptyView()
        case .circle:
            Image("LastfmLogo")
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .accessibilityLabel("Last.fm")
        case .wordmark:
            Image("LastfmWordmark")
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .aspectRatio(Self.wordmarkAspect, contentMode: .fit)
                .foregroundStyle(.primary.opacity(0.92))
                .frame(height: size * 0.95)
                .accessibilityLabel("Last.fm")
        case .badge:
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(isRed ? Self.red : Color.secondary.opacity(0.85))
                Text("as")
                    .font(.system(size: size * 0.62, weight: .heavy, design: .rounded))
                    .foregroundStyle(isRed ? Color.white : Color(nsColor: .windowBackgroundColor))
                    .offset(y: -size * 0.03)
            }
            .frame(width: size, height: size)
            .accessibilityLabel("Last.fm")
        }
    }
}
