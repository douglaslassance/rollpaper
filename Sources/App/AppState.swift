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
    /// The original, non-upscaled download of `currentLocalFile`. Kept around
    /// (and out of the cache prune) so saving the wallpaper to disk never
    /// exports the upscaled version.
    @Published private(set) var currentLocalOriginalFile: URL?
    @Published private(set) var isRefreshing: Bool = false
    @Published private(set) var lastError: String?

    @AppStorage("rotationIntervalSeconds") var rotationIntervalSeconds: Double = 3600
    @AppStorage("fitMode") var fitMode: FitMode = .fill
    /// Pro-only: upscale each wallpaper toward the display resolution with
    /// MetalFX before setting it. Gated at use-time on `hasProAccess`.
    @AppStorage("upscaleEnabled") var upscaleEnabled: Bool = false

    private var rotationTask: Task<Void, Never>?
    /// Set when `rotateNow()` is called while another rotation is already in
    /// flight (e.g. the automatic timer racing a manual trigger like
    /// "Don't show this again"). Without this, the guard below would just
    /// silently drop the request instead of running it once the in-flight
    /// rotation finishes.
    private var rotateAgainRequested = false

    /// imageURL.absoluteString → last time we set it as the wallpaper.
    /// Used to dampen the pick weight of recently-shown images; the dampening
    /// decays back toward 1.0 with time (see `pickWeighted`).
    private var seenAt: [String: Date]

    /// Wallpapers the user excluded via "Don't show this again".
    /// Ordered newest-first for the Filtered settings tab.
    @Published private(set) var filtered: [FilteredEntry] {
        didSet {
            filteredURLs = Set(filtered.map(\.id))
            persistFiltered()
        }
    }
    /// Mirror of `filtered` keyed by `imageURL.absoluteString` for O(1) filtering.
    private var filteredURLs: Set<String>

    init() {
        self.feeds = Self.loadFeeds()
        self.seenAt = Self.loadSeenAt()
        let initialFiltered = Self.loadFiltered()
        self.filtered = initialFiltered
        self.filteredURLs = Set(initialFiltered.map(\.id))
        startRotation()
    }

    deinit {
        rotationTask?.cancel()
    }

    func rotateNow() async {
        guard !isRefreshing else {
            rotateAgainRequested = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        repeat {
            rotateAgainRequested = false
            await performRotation()
        } while rotateAgainRequested
    }

    private func performRotation() async {
        do {
            var items: [WallpaperItem] = []
            for feed in feeds {
                let fetched = try await feed.fetch()
                items.append(contentsOf: fetched)
            }
            let fetchedCount = items.count
            items.removeAll { filteredURLs.contains($0.imageURL.absoluteString) }
            guard let pick = pickWeighted(items) else {
                if feeds.isEmpty {
                    lastError = "No feeds configured"
                } else if fetchedCount > 0 {
                    lastError = "All current feed items are filtered out"
                } else {
                    lastError = "No images in feeds"
                }
                return
            }
            let newLocal = try await WallpaperManager.shared.download(pick.imageURL)
            let fileToSet: URL
            if upscaleEnabled && EntitlementManager.shared.hasProAccess {
                fileToSet = await WallpaperManager.shared.upscaledIfBeneficial(newLocal)
            } else {
                fileToSet = newLocal
            }
            try WallpaperManager.shared.setDesktopImage(fileToSet, fitMode: fitMode)
            WallpaperManager.shared.pruneCache(keeping: [fileToSet, newLocal])

            currentWallpaper = pick
            currentLocalFile = fileToSet
            currentLocalOriginalFile = newLocal
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

    func saveCurrentWallpaperAs() {
        guard let local = currentLocalOriginalFile else { return }
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

    /// Add the current wallpaper to the filter list and immediately rotate to
    /// a new one. If a rotation is already in flight, the guard in `rotateNow`
    /// will skip; the filtered image is still excluded from future picks.
    func filterCurrentWallpaper() {
        guard let item = currentWallpaper else { return }
        let key = item.imageURL.absoluteString
        guard !filteredURLs.contains(key) else { return }
        let entry = FilteredEntry(
            imageURL: item.imageURL,
            sourceURL: item.sourceURL,
            addedAt: Date()
        )
        filtered.insert(entry, at: 0)
        Task { await rotateNow() }
    }

    func unfilter(_ entry: FilteredEntry) {
        filtered.removeAll { $0.id == entry.id }
    }

    func clearFiltered() {
        filtered.removeAll()
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
    // Persisted key kept as "blocked.v1" so existing user data still loads.
    private static let filteredKey = "blocked.v1"

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

    private static func loadFiltered() -> [FilteredEntry] {
        guard let data = UserDefaults.standard.data(forKey: filteredKey) else { return [] }
        return (try? JSONDecoder().decode([FilteredEntry].self, from: data)) ?? []
    }

    private func persistFiltered() {
        guard let data = try? JSONEncoder().encode(filtered) else { return }
        UserDefaults.standard.set(data, forKey: Self.filteredKey)
    }
}
