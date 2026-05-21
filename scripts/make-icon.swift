#!/usr/bin/env swift
// Render the menu-bar SF Symbol into a macOS-style app icon.
// Output: assets/Rollpaper.icns (committed to the repo). Rerun this script
// whenever you change the symbol or styling below.

import AppKit
import Foundation

let symbolName = "photo.on.rectangle.angled"
let backgroundColor = NSColor(calibratedRed: 0.96, green: 0.96, blue: 0.97, alpha: 1)
let foregroundColor = NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)

let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assetsDir = repoRoot.appendingPathComponent("assets")
let iconsetDir = assetsDir.appendingPathComponent("Rollpaper.iconset")
let icnsPath = assetsDir.appendingPathComponent("Rollpaper.icns")

try? FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
try? FileManager.default.removeItem(at: iconsetDir)
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

func renderPNG(pixelSize: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }
    rep.size = NSSize(width: pixelSize, height: pixelSize)

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let size = CGFloat(pixelSize)
    let cornerRadius = size * 0.225
    let bg = NSBezierPath(
        roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
        xRadius: cornerRadius,
        yRadius: cornerRadius
    )
    backgroundColor.setFill()
    bg.fill()

    guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
        return rep.representation(using: .png, properties: [:])
    }
    let config = NSImage.SymbolConfiguration(pointSize: size * 0.55, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [foregroundColor]))
    let configured = symbol.withSymbolConfiguration(config) ?? symbol
    let symbolSize = configured.size
    let symbolRect = NSRect(
        x: (size - symbolSize.width) / 2,
        y: (size - symbolSize.height) / 2,
        width: symbolSize.width,
        height: symbolSize.height
    )
    configured.draw(in: symbolRect)

    return rep.representation(using: .png, properties: [:])
}

let outputs: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for output in outputs {
    guard let data = renderPNG(pixelSize: output.pixels) else {
        FileHandle.standardError.write(Data("Failed to render \(output.name)\n".utf8))
        exit(1)
    }
    try data.write(to: iconsetDir.appendingPathComponent(output.name))
}

let task = Process()
task.launchPath = "/usr/bin/iconutil"
task.arguments = ["-c", "icns", iconsetDir.path, "-o", icnsPath.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(Int32(task.terminationStatus))
}

print("Wrote \(icnsPath.path)")
