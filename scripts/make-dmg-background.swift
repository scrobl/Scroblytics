#!/usr/bin/env swift
// Draws the background picture of the installer disk image: a soft grey field with an arrow pointing from the app to the
// Applications folder. The window is 600 x 400 points; `scale` 2 makes the Retina version (the same picture at twice the
// pixels). Usage: make-dmg-background.swift <output.png> <scale>
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3, let scale = Int(arguments[2]), scale >= 1 else {
    FileHandle.standardError.write(Data("usage: make-dmg-background.swift <output.png> <scale>\n".utf8))
    exit(2)
}

let width = 600.0, height = 400.0
// Where the two icons sit (centres, in points from the top left); the arrow runs between them.
let iconY = 175.0
let leftX = 150.0, rightX = 450.0

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(width) * scale, pixelsHigh: Int(height) * scale, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }
rep.size = NSSize(width: width, height: height) // 72 dpi at scale 1, 144 at scale 2: Finder reads this to size the picture

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

// Background: a gentle vertical gradient, light enough that Finder's dark icon labels stay readable.
let gradient = NSGradient(colors: [NSColor(white: 0.97, alpha: 1), NSColor(white: 0.89, alpha: 1)])!
gradient.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -90)

// Coordinates below are from the top left; AppKit's origin is the bottom left.
func flipped(_ y: Double) -> Double { height - y }

// The arrow: a rounded shaft and a head, in a mid grey.
let color = NSColor(white: 0.52, alpha: 1)
color.setStroke()
color.setFill()
let shaft = NSBezierPath()
shaft.lineWidth = 7
shaft.lineCapStyle = .round
let startX = leftX + 88, endX = rightX - 96
shaft.move(to: NSPoint(x: startX, y: flipped(iconY)))
shaft.line(to: NSPoint(x: endX - 14, y: flipped(iconY)))
shaft.stroke()
let head = NSBezierPath()
head.lineJoinStyle = .round
head.lineWidth = 4
head.move(to: NSPoint(x: endX + 6, y: flipped(iconY)))
head.line(to: NSPoint(x: endX - 22, y: flipped(iconY - 20)))
head.line(to: NSPoint(x: endX - 22, y: flipped(iconY + 20)))
head.close()
head.fill()
head.stroke()

// A short instruction near the bottom.
let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
let text = "Drag Scroblytics to the Applications folder" as NSString
text.draw(
    in: NSRect(x: 0, y: flipped(352), width: width, height: 20),
    withAttributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .regular),
        .foregroundColor: NSColor(white: 0.42, alpha: 1),
        .paragraphStyle: paragraph,
    ]
)

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: arguments[1]))
