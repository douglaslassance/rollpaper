import Foundation
import UniformTypeIdentifiers

enum LocalFolderClient {
    /// Folders we've already begun security-scoped access to this session.
    /// Access is intentionally kept open for the app's lifetime: the folder is a
    /// persistent feed whose files are re-read (and copied into the cache) on
    /// every rotation, so we resolve and open it once rather than per fetch.
    private static var accessedPaths = Set<String>()

    static func fetch(bookmark: Data?) async throws -> [WallpaperItem] {
        guard let bookmark else {
            throw FeedError.invalidConfiguration(
                "This folder feed is missing its saved permission. Remove it and add the folder again."
            )
        }

        var isStale = false
        let folder: URL
        do {
            folder = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw FeedError.invalidConfiguration(
                "Could not open the saved folder. Remove the feed and add it again."
            )
        }

        if !accessedPaths.contains(folder.path), folder.startAccessingSecurityScopedResource() {
            accessedPaths.insert(folder.path)
        }

        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw FeedError.network("Could not read the folder “\(folder.lastPathComponent)”.")
        }

        return entries.compactMap { url -> WallpaperItem? in
            guard isImageFile(url) else { return nil }
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return WallpaperItem(
                id: url.path,
                imageURL: url,
                sourceURL: nil,
                createdAt: modified
            )
        }
    }

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "tiff", "tif", "bmp", "webp"
    ]

    private static func isImageFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if let type = UTType(filenameExtension: ext), type.conforms(to: .image) {
            return true
        }
        return imageExtensions.contains(ext)
    }
}
