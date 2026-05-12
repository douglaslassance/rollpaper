import XCTest
@testable import App

final class SmokeTests: XCTestCase {
    func testFeedConfigRoundTrip() throws {
        let config = FeedConfig(kind: .bluesky, name: "Test", handle: "user.bsky.social")
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(FeedConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    func testTolerantISO8601() {
        XCTAssertNotNil(ISO8601.tolerant("2024-01-15T12:34:56Z"))
        XCTAssertNotNil(ISO8601.tolerant("2024-01-15T12:34:56.789Z"))
        XCTAssertNil(ISO8601.tolerant("not a date"))
    }
}
