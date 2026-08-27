import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <source.png> <output.png>\n".utf8))
    exit(64)
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = NSImage(contentsOf: sourceURL) else {
    FileHandle.standardError.write(Data("unable to load icon source: \(sourceURL.path)\n".utf8))
    exit(66)
}

let canvasSize = 1024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: canvasSize,
    pixelsHigh: canvasSize,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    exit(70)
}
bitmap.size = NSSize(width: canvasSize, height: canvasSize)

guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    exit(70)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high

NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: canvasSize, height: canvasSize).fill()

// A small transparent margin and soft shadow follow modern macOS icon
// proportions while keeping ears and whiskers inside the safe area.
let iconRect = NSRect(x: 58, y: 64, width: 908, height: 908)
let iconPath = NSBezierPath(roundedRect: iconRect, xRadius: 202, yRadius: 202)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
shadow.shadowBlurRadius = 30
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor.white.setFill()
iconPath.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
iconPath.addClip()
source.draw(
    in: iconRect,
    from: NSRect(origin: .zero, size: source.size),
    operation: .copy,
    fraction: 1,
    respectFlipped: true,
    hints: [.interpolation: NSImageInterpolation.high]
)

// Gentle edge highlight keeps the icon legible on both light and dark Docks.
NSColor.white.withAlphaComponent(0.18).setStroke()
iconPath.lineWidth = 3
iconPath.stroke()
NSGraphicsContext.restoreGraphicsState()

context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    exit(70)
}
try png.write(to: outputURL, options: .atomic)
