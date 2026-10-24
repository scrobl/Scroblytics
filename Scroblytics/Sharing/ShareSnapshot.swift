import AppKit
import SwiftUI

/// A picture of part of the live window, taken when the person presses Share. Trends' charts compute their own data and draw it inside
/// the view, so the card is made from what is on screen: the chart exactly as it is drawn, with its title and period around it.
/// (Equal only to itself: two snapshots are two pictures.)
final class ShareSnapshot: @unchecked Sendable, Equatable {
    let image: NSImage

    init(image: NSImage) { self.image = image }

    static func == (a: ShareSnapshot, b: ShareSnapshot) -> Bool { a === b }
}

/// What a chart says in words above its graphic ("12,345 scrobbles", "+8% vs last year"): the card prints it above the picture, since the
/// picture alone has the shape of the data but not its size.
struct ShareChartSummary: Equatable, Sendable {
    var headline: String
    /// "+8% vs Jan 1, 2025 – Oct 17, 2025"; coloured green or red by `isUp`.
    var change: String?
    var isUp = true
    /// A plain second line (not a comparison), in a neutral colour.
    var detail: String? = nil
    /// What the colours in the picture mean, when the picture alone doesn't say (a green area and a dashed purple line).
    var legend: [Legend] = []

    struct Legend: Equatable, Sendable {
        var label: String
        var color: Color
        /// A short line (a series) rather than a dot.
        var isLine = false
    }
}

/// Finds a region of the window by an anchor view placed behind a chart, and takes its picture.
@MainActor
@Observable
final class ShareChartCapture {
    @ObservationIgnored fileprivate weak var anchor: NSView?
    /// Whether a chart has put its anchor on screen (a section showing "not enough data" has none, so there is nothing to share).
    private(set) var hasChart = false
    /// The chart's headline numbers, set by the chart when it has computed them (nil for a chart that has none to give).
    var summary: ShareChartSummary?
    /// The chart drawn for a card, when it can be (the Share button then makes that instead of a picture of the window).
    var native: ShareNativeChart?

    fileprivate func register(_ view: NSView) {
        anchor = view
        hasChart = true
    }

    fileprivate func unregister(_ view: NSView) {
        guard anchor === view else { return }
        anchor = nil
        hasChart = false
    }

    /// The anchored region as an image, on the window's own background so it reads as drawn. Nil when the chart isn't on screen.
    func image() -> NSImage? {
        guard let anchor, let window = anchor.window, anchor.bounds.width > 20, anchor.bounds.height > 20 else { return nil }
        // A chart further down a scrolling page is only partly on screen. Take the picture from the page itself (the scroll view's whole
        // content), not from the window, so the part that is scrolled out of view is drawn too.
        let content = anchor.enclosingScrollView?.documentView ?? window.contentView
        guard let content else { return nil }
        // A little beyond the chart's frame, since the top axis label and the date labels overhang it (not so far as the controls above).
        let rect = anchor.convert(anchor.bounds, to: content).insetBy(dx: -4, dy: -8).intersection(content.bounds)
        guard !rect.isEmpty, let rep = content.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        content.cacheDisplay(in: rect, to: rep)
        let size = rect.size
        // The chart panel's own background is a material that draws nothing off screen; put the picture on the window's background colour,
        // keeping the picture's own pixel density (twice the points on a Retina screen).
        var background = NSColor.windowBackgroundColor
        content.effectiveAppearance.performAsCurrentDrawingAppearance { background = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? background }
        guard let flat = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: flat) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        background.setFill()
        NSRect(x: 0, y: 0, width: flat.pixelsWide, height: flat.pixelsHigh).fill()
        rep.draw(in: NSRect(x: 0, y: 0, width: flat.pixelsWide, height: flat.pixelsHigh))
        NSGraphicsContext.restoreGraphicsState()
        let flattened = NSImage(size: size)
        flattened.addRepresentation(flat)
        return flattened
    }
}

private struct ShareChartCaptureKey: EnvironmentKey {
    static let defaultValue: ShareChartCapture? = nil
}

extension EnvironmentValues {
    /// Where the chart inside a Trends section registers the part of itself that a shared card should show.
    var shareChartCapture: ShareChartCapture? {
        get { self[ShareChartCaptureKey.self] }
        set { self[ShareChartCaptureKey.self] = newValue }
    }
}

private struct ShareChartAnchor: NSViewRepresentable {
    let capture: ShareChartCapture?

    final class Coordinator {
        let capture: ShareChartCapture?
        init(_ capture: ShareChartCapture?) { self.capture = capture }
    }

    func makeCoordinator() -> Coordinator { Coordinator(capture) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // Registering changes what the section shows, so it waits until the view update is over.
        DispatchQueue.main.async { capture?.register(view) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        let capture = coordinator.capture
        Task { @MainActor in capture?.unregister(view) }
    }
}

extension View {
    /// Marks this as the part of a chart that Share takes a picture of (the graphic, not its controls and hints).
    func shareChartArea() -> some View { modifier(ShareChartAreaModifier()) }
}

private struct ShareChartAreaModifier: ViewModifier {
    @Environment(\.shareChartCapture) private var capture

    func body(content: Content) -> some View {
        content.background(ShareChartAnchor(capture: capture))
    }
}
