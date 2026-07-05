import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import App

final class SmokeTests: XCTestCase {
    func testFeedConfigRoundTrip() throws {
        let config = FeedConfig(kind: .bluesky, name: "Test", handle: "user.bsky.social")
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(FeedConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    /// Exercises the real bundled model end to end: Bundle.module load, tiling,
    /// downscale, and JPEG encode.
    func testCoreMLUpscaleProducesCoveringImage() throws {
        XCTAssertTrue(CoreMLUpscaler.isAvailable, "bundled Core ML model failed to load")

        // A 400×300 source whose 4× (1600×1200) overshoots the target below,
        // exercising the downscale-to-cover path.
        let src = 400, srh = 300
        var bytes = [UInt8](repeating: 0, count: src * srh * 4)
        for y in 0..<srh {
            for x in 0..<src {
                let i = (y * src + x) * 4
                bytes[i] = UInt8(x * 255 / src); bytes[i + 1] = UInt8(y * 255 / srh)
                bytes[i + 2] = (x / 10 + y / 10) % 2 == 0 ? 230 : 40; bytes[i + 3] = 255
            }
        }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let bmp = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let ctx = CGContext(data: &bytes, width: src, height: srh, bitsPerComponent: 8,
                            bytesPerRow: src * 4, space: cs, bitmapInfo: bmp)!
        let cg = ctx.makeImage()!

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("src.png")
        let dst = CGImageDestinationCreateWithURL(input as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dst, cg, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dst))

        let target = CGSize(width: 1000, height: 800)
        let out = try CoreMLUpscaler.upscale(imageAt: input, toFill: target, outputDirectory: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        XCTAssertEqual(out.pathExtension, "jpg")

        let result = CGImageSourceCreateImageAtIndex(
            CGImageSourceCreateWithURL(out as CFURL, nil)!, 0, nil)!
        // Covers the target on both axes, and was downscaled from the full 4×
        // (1600×1200) rather than left oversized.
        XCTAssertGreaterThanOrEqual(result.width, 1000)
        XCTAssertGreaterThanOrEqual(result.height, 800)
        XCTAssertLessThan(result.width, 1600)
    }

    func testTolerantISO8601() {
        XCTAssertNotNil(ISO8601.tolerant("2024-01-15T12:34:56Z"))
        XCTAssertNotNil(ISO8601.tolerant("2024-01-15T12:34:56.789Z"))
        XCTAssertNil(ISO8601.tolerant("not a date"))
    }
}
