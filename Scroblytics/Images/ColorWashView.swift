import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI

private struct ColorWashRGB: Hashable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    var color: Color {
        Color(red: red, green: green, blue: blue)
    }

    var saturation: Double {
        let maximum = max(red, green, blue)
        guard maximum > 0 else { return 0 }
        return (maximum - min(red, green, blue)) / maximum
    }

    var luminance: Double {
        0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    func boosted(minimumSaturation: Double = 0.64) -> ColorWashRGB {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        guard maximum > minimum else { return self }
        let currentSaturation = (maximum - minimum) / maximum
        guard currentSaturation < minimumSaturation else { return self }
        let scale = minimumSaturation / currentSaturation
        return ColorWashRGB(
            red: maximum - (maximum - red) * scale,
            green: maximum - (maximum - green) * scale,
            blue: maximum - (maximum - blue) * scale
        ).clamped()
    }

    private func clamped() -> ColorWashRGB {
        ColorWashRGB(
            red: min(1, max(0, red)),
            green: min(1, max(0, green)),
            blue: min(1, max(0, blue))
        )
    }
}

private struct ColorWashPalette: Sendable {
    let colors: [ColorWashRGB]
    let isMonochrome: Bool
}

private actor ColorWashPaletteCache {
    static let shared = ColorWashPaletteCache()

    private var palettes: [String: ColorWashPalette] = [:]

    func palette(for urlStrings: [String]) async -> ColorWashPalette? {
        guard !urlStrings.isEmpty else { return nil }
        let key = urlStrings.joined(separator: "|")
        if let cached = palettes[key] { return cached }

        var colors: [ColorWashRGB] = []
        for urlString in urlStrings.prefix(3) {
            guard let url = URL(string: urlString),
                  let data = try? await imageData(from: url),
                  let sampled = Self.sample(data: data) else { continue }
            colors.append(contentsOf: sampled)
        }

        guard let palette = Self.makePalette(from: colors) else { return nil }
        palettes[key] = palette
        return palette
    }

    private func imageData(from url: URL) async throws -> Data {
        if url.isFileURL { return try Data(contentsOf: url) }
        try ConnectivityGate.check(host: url.host)
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    nonisolated private static func sample(data: Data) -> [ColorWashRGB]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 18
              ] as CFDictionary) else { return nil }

        let width = 18
        let height = 18
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        return stride(from: 0, to: pixels.count, by: 4).compactMap { index in
            guard pixels[index + 3] > 100 else { return nil }
            return ColorWashRGB(
                red: Double(pixels[index]) / 255,
                green: Double(pixels[index + 1]) / 255,
                blue: Double(pixels[index + 2]) / 255
            )
        }
    }

    nonisolated private static func makePalette(from samples: [ColorWashRGB]) -> ColorWashPalette? {
        guard !samples.isEmpty else { return nil }

        let colorful = samples
            .filter { $0.luminance > 0.06 && $0.luminance < 0.94 }
            .sorted {
                let lhs = $0.saturation * 0.8 + (0.5 - abs($0.luminance - 0.5)) * 0.2
                let rhs = $1.saturation * 0.8 + (0.5 - abs($1.luminance - 0.5)) * 0.2
                return lhs > rhs
            }

        var selected: [ColorWashRGB] = []
        for candidate in colorful where candidate.saturation > 0.12 {
            let isDistinct = selected.allSatisfy { existing in
                let distance = abs(candidate.red - existing.red)
                    + abs(candidate.green - existing.green)
                    + abs(candidate.blue - existing.blue)
                return distance > 0.32
            }
            if isDistinct { selected.append(candidate.boosted()) }
            if selected.count == 4 { break }
        }

        guard selected.count >= 2 else {
            return ColorWashPalette(colors: monochromePalette(from: samples), isMonochrome: true)
        }

        // Repeat colors already present in the artwork instead of inventing
        // unrelated hues when only two dominant colors are available.
        while selected.count < 4 {
            selected.append(selected[selected.count % 2])
        }
        return ColorWashPalette(colors: Array(selected.prefix(4)), isMonochrome: false)
    }

    nonisolated private static func monochromePalette(from samples: [ColorWashRGB]) -> [ColorWashRGB] {
        let sorted = samples.map(\.luminance).sorted()
        let indices = [0, sorted.count / 3, sorted.count * 2 / 3, sorted.count - 1]
        var tones = indices.map { sorted[$0] }

        // Nearly flat covers still need enough tonal separation for the wash
        // to be visible. Keep that separation neutral rather than adding hue.
        if (tones.last ?? 0) - (tones.first ?? 0) < 0.12 {
            let center = sorted.reduce(0, +) / Double(sorted.count)
            tones = [-0.18, -0.06, 0.06, 0.18].map {
                min(0.96, max(0.04, center + $0))
            }
        }
        return tones.map { tone in
            ColorWashRGB(red: tone, green: tone, blue: tone)
        }
    }
}

struct ColorWashView: View {
    let imageURLs: [String]
    var strength: Double = 1

    @Environment(\.colorScheme) private var colorScheme
    @State private var palette: ColorWashPalette?

    private var identity: String {
        imageURLs.filter { !$0.isEmpty }.prefix(3).joined(separator: "|")
    }

    var body: some View {
        GeometryReader { geometry in
            if palette != nil {
                ZStack {
                    wash(color(at: 0), size: geometry.size, x: -0.28, y: -0.34)
                    wash(color(at: 1), size: geometry.size, x: 0.34, y: -0.18)
                    wash(color(at: 2), size: geometry.size, x: -0.12, y: 0.34)
                    wash(color(at: 3), size: geometry.size, x: 0.42, y: 0.38)
                }
                .blur(radius: 42)
                .scaleEffect(1.12)
                .clipped()
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: identity) {
            palette = nil
            let urls = imageURLs.filter { !$0.isEmpty }
            palette = await ColorWashPaletteCache.shared.palette(for: urls)
        }
    }

    private func color(at index: Int) -> Color {
        guard let palette, !palette.colors.isEmpty else { return .clear }
        let source = palette.colors[index % palette.colors.count]
        let color = palette.isMonochrome ? themeAdjustedMonochrome(source) : source.color
        let opacity = palette.isMonochrome ? 0.34 : 0.52
        return color.opacity(opacity * strength)
    }

    private func themeAdjustedMonochrome(_ source: ColorWashRGB) -> Color {
        let tones = palette?.colors.map(\.luminance) ?? [source.luminance]
        let minimum = tones.min() ?? 0
        let maximum = tones.max() ?? 1
        let normalized = maximum > minimum
            ? (source.luminance - minimum) / (maximum - minimum)
            : 0.5
        let range = colorScheme == .dark ? 0.06...0.32 : 0.70...0.97
        let tone = range.lowerBound + normalized * (range.upperBound - range.lowerBound)
        return Color(red: tone, green: tone, blue: tone)
    }

    private func wash(_ color: Color, size: CGSize, x: CGFloat, y: CGFloat) -> some View {
        RadialGradient(colors: [color, color.opacity(0)], center: .center, startRadius: 0, endRadius: max(size.width, size.height) * 0.62)
            .frame(width: size.width, height: size.height)
            .offset(x: size.width * x, y: size.height * y)
    }
}
