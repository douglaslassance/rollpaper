import Foundation

enum MastodonClient {
    /// Fetches an account's statuses or a hashtag timeline from a single reference
    /// that always carries its instance: "user@instance" (optionally "@"-prefixed)
    /// or "#hashtag@instance".
    static func fetch(_ reference: String) async throws -> [WallpaperItem] {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FeedError.invalidConfiguration("Mastodon handle or hashtag is empty")
        }

        if trimmed.hasPrefix("#") {
            let (tag, instance) = try splitNameAndInstance(String(trimmed.dropFirst()))
            return try await fetchHashtag(tag, baseURL: instance)
        }

        let withoutAt = trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
        let (account, baseURL) = try splitNameAndInstance(withoutAt)
        let accountID = try await lookup(account: account, baseURL: baseURL)
        return try await fetchStatuses(accountID: accountID, baseURL: baseURL)
    }

    /// Splits "name@instance" into the bare name and the instance's base URL.
    private static func splitNameAndInstance(_ string: String) throws -> (name: String, baseURL: URL) {
        let parts = string.split(separator: "@", omittingEmptySubsequences: true)
        guard parts.count == 2, let url = URL(string: "https://\(parts[1])") else {
            throw FeedError.invalidConfiguration(
                "Include an instance, e.g. user@mastodon.social or #hashtag@mastodon.social"
            )
        }
        return (String(parts[0]), url)
    }

    private static func fetchHashtag(_ hashtag: String, baseURL: URL) async throws -> [WallpaperItem] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/api/v1/timelines/tag/\(hashtag)"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "only_media", value: "true"),
            URLQueryItem(name: "limit", value: "40")
        ]
        guard let url = components.url else {
            throw FeedError.invalidConfiguration("Could not build Mastodon hashtag URL")
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FeedError.network("Mastodon hashtag timeline returned HTTP \(http.statusCode)")
        }
        let statuses = try JSONDecoder.mastodon.decode([Status].self, from: data)
        return statuses.flatMap(wallpaperItems(from:))
    }

    private static func lookup(account: String, baseURL: URL) async throws -> String {
        var components = URLComponents(url: baseURL.appendingPathComponent("/api/v1/accounts/lookup"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "acct", value: account)]
        guard let url = components.url else {
            throw FeedError.invalidConfiguration("Could not build Mastodon lookup URL")
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FeedError.network("Mastodon lookup returned HTTP \(http.statusCode)")
        }
        let decoded = try JSONDecoder().decode(LookupResponse.self, from: data)
        return decoded.id
    }

    private static func fetchStatuses(accountID: String, baseURL: URL) async throws -> [WallpaperItem] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/api/v1/accounts/\(accountID)/statuses"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "only_media", value: "true"),
            URLQueryItem(name: "limit", value: "40"),
            URLQueryItem(name: "exclude_replies", value: "true"),
            URLQueryItem(name: "exclude_reblogs", value: "true")
        ]
        guard let url = components.url else {
            throw FeedError.invalidConfiguration("Could not build Mastodon statuses URL")
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FeedError.network("Mastodon statuses returned HTTP \(http.statusCode)")
        }
        let statuses = try JSONDecoder.mastodon.decode([Status].self, from: data)
        return statuses.flatMap(wallpaperItems(from:))
    }

    private static func wallpaperItems(from status: Status) -> [WallpaperItem] {
        let postURL = URL(string: status.url ?? "")
        return status.mediaAttachments.compactMap { attachment in
            guard attachment.type == "image", let imageURL = URL(string: attachment.url) else { return nil }
            return WallpaperItem(
                id: attachment.id,
                imageURL: imageURL,
                sourceURL: postURL,
                createdAt: status.createdAt
            )
        }
    }

    private struct LookupResponse: Decodable {
        let id: String
    }

    private struct Status: Decodable {
        let url: String?
        let createdAt: Date?
        let mediaAttachments: [MediaAttachment]

        private enum CodingKeys: String, CodingKey {
            case url
            case createdAt = "created_at"
            case mediaAttachments = "media_attachments"
        }
    }

    private struct MediaAttachment: Decodable {
        let id: String
        let type: String
        let url: String
    }
}

private extension JSONDecoder {
    static let mastodon: JSONDecoder = {
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
