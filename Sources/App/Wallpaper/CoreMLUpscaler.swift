import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// On-device AI upscaling with a bundled Core ML model: Real-ESRGAN's
/// `realesr-general-x4v3` (SRVGGNetCompact, 4×), BSD-3-Clause. Runs in-process
/// on the Neural Engine/GPU, so it works inside the App Sandbox with no
/// external tools and no network.
///
/// The model has a fixed 256×256 input, so larger images are processed in
/// overlapping tiles whose padded borders are cropped away to avoid seams.
enum CoreMLUpscaler {
    private static let tile = 256
    private static let pad = 16
    private static let scale = 4
    private static var core: Int { tile - 2 * pad }  // 224

    /// Only upscale when the display needs meaningfully more pixels than the
    /// source provides; below this, macOS's own scaling is already fine.
    private static let minGain: CGFloat = 1.2

    enum UpscaleError: LocalizedError {
        case modelUnavailable
        case decodeFailed
        case notBeneficial
        case predictionFailed
        case encodeFailed

        var errorDescription: String? {
            switch self {
            case .modelUnavailable: return "The upscaling model could not be loaded."
            case .decodeFailed: return "Could not read the source image."
            case .notBeneficial: return "The image already suits the display; skipping upscaling."
            case .predictionFailed: return "The upscaling model failed to run."
            case .encodeFailed: return "Could not write the upscaled image."
            }
        }
    }

    /// Compiled once per process. The `.mlmodelc` is bundled precompiled, so
    /// this is a direct load, no runtime compilation.
    private static let model: MLModel? = {
        guard let url = modelURL() else { return nil }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        return try? MLModel(contentsOf: url, configuration: config)
    }()

    /// `Bundle.module`'s generated accessor looks for the resource bundle at
    /// the `.app` root, then falls back to an absolute dev-machine build
    /// path; neither exists in a packaged, sandboxed app (the resource
    /// bundle actually lives under `Contents/Resources`), so it hits a
    /// fatal error instead of returning nil. Resolve the real location
    /// directly and only fall back to `Bundle.module` for `swift run`/tests.
    private static func modelURL() -> URL? {
        if let resourcesBundle = Bundle.main.resourceURL?.appendingPathComponent("Rollpaper_App.bundle"),
           let bundle = Bundle(path: resourcesBundle.path),
           let url = bundle.url(forResource: "RealESRGANx4v3", withExtension: "mlmodelc") {
            return url
        }
        return Bundle.module.url(forResource: "RealESRGANx4v3", withExtension: "mlmodelc")
    }

    static var isAvailable: Bool { model != nil }

    /// Upscales the image at `url` so it covers `target` (in pixels), writing a
    /// JPEG into `outputDirectory` and returning its URL.
    ///
    /// Throws `.notBeneficial` when the source already suits the display, so
    /// callers can fall back to the original.
    static func upscale(imageAt url: URL, toFill target: CGSize, outputDirectory: URL) throws -> URL {
        guard let model else { throw UpscaleError.modelUnavailable }
        let source = try decode(url)
        let srcWidth = source.width
        let srcHeight = source.height

        // Needed only when the source is meaningfully smaller than the display.
        // The "already big enough" cutoff is the display's own resolution, so
        // the pass scales with the screen (more on a 5K display, less on 1080p)
        // and never runs on images that already reach the display's longer side.
        let gain = max(target.width / CGFloat(srcWidth), target.height / CGFloat(srcHeight))
        let displayLongestSide = max(target.width, target.height)
        guard gain > minGain, CGFloat(max(srcWidth, srcHeight)) < displayLongestSide else {
            throw UpscaleError.notBeneficial
        }

        let upscaled = try run(model: model, on: source)

        // The 4× result usually overshoots the display; downscale so it just
        // covers `target`, keeping the stored file near display size.
        let cover = max(target.width / CGFloat(upscaled.width), target.height / CGFloat(upscaled.height))
        let final: CGImage
        if cover < 1 {
            final = resize(upscaled,
                           to: CGSize(width: (CGFloat(upscaled.width) * cover).rounded(),
                                      height: (CGFloat(upscaled.height) * cover).rounded())) ?? upscaled
        } else {
            final = upscaled
        }
        return try writeJPEG(final, basedOn: url, into: outputDirectory)
    }

    // MARK: - Inference

    private static func run(model: MLModel, on source: CGImage) throws -> CGImage {
        let width = source.width
        let height = source.height
        var src = [UInt8](repeating: 0, count: width * height * 4)
        try draw(source, into: &src, width: width, height: height)

        let outWidth = width * scale
        let outHeight = height * scale
        var out = [UInt8](repeating: 255, count: outWidth * outHeight * 4)

        guard let buffer = makePixelBuffer(tile, tile) else { throw UpscaleError.predictionFailed }

        var ty = 0
        while ty < height {
            var tx = 0
            while tx < width {
                let coreW = min(core, width - tx)
                let coreH = min(core, height - ty)
                fillTile(buffer, from: src, width: width, height: height, originX: tx, originY: ty)

                let provider = try MLDictionaryFeatureProvider(dictionary: [
                    "image": MLFeatureValue(pixelBuffer: buffer)
                ])
                guard let array = try model.prediction(from: provider)
                    .featureValue(for: "output")?.multiArrayValue else {
                    throw UpscaleError.predictionFailed
                }
                copyCore(array, into: &out, outWidth: outWidth,
                         destX: tx * scale, destY: ty * scale,
                         coreW: coreW * scale, coreH: coreH * scale)
                tx += core
            }
            ty += core
        }

        guard let image = makeImage(from: out, width: outWidth, height: outHeight) else {
            throw UpscaleError.predictionFailed
        }
        return image
    }

    /// Fills the reusable 256×256 BGRA buffer with the window centred on the
    /// tile's core region, clamping (edge-replicating) out-of-bounds pixels.
    private static func fillTile(_ buffer: CVPixelBuffer, from src: [UInt8],
                                 width: Int, height: Int, originX: Int, originY: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for j in 0..<tile {
            let sy = min(max(originY - pad + j, 0), height - 1)
            for i in 0..<tile {
                let sx = min(max(originX - pad + i, 0), width - 1)
                let s = (sy * width + sx) * 4
                let d = j * stride + i * 4
                base[d + 0] = src[s + 2]  // B
                base[d + 1] = src[s + 1]  // G
                base[d + 2] = src[s + 0]  // R
                base[d + 3] = 255
            }
        }
    }

    /// Copies the model output's core region (dropping the padded border) into
    /// the assembled output buffer.
    private static func copyCore(_ array: MLMultiArray, into out: inout [UInt8],
                                 outWidth: Int, destX: Int, destY: Int, coreW: Int, coreH: Int) {
        let sC = array.strides[1].intValue
        let sY = array.strides[2].intValue
        let sX = array.strides[3].intValue
        let offset = pad * scale

        func write(_ sample: (Int, Int, Int) -> Float) {
            for oy in 0..<coreH {
                let dy = destY + oy
                let iy = offset + oy
                for ox in 0..<coreW {
                    let di = (dy * outWidth + destX + ox) * 4
                    let ix = offset + ox
                    for c in 0..<3 {
                        var v = sample(c, iy, ix)
                        v = v < 0 ? 0 : (v > 1 ? 1 : v)
                        out[di + c] = UInt8(v * 255 + 0.5)
                    }
                    out[di + 3] = 255
                }
            }
        }

        switch array.dataType {
        case .float16:
            let p = array.dataPointer.assumingMemoryBound(to: Float16.self)
            write { c, y, x in Float(p[c * sC + y * sY + x * sX]) }
        case .float32:
            let p = array.dataPointer.assumingMemoryBound(to: Float.self)
            write { c, y, x in p[c * sC + y * sY + x * sX] }
        default:
            write { c, y, x in array[[0, c, y, x] as [NSNumber]].floatValue }
        }
    }

    // MARK: - CoreGraphics helpers

    private static let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue

    private static func decode(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw UpscaleError.decodeFailed
        }
        return image
    }

    private static func draw(_ image: CGImage, into bytes: inout [UInt8], width: Int, height: Int) throws {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &bytes, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: colorSpace, bitmapInfo: bitmapInfo) else {
            throw UpscaleError.decodeFailed
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    private static func makeImage(from bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        var mutable = bytes
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &mutable, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: colorSpace, bitmapInfo: bitmapInfo) else {
            return nil
        }
        return context.makeImage()
    }

    private static func resize(_ image: CGImage, to size: CGSize) -> CGImage? {
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: bitmapInfo) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func makePixelBuffer(_ width: Int, _ height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: CFDictionary = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ] as CFDictionary
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs, &buffer)
        return buffer
    }

    private static func writeJPEG(_ image: CGImage, basedOn source: URL, into directory: URL) throws -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        let destination = directory.appendingPathComponent("\(base)-upscaled.jpg")
        guard let out = CGImageDestinationCreateWithURL(
            destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw UpscaleError.encodeFailed
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        CGImageDestinationAddImage(out, image, options as CFDictionary)
        guard CGImageDestinationFinalize(out) else { throw UpscaleError.encodeFailed }
        return destination
    }
}
