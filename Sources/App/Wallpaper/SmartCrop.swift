import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Subject-aware cropping for the `.smart` fit mode.
///
/// macOS's own `.fill` scaling crops from the centre, which is the worst
/// possible choice for tall portrait art on a wide display: the middle of a
/// full-body character piece is the torso, so the face gets cut away. This
/// pre-crops the image to the display's aspect ratio around whatever the
/// picture is actually about, then hands macOS an image that already fits.
///
/// Detection is Vision, which ships with macOS. There is no bundled model, no
/// download and no network, and a pass costs a few tens of milliseconds.
enum SmartCrop {
    /// Ignore aspect-ratio differences this small. Below it the crop would
    /// shave a sliver off the edges, which is not worth a re-encode.
    private static let minAspectDifference: CGFloat = 0.02

    /// Where a detected face or upper body sits vertically inside the crop.
    /// Above the middle, so the eyeline lands near the upper third, which is
    /// how portraits are normally framed.
    private static let portraitAnchor: CGFloat = 0.38

    enum CropError: LocalizedError {
        case decodeFailed
        case notBeneficial
        case cropFailed
        case encodeFailed

        var errorDescription: String? {
            switch self {
            case .decodeFailed: return "Could not read the source image."
            case .notBeneficial: return "The image already matches the display; skipping cropping."
            case .cropFailed: return "Could not crop the image."
            case .encodeFailed: return "Could not write the cropped image."
            }
        }
    }

    /// Crops the image at `url` to `target`'s aspect ratio, framed on its
    /// subject, writing a JPEG into `outputDirectory` and returning its URL.
    ///
    /// Throws `.notBeneficial` when the image already matches the display's
    /// shape, so callers can fall back to the original untouched.
    static func crop(imageAt url: URL, toAspectOf target: CGSize, outputDirectory: URL) throws -> URL {
        guard target.width > 0, target.height > 0 else { throw CropError.notBeneficial }
        let image = try decode(url)
        let imageSize = CGSize(width: image.width, height: image.height)
        guard imageSize.width > 0, imageSize.height > 0 else { throw CropError.decodeFailed }

        let targetAspect = target.width / target.height
        let imageAspect = imageSize.width / imageSize.height
        guard abs(imageAspect - targetAspect) / targetAspect > minAspectDifference else {
            throw CropError.notBeneficial
        }

        let cropSize = cropSize(for: imageSize, targetAspect: targetAspect)
        let origin = cropOrigin(cropSize: cropSize, imageSize: imageSize,
                                focus: focus(in: image, imageSize: imageSize))
        let rect = CGRect(origin: origin, size: cropSize).integral

        guard let cropped = image.cropping(to: rect) else { throw CropError.cropFailed }
        return try writeJPEG(cropped, basedOn: url, into: outputDirectory)
    }

    // MARK: - Geometry

    /// The largest rectangle with `targetAspect` that fits inside the image.
    private static func cropSize(for imageSize: CGSize, targetAspect: CGFloat) -> CGSize {
        if imageSize.width / imageSize.height > targetAspect {
            // Image is wider than the display: keep full height, trim the sides.
            return CGSize(width: (imageSize.height * targetAspect).rounded(.down), height: imageSize.height)
        }
        // Image is taller than the display: keep full width, trim top and bottom.
        return CGSize(width: imageSize.width, height: (imageSize.width / targetAspect).rounded(.down))
    }

    /// Positions the crop window over the focus, clamped to the image. No focus
    /// (nothing detected) falls back to the centred crop macOS would have done.
    private static func cropOrigin(cropSize: CGSize, imageSize: CGSize, focus: Focus?) -> CGPoint {
        let point: CGPoint
        switch focus {
        case nil:
            point = CGPoint(x: (imageSize.width - cropSize.width) / 2,
                            y: (imageSize.height - cropSize.height) / 2)
        case .subject(let rect):
            // A subject taller than the crop cannot be framed by the anchor
            // rule; centring on it keeps as much as the crop can hold.
            let anchorY = rect.height >= cropSize.height ? 0.5 : portraitAnchor
            point = CGPoint(x: rect.midX - cropSize.width / 2,
                            y: rect.midY - cropSize.height * anchorY)
        case .heatmap(let width, let height, let weights):
            let columns = profile(weights, width: width, height: height, alongRows: false)
            let rows = profile(weights, width: width, height: height, alongRows: true)
            point = CGPoint(
                x: heaviestWindowStart(columns, fraction: cropSize.width / imageSize.width) * imageSize.width,
                y: heaviestWindowStart(rows, fraction: cropSize.height / imageSize.height) * imageSize.height
            )
        }
        return CGPoint(x: clamp(point.x, upper: imageSize.width - cropSize.width).rounded(),
                       y: clamp(point.y, upper: imageSize.height - cropSize.height).rounded())
    }

    private static func clamp(_ value: CGFloat, upper: CGFloat) -> CGFloat {
        min(max(value, 0), max(upper, 0))
    }

    // MARK: - Detection

    /// What the crop should be built around.
    private enum Focus {
        /// A detected subject, in image pixel coordinates with a top-left
        /// origin. Precise enough to frame by the anchor rule.
        case subject(CGRect)
        /// A saliency heatmap, row-major from the top-left. Its bounding box is
        /// far too coarse to frame with (it routinely spans most of the image),
        /// so the weights themselves decide where the crop sits.
        case heatmap(width: Int, height: Int, weights: [Float])
    }

    /// Finds what the image is about, most specific first. Faces give the best
    /// framing, upper bodies catch stylized art whose faces the detector
    /// misses, and attention saliency covers everything else (creatures,
    /// machines, landscapes, abstract pieces). Returns nil when nothing stands
    /// out, which means "crop from the centre".
    private static func focus(in image: CGImage, imageSize: CGSize) -> Focus? {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        if let rect = union(of: VNDetectFaceRectanglesRequest(), handler: handler, imageSize: imageSize) {
            return .subject(rect)
        }

        let bodies = VNDetectHumanRectanglesRequest()
        bodies.upperBodyOnly = true
        if let rect = union(of: bodies, handler: handler, imageSize: imageSize) {
            return .subject(rect)
        }

        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        guard (try? handler.perform([saliency])) != nil,
              let observation = saliency.results?.first else { return nil }
        return heatmap(from: observation)
    }

    /// Runs `request` and returns the union of its detections in image pixel
    /// coordinates (origin top-left), or nil if it found nothing. Vision
    /// reports normalized rects with a bottom-left origin, so the y axis is
    /// flipped here to match `CGImage.cropping(to:)`.
    private static func union(of request: VNImageBasedRequest,
                              handler: VNImageRequestHandler,
                              imageSize: CGSize) -> CGRect? {
        guard (try? handler.perform([request])) != nil,
              let observations = request.results?.compactMap({ $0 as? VNDetectedObjectObservation }),
              !observations.isEmpty else { return nil }

        return observations.reduce(into: CGRect?.none) { union, observation in
            let box = observation.boundingBox
            let rect = CGRect(x: box.minX * imageSize.width,
                              y: (1 - box.maxY) * imageSize.height,
                              width: box.width * imageSize.width,
                              height: box.height * imageSize.height)
            union = union.map { $0.union(rect) } ?? rect
        }
    }

    /// Copies the saliency observation's grayscale heatmap (a small buffer,
    /// typically 68×68) out into a plain array. Returns nil for a uniformly
    /// blank map, where every crop is equally good and centring is fine.
    private static func heatmap(from observation: VNSaliencyImageObservation) -> Focus? {
        let buffer = observation.pixelBuffer
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent32Float else {
            return nil
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0,
              let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: Float.self) else {
            return nil
        }
        let stride = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<Float>.size

        var weights = [Float](repeating: 0, count: width * height)
        var total: Float = 0
        for y in 0..<height {
            for x in 0..<width {
                let value = max(base[y * stride + x], 0)
                weights[y * width + x] = value
                total += value
            }
        }
        guard total > 0 else { return nil }
        return .heatmap(width: width, height: height, weights: weights)
    }

    /// Collapses the heatmap onto one axis, giving a 1-D profile of where the
    /// interesting pixels are.
    private static func profile(_ weights: [Float], width: Int, height: Int, alongRows: Bool) -> [Float] {
        var out = [Float](repeating: 0, count: alongRows ? height : width)
        for y in 0..<height {
            for x in 0..<width {
                out[alongRows ? y : x] += weights[y * width + x]
            }
        }
        return out
    }

    /// Slides a window covering `fraction` of the profile and returns the start
    /// holding the most weight, as a fraction of the whole. Ties keep the
    /// earliest window, which biases a crop toward the top of a portrait (where
    /// the head is) rather than its feet.
    private static func heaviestWindowStart(_ profile: [Float], fraction: CGFloat) -> CGFloat {
        let count = profile.count
        let window = max(1, min(count, Int((CGFloat(count) * fraction).rounded())))
        guard window < count else { return 0 }

        var sum = profile[0..<window].reduce(0, +)
        var best = sum
        var bestStart = 0
        for start in 1...(count - window) {
            sum += profile[start + window - 1] - profile[start - 1]
            if sum > best {
                best = sum
                bestStart = start
            }
        }
        return CGFloat(bestStart) / CGFloat(count)
    }

    // MARK: - Image IO

    /// Decodes the image with its EXIF orientation baked into the pixels.
    /// `CGImageSourceCreateImageAtIndex` hands back the stored pixels and
    /// leaves the rotation in the metadata, so a phone photo shot in portrait
    /// arrives as a landscape buffer. Cropping that would trim the wrong axis,
    /// and the JPEG we write carries no orientation tag to put it back.
    private static func decode(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CropError.decodeFailed
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let raw = properties?[kCGImagePropertyOrientation] as? UInt32 ?? 1
        guard let orientation = CGImagePropertyOrientation(rawValue: raw), orientation != .up else {
            return image
        }
        let oriented = CIImage(cgImage: image).oriented(orientation)
        return CIContext().createCGImage(oriented, from: oriented.extent) ?? image
    }

    private static func writeJPEG(_ image: CGImage, basedOn source: URL, into directory: URL) throws -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        let destination = directory.appendingPathComponent("\(base)-framed.jpg")
        guard let out = CGImageDestinationCreateWithURL(
            destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CropError.encodeFailed
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
        CGImageDestinationAddImage(out, image, options as CFDictionary)
        guard CGImageDestinationFinalize(out) else { throw CropError.encodeFailed }
        return destination
    }
}
