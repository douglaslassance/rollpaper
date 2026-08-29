import Foundation

enum BlueskyClient {
    /// Rewrites what someone actually typed into something the API accepts, so a
    /// small input mistake doesn't leave a feed failing forever. Handles
    /// surrounding whitespace, a leading "@", a pasted profile link, and the
    /// most common mistake of all: a bare username. Bluesky handles are domains,
    /// so "louie" is not a valid identifier and has to become
    /// "louie.bsky.social". Feed references (AT-URIs and bsky.app feed links)
    /// pass through untouched for `fetchFeed` to parse.
    static func normalized(_ reference: String) -> String {
        var value = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return value }
        if value.hasPrefix("at://") || parseFeedLink(value) != nil { return value }

        if let handle = parseProfileLink(value) { value = handle }
        if value.hasPrefix("@") { value = String(value.dropFirst()) }
        while value.hasSuffix("/") { value.removeLast() }

        // A DID is already an identifier, and anything with a dot is already a
        // domain (bsky.social or a custom one). Only a bare name needs the
        // default host appended.
        guard !value.isEmpty, !value.hasPrefix("did:"), !value.contains(".") else { return value }
        return value + ".bsky.social"
    }

    /// True when `reference` identifies a custom feed (an AT-URI or a bsky.app feed link)
    /// rather than a plain account handle/DID.
    static func isFeedReference(_ reference: String) -> Bool {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("at://") || parseFeedLink(trimmed) != nil
    }

    /// Fetches an account's posts or a custom feed, auto-detected from `reference`:
    /// a handle/DID (optionally "@"-prefixed), an AT-URI, or a bsky.app feed link.
    static func fetch(_ reference: String) async throws -> [WallpaperItem] {
        let trimmed = normalized(reference)
        guard !trimmed.isEmpty else {
            throw FeedError.invalidConfiguration("Bluesky handle or feed link is empty")
        }

        if trimmed.hasPrefix("at://") || parseFeedLink(trimmed) != nil {
            return try await fetchFeed(trimmed)
        }

        let actor = trimmed
        var components = URLComponents(string: "https://public.api.bsky.app/xrpc/app.bsky.feed.getAuthorFeed")!
        components.queryItems = [
            URLQueryItem(name: "actor", value: actor),
            URLQueryItem(name: "limit", value: "50"),
            URLQueryItem(name: "filter", value: "posts_with_media")
        ]
        guard let url = components.url else {
            throw FeedError.invalidConfiguration("Could not build Bluesky URL")
        }
        return try await fetchAndDecode(url: url)
    }

    /// Fetches a custom feed given either its AT-URI (at://did/app.bsky.feed.generator/name)
    /// or the bsky.app link a user would copy from the app (https://bsky.app/profile/x/feed/name).
    private static func fetchFeed(_ reference: String) async throws -> [WallpaperItem] {
        let feedURI: String
        if reference.hasPrefix("at://") {
            feedURI = reference
        } else if let parsed = parseFeedLink(reference) {
            let did = try await resolveDID(for: parsed.actor)
            feedURI = "at://\(did)/app.bsky.feed.generator/\(parsed.feedName)"
        } else {
            throw FeedError.invalidConfiguration("Could not parse Bluesky feed link")
        }

        var components = URLComponents(string: "https://public.api.bsky.app/xrpc/app.bsky.feed.getFeed")!
        components.queryItems = [
            URLQueryItem(name: "feed", value: feedURI),
            URLQueryItem(name: "limit", value: "50")
        ]
        guard let url = components.url else {
            throw FeedError.invalidConfiguration("Could not build Bluesky feed URL")
        }
        return try await fetchAndDecode(url: url)
    }

    private static func parseFeedLink(_ string: String) -> (actor: String, feedName: String)? {
        guard let url = bskyAppURL(string) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 4, parts[0] == "profile", parts[2] == "feed" else { return nil }
        return (actor: parts[1], feedName: parts[3])
    }

    /// The handle out of a pasted profile link, e.g.
    /// https://bsky.app/profile/louie.bsky.social.
    private static func parseProfileLink(_ string: String) -> String? {
        guard let url = bskyAppURL(string) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, parts[0] == "profile" else { return nil }
        return parts[1]
    }

    /// Parses a bsky.app link with or without its scheme, since copying one out
    /// of a browser's address bar often drops the "https://".
    private static func bskyAppURL(_ string: String) -> URL? {
        let candidate = string.contains("://") ? string : "https://" + string
        guard let url = URL(string: candidate), url.host == "bsky.app" else { return nil }
        return url
    }

    private static func resolveDID(for actor: String) async throws -> String {
        if actor.hasPrefix("did:") { return actor }
        var components = URLComponents(string: "https://public.api.bsky.app/xrpc/com.atproto.identity.resolveHandle")!
        components.queryItems = [URLQueryItem(name: "handle", value: actor)]
        guard let url = components.url else {
            throw FeedError.invalidConfiguration("Could not build Bluesky handle resolution URL")
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FeedError.network("Bluesky handle resolution returned HTTP \(http.statusCode)")
        }
        return try JSONDecoder().decode(ResolvedHandle.self, from: data).did
    }

    private static func fetchAndDecode(url: URL) async throws -> [WallpaperItem] {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FeedError.network("Bluesky returned HTTP \(http.statusCode)")
        }

        let decoded = try JSONDecoder.bluesky.decode(AuthorFeedResponse.self, from: data)
        return decoded.feed.flatMap { entry -> [WallpaperItem] in
            let post = entry.post
            let images = post.embed?.images ?? []
            let postURL = makePostURL(uri: post.uri, handle: post.author.handle)
            return images.compactMap { image -> WallpaperItem? in
                guard let imageURL = URL(string: image.fullsize) else { return nil }
                return WallpaperItem(
                    id: image.fullsize,
                    imageURL: imageURL,
                    sourceURL: postURL,
                    createdAt: post.indexedAt
                )
            }
        }
    }

    private static func makePostURL(uri: String, handle: String) -> URL? {
        guard let rkey = uri.split(separator: "/").last else { return nil }
        return URL(string: "https://bsky.app/profile/\(handle)/post/\(rkey)")
    }

    private struct ResolvedHandle: Decodable {
        let did: String
    }

    private struct AuthorFeedResponse: Decodable {
        let feed: [Entry]
    }

    private struct Entry: Decodable {
        let post: Post
    }

    private struct Post: Decodable {
        let uri: String
        let author: Author
        let indexedAt: Date
        let embed: Embed?
    }

    private struct Author: Decodable {
        let handle: String
    }

    private struct Embed: Decodable {
        let images: [EmbeddedImage]?

        private enum CodingKeys: String, CodingKey {
            case images
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.images = try container.decodeIfPresent([EmbeddedImage].self, forKey: .images)
        }
    }

    private struct EmbeddedImage: Decodable {
        let fullsize: String
    }
}

private extension JSONDecoder {
    static let bluesky: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let container = try dec.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = ISO8601.tolerant(raw) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unparseable date: \(raw)"
            )
        }
        return decoder
    }()
}
