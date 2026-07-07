import Foundation

enum RedditClient {
    /// Public OAuth client id for Reddit's "installed app" grant. Not a secret:
    /// this grant type authenticates the app, not a user, and needs no client secret.
    /// Register one at https://www.reddit.com/prefs/apps ("installed app" type).
    private static let clientID = "YOUR_REDDIT_CLIENT_ID"
    private static let userAgent = "macos:com.rollpaper.app:v1 (by /u/rollpaperapp)"

    static func fetch(subreddit: String) async throws -> [WallpaperItem] {
        var trimmed = subreddit.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("r/") {
            trimmed = String(trimmed.dropFirst(2))
        }
        guard !trimmed.isEmpty else {
            throw FeedError.invalidConfiguration("Subreddit name is empty")
        }

        let token = try await fetchToken()

        var components = URLComponents(string: "https://oauth.reddit.com/r/\(trimmed)/hot")!
        components.queryItems = [
            URLQueryItem(name: "limit", value: "50"),
            URLQueryItem(name: "raw_json", value: "1")
        ]
        guard let url = components.url else {
            throw FeedError.invalidConfiguration("Could not build Reddit URL")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FeedError.network("Reddit returned HTTP \(http.statusCode)")
        }

        let listing = try JSONDecoder().decode(Listing.self, from: data)
        return listing.data.children.flatMap { $0.data.wallpaperItems }
    }

    private static func fetchToken() async throws -> String {
        var request = URLRequest(url: URL(string: "https://www.reddit.com/api/v1/access_token")!)
        request.httpMethod = "POST"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let credentials = Data("\(clientID):".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        let body = "grant_type=https://oauth.reddit.com/grants/installed_client&device_id=rollpaper-app"
        request.httpBody = Data(body.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FeedError.network("Reddit auth returned HTTP \(http.statusCode)")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data).accessToken
    }

    private struct TokenResponse: Decodable {
        let accessToken: String

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
        }
    }

    private struct Listing: Decodable {
        let data: ListingData
    }

    private struct ListingData: Decodable {
        let children: [Child]
    }

    private struct Child: Decodable {
        let data: Post
    }

    private struct Post: Decodable {
        let id: String
        let permalink: String
        let createdUTC: Double
        let postHint: String?
        let url: String?
        let isGallery: Bool?
        let mediaMetadata: [String: MediaMetadataEntry]?
        let stickied: Bool
        let over18: Bool

        private enum CodingKeys: String, CodingKey {
            case id, permalink, url, stickied
            case createdUTC = "created_utc"
            case postHint = "post_hint"
            case isGallery = "is_gallery"
            case mediaMetadata = "media_metadata"
            case over18 = "over_18"
        }

        var wallpaperItems: [WallpaperItem] {
            guard !stickied, !over18 else { return [] }
            let sourceURL = URL(string: "https://www.reddit.com\(permalink)")
            let createdAt = Date(timeIntervalSince1970: createdUTC)

            if isGallery == true, let mediaMetadata {
                return mediaMetadata.compactMap { key, entry -> WallpaperItem? in
                    guard let imageURL = entry.imageURL else { return nil }
                    return WallpaperItem(id: key, imageURL: imageURL, sourceURL: sourceURL, createdAt: createdAt)
                }
            }

            guard postHint == "image", let url, let imageURL = URL(string: url) else {
                return []
            }
            return [WallpaperItem(id: id, imageURL: imageURL, sourceURL: sourceURL, createdAt: createdAt)]
        }
    }

    private struct MediaMetadataEntry: Decodable {
        let e: String?
        let s: MediaSource?

        var imageURL: URL? {
            guard e == "Image", let raw = s?.u else { return nil }
            return URL(string: raw.replacingOccurrences(of: "&amp;", with: "&"))
        }
    }

    private struct MediaSource: Decodable {
        let u: String?
    }
}
