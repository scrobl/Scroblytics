import SwiftUI

/// A small Last.fm badge: white "as" on Last.fm red, drawn here so it needs no image file and renders the same everywhere (an image
/// renderer included). It stands in front of a Last.fm name. If the official artwork is preferred, replace this view's body with it.
struct LastfmMark: View {
    var size: CGFloat = 28
    /// False draws it in the surrounding secondary style instead of red (for quiet chrome).
    var isRed = true

    private static let red = Color(red: 0.835, green: 0.063, blue: 0.027)

    var body: some View {
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
