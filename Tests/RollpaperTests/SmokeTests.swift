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

    /// A tall image whose subject sits near the top: the centred crop macOS
    /// would do misses it entirely, so this checks the smart crop moved the
    /// window up to keep it. Also covers the aspect-ratio contract, since the
    /// output is what gets handed to `setDesktopImage` unclipped.
    func testSmartCropFramesTheSubjectRatherThanTheCentre() throws {
        let width = 800, height = 1600
        let subject = CGRect(x: 300, y: 150, width: 200, height: 200)
        let image = makeImage(width: width, height: height) { x, y in
            subject.contains(CGPoint(x: x, y: y)) ? (245, 120, 20) : (70, 72, 75)
        }

        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try write(image, named: "tall.png", into: dir)

        let target = CGSize(width: 3840, height: 2160)
        let out = try SmartCrop.crop(imageAt: input, toAspectOf: target, outputDirectory: dir)
        let result = CGImageSourceCreateImageAtIndex(
            CGImageSourceCreateWithURL(out as CFURL, nil)!, 0, nil)!

        // Full width kept, height trimmed to the display's 16:9.
        XCTAssertEqual(result.width, width)
        XCTAssertEqual(Double(result.width) / Double(result.height),
                       target.width / target.height, accuracy: 0.01)

        // The whole 200×200 subject survived the crop, which is 1/9th of the
        // 800×450 result. A centred crop (y 575…1025) would have left none of
        // it, since the subject ends at y = 350.
        XCTAssertGreaterThan(orangeFraction(of: result), 0.08,
                             "smart crop dropped the subject; it framed the centre instead")
    }

    /// An image already shaped like the display needs no crop, and saying so
    /// lets the caller keep the untouched original rather than re-encoding it.
    func testSmartCropSkipsImagesThatAlreadyMatchTheDisplay() throws {
        let image = makeImage(width: 1600, height: 900) { x, _ in (UInt8(x % 256), 100, 100) }
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try write(image, named: "wide.png", into: dir)

        XCTAssertThrowsError(
            try SmartCrop.crop(imageAt: input, toAspectOf: CGSize(width: 3840, height: 2160),
                               outputDirectory: dir)
        ) { error in
            XCTAssertEqual(error as? SmartCrop.CropError, .notBeneficial)
        }
    }

    // MARK: - Image helpers

    private func makeImage(width: Int, height: Int,
                           pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                (bytes[i], bytes[i + 1], bytes[i + 2]) = pixel(x, y)
            }
        }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let bmp = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let ctx = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: cs, bitmapInfo: bmp)!
        return ctx.makeImage()!
    }

    private func makeScratchDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ image: CGImage, named name: String, into directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dst, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dst))
        return url
    }

    /// Share of pixels matching the subject colour, read back through a bitmap
    /// context so JPEG's lossy edges don't matter.
    private func orangeFraction(of image: CGImage) -> Double {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let bmp = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let ctx = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: cs, bitmapInfo: bmp)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var hits = 0
        for i in stride(from: 0, to: bytes.count, by: 4) where bytes[i] > 200 && bytes[i + 2] < 90 {
            hits += 1
        }
        return Double(hits) / Double(width * height)
    }

    func testTolerantISO8601() {
        XCTAssertNotNil(ISO8601.tolerant("2024-01-15T12:34:56Z"))
        XCTAssertNotNil(ISO8601.tolerant("2024-01-15T12:34:56.789Z"))
        XCTAssertNil(ISO8601.tolerant("not a date"))
    }
}
