import Foundation
import Photos
import UniformTypeIdentifiers

/// A wallpaper source backed by the local Photos library. The user picks one
/// collection, either a user album or a system "smart" album (Favorites,
/// Recents, and so on); `fetch` enumerates that collection's photos.
///
/// Unlike the remote feeds, `fetch` returns lightweight references rather than
/// image bytes: each `WallpaperItem` carries a `photos://asset?id=…` URL built
/// from the asset's stable local identifier. Only the picked item is later
/// materialized to a file (see `WallpaperManager.download` and `loadAssetData`),
/// so a library of thousands of photos costs nothing to enumerate each rotation.
enum PhotosLibraryClient {
    /// URL scheme used to reference a Photos asset without touching disk.
    static let scheme = "photos"

    // MARK: - URL round-tripping

    /// Builds the `photos://asset?id=<localIdentifier>` URL stored in a
    /// `WallpaperItem`. Local identifiers contain slashes, so the identifier
    /// rides in a query item rather than the path to survive URL parsing.
    static func url(forAssetIdentifier identifier: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "asset"
        components.queryItems = [URLQueryItem(name: "id", value: identifier)]
        return components.url ?? URL(string: "\(scheme)://asset")!
    }

    /// Extracts the asset local identifier from a `photos://` URL, or nil if the
    /// URL isn't one of ours.
    static func assetIdentifier(from url: URL) -> String? {
        guard url.scheme == scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        return components.queryItems?.first(where: { $0.name == "id" })?.value
    }

    // MARK: - Authorization

    /// Requests read access to the Photos library, returning the resulting
    /// status. Safe to call repeatedly; once granted it resolves immediately.
    static func requestAccess() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current != .notDetermined { return current }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }

    // MARK: - Album listing (for the settings picker)

    /// One selectable collection, with enough detail to show in the picker.
    struct Album: Identifiable, Hashable, Sendable {
        let id: String       // PHAssetCollection.localIdentifier
        let title: String
        let count: Int       // number of photos (non-video assets)
        let isSmart: Bool    // system "auto" album vs. a user-created album
    }

    /// Lists non-empty collections the user can choose from: system smart albums
    /// first (Favorites, Recents, …), then user albums alphabetically. Requires
    /// access to already be granted.
    static func albums() async -> [Album] {
        await Task.detached(priority: .userInitiated) {
            var smart: [Album] = []
            var user: [Album] = []

            let imageOnly = PHFetchOptions()
            imageOnly.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)

            func makeAlbum(_ collection: PHAssetCollection, isSmart: Bool) -> Album? {
                let count = PHAsset.fetchAssets(in: collection, options: imageOnly).count
                guard count > 0 else { return nil }
                let title = collection.localizedTitle ?? "Album"
                return Album(id: collection.localIdentifier, title: title, count: count, isSmart: isSmart)
            }

            let smartResult = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .any, options: nil)
            smartResult.enumerateObjects { collection, _, _ in
                if let album = makeAlbum(collection, isSmart: true) { smart.append(album) }
            }

            let userResult = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
            userResult.enumerateObjects { collection, _, _ in
                if let album = makeAlbum(collection, isSmart: false) { user.append(album) }
            }

            user.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            return smart + user
        }.value
    }

    // MARK: - Fetch (rotation)

    static func fetch(albumIdentifier: String) async throws -> [WallpaperItem] {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw FeedError.invalidConfiguration(
                "Rollpaper doesn't have access to your photos. Grant access in System Settings › Privacy & Security › Photos."
            )
        }

        return try await Task.detached(priority: .userInitiated) {
            let collections = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [albumIdentifier],
                options: nil
            )
            guard let collection = collections.firstObject else {
                throw FeedError.invalidConfiguration(
                    "The chosen photo album is no longer available. Remove the feed and add it again."
                )
            }

            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
            let assets = PHAsset.fetchAssets(in: collection, options: options)

            var items: [WallpaperItem] = []
            items.reserveCapacity(assets.count)
            assets.enumerateObjects { asset, _, _ in
                items.append(WallpaperItem(
                    id: asset.localIdentifier,
                    imageURL: url(forAssetIdentifier: asset.localIdentifier),
                    // No meaningful "source" to reveal; the menu item stays disabled.
                    sourceURL: nil,
                    createdAt: asset.creationDate
                ))
            }
            return items
        }.value
    }

    // MARK: - Materialize (called lazily for the picked item)

    /// Full-resolution image bytes for an asset, plus its preferred file
    /// extension. Allows iCloud download so members of shared/optimized
    /// libraries still resolve.
    static func loadAssetData(identifier: String) async throws -> (data: Data, fileExtension: String?) {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = assets.firstObject else {
            throw FeedError.invalidConfiguration("This photo is no longer in your library.")
        }

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.isSynchronous = false

        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, info in
                if let data {
                    let ext = uti.flatMap { UTType($0)?.preferredFilenameExtension }
                    continuation.resume(returning: (data, ext))
                } else {
                    let message = (info?[PHImageErrorKey] as? NSError)?.localizedDescription
                        ?? "Could not load the photo from your library."
                    continuation.resume(throwing: FeedError.network(message))
                }
            }
        }
    }
}
