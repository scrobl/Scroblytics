import AppKit
import SwiftUI

/// Turns a card into pixels. Main actor (SwiftUI's renderer is); pictures are loaded before it starts.
@MainActor
enum ShareRenderer {
    /// The PNG for `card` at `options.size` times `scale` (2 gives 2160 × 2160 for a square card).
    static func png(card: ShareCard, options: ShareOptions, identity: ShareIdentity, images: [String: NSImage], scale: CGFloat = 2) -> Data? {
        // Straight from the renderer's bitmap: going through an NSImage's TIFF and back kept a full copy of the picture alive for every
        // export (about 30 MB at full size, never given back).
        guard let bitmap = cgImage(card: card, options: options, identity: identity, images: images, scale: scale) else { return nil }
        return NSBitmapImageRep(cgImage: bitmap).representation(using: .png, properties: [:])
    }

    static func nsImage(card: ShareCard, options: ShareOptions, identity: ShareIdentity, images: [String: NSImage], scale: CGFloat) -> NSImage? {
        renderer(card: card, options: options, identity: identity, images: images, scale: scale).nsImage
    }

    private static func cgImage(card: ShareCard, options: ShareOptions, identity: ShareIdentity, images: [String: NSImage], scale: CGFloat) -> CGImage? {
        renderer(card: card, options: options, identity: identity, images: images, scale: scale).cgImage
    }

    private static func renderer(card: ShareCard, options: ShareOptions, identity: ShareIdentity, images: [String: NSImage], scale: CGFloat) -> ImageRenderer<ShareCardView> {
        let view = ShareCardView(card: card, options: options, identity: identity, images: images)
        let renderer = ImageRenderer(content: view)
        // A fitted chart card has a width and takes the height its content needs.
        renderer.proposedSize = card.fitsChart(for: options) ? ProposedViewSize(width: card.fittedWidth, height: nil) : ProposedViewSize(options.size.points)
        renderer.scale = scale
        return renderer
    }

    /// The pictures a card with these options will draw.
    static func imageURLs(card: ShareCard, options: ShareOptions) -> [String?] {
        card.pictureURLs(for: options)
    }
}
