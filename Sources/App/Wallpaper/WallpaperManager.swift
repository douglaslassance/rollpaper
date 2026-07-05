import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class WallpaperManager {
    static let shared = WallpaperManager()

    private let cacheURL: URL

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        let base = caches.first ?? FileManager.default.temporaryDirectory
        cacheURL = base.appendingPathComponent("Rollpaper", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
    }

    func download(_ remoteURL: URL) async throws -> URL {
        let (data, response) = try await URLSession.shared.data(from: remoteURL)
        let ext = preferredExtension(for: response, fallbackURL: remoteURL) ?? "jpg"
        let base = baseFilename(for: remoteURL)
        let local = cacheURL.appendingPathComponent("\(base).\(ext)")
        try data.write(to: local, options: .atomic)
        return local
    }

    /// Upscales `localFile` toward the largest attached display's pixel
    /// resolution with the on-device AI model, returning the upscaled file.
    /// Best-effort: falls back to the original when the image already suits the
    /// display or the pass fails, so it never blocks a rotation.
    func upscaledIfBeneficial(_ localFile: URL) async -> URL {
        let target = largestScreenPixelSize()
        let directory = cacheURL
        do {
            return try await Task.detached(priority: .userInitiated) {
                try CoreMLUpscaler.upscale(imageAt: localFile, toFill: target, outputDirectory: directory)
            }.value
        } catch {
            return localFile
        }
    }

    /// Deletes every cached file except `keep`, so the cache holds roughly the
    /// current wallpaper rather than growing without bound (the AI-upscaled
    /// files are large). Only the currently-set wallpaper needs to stay on disk.
    func pruneCache(keeping keep: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: cacheURL, includingPropertiesForKeys: nil) else { return }
        let keepPath = keep.standardizedFileURL.path
        for entry in entries where entry.standardizedFileURL.path != keepPath {
            try? fm.removeItem(at: entry)
        }
    }

    private func largestScreenPixelSize() -> CGSize {
        let sizes = NSScreen.screens.map { screen -> CGSize in
            CGSize(width: screen.frame.width * screen.backingScaleFactor,
                   height: screen.frame.height * screen.backingScaleFactor)
        }
        return sizes.max { $0.width * $0.height < $1.width * $1.height }
            ?? CGSize(width: 3840, height: 2160)
    }

    func setDesktopImage(_ localFile: URL, fitMode: FitMode) throws {
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSNumber(value: fitMode.imageScaling.rawValue),
            .allowClipping: fitMode.allowsClipping
        ]
        for screen in NSScreen.screens {
            try NSWorkspace.shared.setDesktopImageURL(localFile, for: screen, options: options)
        }
    }

    private func preferredExtension(for response: URLResponse, fallbackURL: URL) -> String? {
        if let http = response as? HTTPURLResponse,
           let mime = http.mimeType,
           let type = UTType(mimeType: mime),
           let ext = type.preferredFilenameExtension {
            return ext
        }
        let urlExt = fallbackURL.pathExtension
        if !urlExt.isEmpty { return urlExt }
        // Bluesky CDN appends `@jpeg` / `@png` after the path component as a format hint.
        if let suffix = fallbackURL.lastPathComponent.split(separator: "@").last, suffix.count <= 5 {
            let normalized = String(suffix).lowercased()
            if normalized == "jpeg" { return "jpg" }
            return normalized
        }
        return nil
    }

    private func baseFilename(for remoteURL: URL) -> String {
        let raw = remoteURL.lastPathComponent
        // Strip Bluesky-style `@jpeg` format hint and any path extension.
        let beforeAt = raw.split(separator: "@", maxSplits: 1).first.map(String.init) ?? raw
        let withoutExt = (beforeAt as NSString).deletingPathExtension
        let trimmed = withoutExt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? UUID().uuidString : trimmed
    }
}
