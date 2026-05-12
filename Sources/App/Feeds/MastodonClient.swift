import Foundation

enum MastodonClient {
    static func fetch(account: String, instance: String?) async throws -> [WallpaperItem] {
        let trimmedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAccount.isEmpty else {
            throw FeedError.invalidConfiguration("Mastodon account is empty")
        }
        let baseURL = try resolveInstanceURL(account: trimmedAccount, instance: instance)
        let accountID = try await lookup(account: trimmedAccount, baseURL: baseURL)
        return try await fetchStatuses(accountID: accountID, baseURL: baseURL)
    }

    private static func resolveInstanceURL(account: String, instance: String?) throws -> URL {
        if let instance, !instance.isEmpty {
            let normalized = instance.hasPrefix("http") ? instance : "https://\(instance)"
            guard let url = URL(string: normalized) else {
                throw FeedError.invalidConfiguration("Invalid Mastodon instance URL")
            }
            return url
        }
        let parts = account.split(separator: "@", omittingEmptySubsequences: true)
        if parts.count == 2, let url = URL(string: "https://\(parts[1])") {
            return url
        }
        throw FeedError.invalidConfiguration(
            "Mastodon instance is required when account is not in user@instance form"
        )
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
        return statuses.flatMap { status -> [WallpaperItem] in
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
