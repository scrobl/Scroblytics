import AppKit
import SwiftUI

/// Turns a card into pixels. Main actor (SwiftUI's renderer is); pictures are loaded before it starts.
@MainActor
enum ShareRenderer {
    /// The PNG for `card` at `options.size` times `scale` (2 gives 2160 × 2160 for a square card).
    static func png(card: ShareCard, options: ShareOptions, identity: ShareIdentity, images: [String: NSImage], scale: CGFloat = 2) -> Data? {
        guard let image = nsImage(card: card, options: options, identity: identity, images: images, scale: scale),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    static func nsImage(card: ShareCard, options: ShareOptions, identity: ShareIdentity, images: [String: NSImage], scale: CGFloat) -> NSImage? {
        let view = ShareCardView(card: card, options: options, identity: identity, images: images)
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(options.size.points)
        renderer.scale = scale
        return renderer.nsImage
    }

    /// The pictures a card with these options will draw.
    static func imageURLs(card: ShareCard, options: ShareOptions) -> [String?] {
        card.pictureURLs(for: options)
    }
}
