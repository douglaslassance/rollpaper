import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var feeds: [FeedConfig] {
        didSet { persistFeeds() }
    }

    @Published private(set) var currentWallpaper: WallpaperItem?
    @Published private(set) var currentLocalFile: URL?
    @Published private(set) var isRefreshing: Bool = false
    @Published private(set) var lastError: String?

    @AppStorage("rotationIntervalSeconds") var rotationIntervalSeconds: Double = 3600
    @AppStorage("fitMode") var fitMode: FitMode = .fill
    @AppStorage("fadeEnabled") var fadeEnabled: Bool = true
    @AppStorage("fadeDurationSeconds") var fadeDurationSeconds: Double = 0.6

    private var rotationTask: Task<Void, Never>?

    /// imageURL.absoluteString → last time we set it as the wallpaper.
    /// Used to dampen the pick weight of recently-shown images; the dampening
    /// decays back toward 1.0 with time (see `pickWeighted`).
    private var seenAt: [String: Date]

    /// Wallpapers the user excluded via "Don't show this again".
    /// Ordered newest-first for the Blocked settings tab.
    @Published private(set) var blocked: [BlockedEntry] {
        didSet {
            blockedURLs = Set(blocked.map(\.id))
            persistBlocked()
        }
    }
    /// Mirror of `blocked` keyed by `imageURL.absoluteString` for O(1) filtering.
    private var blockedURLs: Set<String>

    init() {
        self.feeds = Self.loadFeeds()
        self.seenAt = Self.loadSeenAt()
        let initialBlocked = Self.loadBlocked()
        self.blocked = initialBlocked
        self.blockedURLs = Set(initialBlocked.map(\.id))
        startRotation()
    }

    deinit {
        rotationTask?.cancel()
    }

    func rotateNow() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            var items: [WallpaperItem] = []
            for feed in feeds {
                let fetched = try await feed.fetch()
                items.append(contentsOf: fetched)
            }
            let fetchedCount = items.count
            items.removeAll { blockedURLs.contains($0.imageURL.absoluteString) }
            guard let pick = pickWeighted(items) else {
                if feeds.isEmpty {
                    lastError = "No feeds configured"
                } else if fetchedCount > 0 {
                    lastError = "All current feed items are blocked"
                } else {
                    lastError = "No images in feeds"
                }
                return
            }
            let newLocal = try await WallpaperManager.shared.download(pick.imageURL)
            let previousLocal = currentLocalFile

            if fadeEnabled, let previousLocal {
                WallpaperFader.shared.showOverlay(imageFile: previousLocal, fitMode: fitMode)
                try WallpaperManager.shared.setDesktopImage(newLocal, fitMode: fitMode)
                await WallpaperFader.shared.fadeOutAndRemove(duration: fadeDurationSeconds)
            } else {
                try WallpaperManager.shared.setDesktopImage(newLocal, fitMode: fitMode)
            }

            currentWallpaper = pick
            currentLocalFile = newLocal
            lastError = nil
            recordSeen(pick)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func applyFitModeToCurrent() {
        guard let file = currentLocalFile else { return }
        try? WallpaperManager.shared.setDesktopImage(file, fitMode: fitMode)
    }

    func downloadCurrentWallpaper() {
        guard let local = currentLocalFile else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = local.lastPathComponent
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? FileManager.default.copyItem(at: local, to: dest)
    }

    func openCurrentWallpaperSource() {
        guard let url = currentWallpaper?.sourceURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Add the current wallpaper to the blocklist and immediately rotate to a
    /// new one. If a rotation is already in flight, the guard in `rotateNow`
    /// will skip; the blocked image is still excluded from future picks.
    func blockCurrentWallpaper() {
        guard let item = currentWallpaper else { return }
        let key = item.imageURL.absoluteString
        guard !blockedURLs.contains(key) else { return }
        let entry = BlockedEntry(
            imageURL: item.imageURL,
            sourceURL: item.sourceURL,
            addedAt: Date()
        )
        blocked.insert(entry, at: 0)
        Task { await rotateNow() }
    }

    func unblock(_ entry: BlockedEntry) {
        blocked.removeAll { $0.id == entry.id }
    }

    func clearBlocked() {
        blocked.removeAll()
    }

    func restartRotation() {
        startRotation()
    }

    private func startRotation() {
        rotationTask?.cancel()
        let interval = max(60, rotationIntervalSeconds)
        rotationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.rotateNow()
            }
        }
    }

    private func pickWeighted(_ items: [WallpaperItem]) -> WallpaperItem? {
        guard !items.isEmpty else { return nil }
        let sorted = items.sorted {
            ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
        }
        // Scale recency decay to pool size so the oldest item retains ~e^-2.5
        // (~0.08) of the newest's base weight regardless of feed length. That
        // keeps it reachable once recent items fall into cooldown, but still
        // strongly biases new posts when nothing has been shown.
        let decay = 2.5 / Double(max(sorted.count - 1, 1))
        // Cooldown half-life: ~20 rotations. After this much elapsed time, a
        // previously-shown image is back to 50% of its base weight; it
        // approaches 100% asymptotically.
        let halfLife = max(rotationIntervalSeconds * 20, 3600)
        let now = Date()
        let weights: [Double] = sorted.enumerated().map { idx, item in
            let base = exp(-decay * Double(idx))
            return base * cooldownFactor(for: item, now: now, halfLife: halfLife)
        }
        let total = weights.reduce(0, +)
        // Every candidate is in deep cooldown (e.g. single-item pool just
        // shown). Fall back to a uniform draw so we don't deadlock.
        guard total > 0 else { return sorted.randomElement() }
        let target = Double.random(in: 0..<total)
        var acc = 0.0
        for (idx, weight) in weights.enumerated() {
            acc += weight
            if target < acc { return sorted[idx] }
        }
        return sorted.last
    }

    /// 1.0 if we've never shown this image; ramps from ~0 back toward 1.0
    /// as the elapsed time since last shown crosses several half-lives.
    private func cooldownFactor(for item: WallpaperItem, now: Date, halfLife: Double) -> Double {
        guard let last = seenAt[item.imageURL.absoluteString] else { return 1.0 }
        let elapsed = max(0, now.timeIntervalSince(last))
        return 1 - pow(0.5, elapsed / halfLife)
    }

    private func recordSeen(_ item: WallpaperItem) {
        let now = Date()
        seenAt[item.imageURL.absoluteString] = now
        // Prune entries that have fully recovered so the dict doesn't grow
        // without bound. 10 half-lives → cooldown factor > 0.999.
        let horizon = max(rotationIntervalSeconds * 20, 3600) * 10
        seenAt = seenAt.filter { now.timeIntervalSince($0.value) < horizon }
        persistSeenAt()
    }

    // MARK: - Persistence

    private static let feedsKey = "feeds.v1"
    private static let seenAtKey = "seenAt.v1"
    private static let blockedKey = "blocked.v1"

    private static func loadFeeds() -> [FeedConfig] {
        guard let data = UserDefaults.standard.data(forKey: feedsKey) else { return [] }
        return (try? JSONDecoder().decode([FeedConfig].self, from: data)) ?? []
    }

    private func persistFeeds() {
        guard let data = try? JSONEncoder().encode(feeds) else { return }
        UserDefaults.standard.set(data, forKey: Self.feedsKey)
    }

    private static func loadSeenAt() -> [String: Date] {
        guard let data = UserDefaults.standard.data(forKey: seenAtKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Date].self, from: data)) ?? [:]
    }

    private func persistSeenAt() {
        guard let data = try? JSONEncoder().encode(seenAt) else { return }
        UserDefaults.standard.set(data, forKey: Self.seenAtKey)
    }

    private static func loadBlocked() -> [BlockedEntry] {
        guard let data = UserDefaults.standard.data(forKey: blockedKey) else { return [] }
        return (try? JSONDecoder().decode([BlockedEntry].self, from: data)) ?? []
    }

    private func persistBlocked() {
        guard let data = try? JSONEncoder().encode(blocked) else { return }
        UserDefaults.standard.set(data, forKey: Self.blockedKey)
    }
}
