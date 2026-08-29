import Foundation

struct WallpaperItem: Equatable, Hashable, Codable, Sendable {
    let id: String
    let imageURL: URL
    let sourceURL: URL?
    let createdAt: Date?
}

/// A wallpaper the user explicitly excluded via "Don't show this again".
/// Persisted across launches; reviewed in the Filtered settings tab.
struct FilteredEntry: Codable, Hashable, Identifiable, Sendable {
    let imageURL: URL
    let sourceURL: URL?
    let addedAt: Date

    var id: String { imageURL.absoluteString }
}

enum FeedKind: String, Codable, CaseIterable, Sendable {
    case bluesky
    case mastodon
    case reddit
    case localFolder
    case photosLibrary

    var displayName: String {
        switch self {
        case .bluesky: return "Bluesky"
        case .mastodon: return "Mastodon"
        case .reddit: return "Reddit"
        case .localFolder: return "Folder"
        case .photosLibrary: return "Photos"
        }
    }
}

struct FeedConfig: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var kind: FeedKind
    var name: String
    /// For remote feeds this holds the handle/subreddit/feed link. For a local
    /// folder feed it holds the folder path, shown in the subtitle; the actual
    /// access is granted by `bookmark`. For a Photos-library feed it holds the
    /// chosen album's `PHAssetCollection.localIdentifier`.
    var handle: String
    /// Security-scoped bookmark for `.localFolder` feeds, so the app can re-read
    /// the user-picked folder across launches inside the sandbox. Nil for remote
    /// feeds; optional so previously persisted feeds still decode.
    var bookmark: Data?

    init(
        id: UUID = UUID(),
        kind: FeedKind,
        name: String,
        handle: String,
        bookmark: Data? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.handle = handle
        self.bookmark = bookmark
    }

    var subtitle: String {
        switch kind {
        case .bluesky:
            return BlueskyClient.isFeedReference(handle) ? "Bluesky feed · \(handle)" : "Bluesky · \(handle)"
        case .mastodon:
            return "Mastodon · \(handle)"
        case .reddit:
            return "Reddit · r/\(handle)"
        case .localFolder:
            return "Folder · \(handle)"
        case .photosLibrary:
            // `handle` is an opaque album identifier, so lean on `name` (the
            // album's title) for a readable subtitle.
            return "Photos · \(name)"
        }
    }

    /// Cleaned-up copy of this config, so a handle saved by an older build (or
    /// typed with a stray "@", a pasted profile link, or as a bare username) is
    /// both stored and displayed in the form the API accepts.
    func normalizedCopy() -> FeedConfig {
        guard kind == .bluesky else { return self }
        let cleaned = BlueskyClient.normalized(handle)
        guard cleaned != handle else { return self }
        var copy = self
        copy.handle = cleaned
        // The name defaults to the handle when the user leaves it blank, so it
        // has to follow the correction rather than keep showing the old text.
        if name == handle { copy.name = cleaned }
        return copy
    }

    func fetch() async throws -> [WallpaperItem] {
        switch kind {
        case .bluesky:
            return try await BlueskyClient.fetch(handle)
        case .mastodon:
            return try await MastodonClient.fetch(handle)
        case .reddit:
            return try await RedditClient.fetch(subreddit: handle)
        case .localFolder:
            return try await LocalFolderClient.fetch(bookmark: bookmark)
        case .photosLibrary:
            return try await PhotosLibraryClient.fetch(albumIdentifier: handle)
        }
    }
}

enum FeedError: LocalizedError {
    case invalidConfiguration(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let msg): return msg
        case .network(let msg): return msg
        }
    }
}

enum ISO8601 {
    static let tolerant: (String) -> Date? = { input in
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: input) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: input)
    }
}
