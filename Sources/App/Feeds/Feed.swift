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

    var displayName: String {
        switch self {
        case .bluesky: return "Bluesky"
        case .mastodon: return "Mastodon"
        }
    }
}

struct FeedConfig: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var kind: FeedKind
    var name: String
    var handle: String
    var instance: String?

    init(
        id: UUID = UUID(),
        kind: FeedKind,
        name: String,
        handle: String,
        instance: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.handle = handle
        self.instance = instance
    }

    var subtitle: String {
        switch kind {
        case .bluesky: return "Bluesky · \(handle)"
        case .mastodon: return "Mastodon · \(handle)"
        }
    }

    func fetch() async throws -> [WallpaperItem] {
        switch kind {
        case .bluesky:
            return try await BlueskyClient.fetch(actor: handle)
        case .mastodon:
            return try await MastodonClient.fetch(account: handle, instance: instance)
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
