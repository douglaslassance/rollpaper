import Foundation

enum BlueskyClient {
    static func fetch(actor: String) async throws -> [WallpaperItem] {
        let trimmed = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FeedError.invalidConfiguration("Bluesky actor handle is empty")
        }

        var components = URLComponents(string: "https://public.api.bsky.app/xrpc/app.bsky.feed.getAuthorFeed")!
        components.queryItems = [
            URLQueryItem(name: "actor", value: trimmed),
            URLQueryItem(name: "limit", value: "50"),
            URLQueryItem(name: "filter", value: "posts_with_media")
        ]
        guard let url = components.url else {
            throw FeedError.invalidConfiguration("Could not build Bluesky URL")
        }

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
