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

    /// True when there is at least one earlier wallpaper to step back to.
    @Published private(set) var canGoToPreviousWallpaper = false

    /// A wallpaper we can re-apply without re-fetching, because its local
    /// files are still on disk (kept out of the cache prune).
    private struct WallpaperSnapshot {
        let wallpaper: WallpaperItem
        let localFile: URL
        let localOriginalFile: URL
    }

    /// Back-stack of previously-shown wallpapers, oldest-first, powering
    /// "Previous Wallpaper". Capped so the (potentially large, upscaled) local
    /// files don't accumulate; each entry's files are retained by the prune.
    private var history: [WallpaperSnapshot] = [] {
        didSet { canGoToPreviousWallpaper = !history.isEmpty }
    }
    private let maxHistoryCount = 10

    @AppStorage("rotationIntervalSeconds") var rotationIntervalSeconds: Double = 3600
    @AppStorage("fitMode") var fitMode: FitMode = .fill
    /// Pro-only: upscale each wallpaper toward the display resolution with
    /// MetalFX before setting it. Gated at use-time on `hasProAccess`.
    @AppStorage("upscaleEnabled") var upscaleEnabled: Bool = false

    private var rotationTask: Task<Void, Never>?
    /// One-shot retry scheduled after a rotation fails, so recovery doesn't wait
    /// for the next full interval (which can be hours or a day). Cancelled once a
    /// rotation succeeds.
    private var retryTask: Task<Void, Never>?
    private var consecutiveFailures = 0
    /// Backoff for the failure retry: 30s, doubling up to 10 minutes.
    private let baseRetryDelay: Double = 30
    private let maxRetryDelay: Double = 600
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
        retryTask?.cancel()
    }

    func rotateNow() async {
        guard !isRefreshing else {
            rotateAgainRequested = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        var failed = false
        repeat {
            rotateAgainRequested = false
            failed = await performRotation()
        } while rotateAgainRequested
        scheduleRetryIfNeeded(failed: failed)
    }

    /// After a genuine rotation failure (e.g. a network hiccup or a transiently
    /// missing cache), retry with exponential backoff instead of waiting for the
    /// next scheduled interval. A success cancels the pending retry and resets
    /// the backoff.
    private func scheduleRetryIfNeeded(failed: Bool) {
        retryTask?.cancel()
        guard failed else {
            consecutiveFailures = 0
            retryTask = nil
            return
        }
        consecutiveFailures += 1
        let delay = min(baseRetryDelay * pow(2, Double(consecutiveFailures - 1)), maxRetryDelay)
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.rotateNow()
        }
    }

    /// Step back to the previously-shown wallpaper. Its local files are still
    /// on disk (kept out of the cache prune), so this re-applies them without
    /// a fetch. Skipped while a rotation is in flight to avoid racing it.
    func showPreviousWallpaper() {
        guard !isRefreshing, let snapshot = history.popLast() else { return }
        do {
            try WallpaperManager.shared.setDesktopImage(snapshot.localFile, fitMode: fitMode)
            currentWallpaper = snapshot.wallpaper
            currentLocalFile = snapshot.localFile
            currentLocalOriginalFile = snapshot.localOriginalFile
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Runs one rotation. Returns `true` when it failed in a way worth retrying
    /// soon (a thrown error such as a network or filesystem failure), and
    /// `false` on success or on a stable non-error condition (no feeds, or every
    /// item filtered) where an immediate retry would just repeat itself.
    @discardableResult
    private func performRotation() async -> Bool {
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
                return false
            }
            let newLocal = try await WallpaperManager.shared.download(pick.imageURL)
            let fileToSet: URL
            if upscaleEnabled && EntitlementManager.shared.hasProAccess {
                fileToSet = await WallpaperManager.shared.upscaledIfBeneficial(newLocal)
            } else {
                fileToSet = newLocal
            }
            try WallpaperManager.shared.setDesktopImage(fileToSet, fitMode: fitMode)

            // Push the outgoing wallpaper onto the back-stack before replacing it.
            if let current = currentWallpaper,
               let localFile = currentLocalFile,
               let originalFile = currentLocalOriginalFile {
                history.append(WallpaperSnapshot(
                    wallpaper: current,
                    localFile: localFile,
                    localOriginalFile: originalFile
                ))
                if history.count > maxHistoryCount { history.removeFirst() }
            }

            currentWallpaper = pick
            currentLocalFile = fileToSet
            currentLocalOriginalFile = newLocal
            lastError = nil
            recordSeen(pick)

            // Keep the current files plus every history entry's files so
            // "Previous Wallpaper" can re-apply them; prune everything else.
            let keep = [fileToSet, newLocal] + history.flatMap { [$0.localFile, $0.localOriginalFile] }
            WallpaperManager.shared.pruneCache(keeping: keep)
            return false
        } catch {
            lastError = error.localizedDescription
            return true
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
        if url.isFileURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Exclude the current wallpaper and rotate to a new one. Remote images can
    /// only be filtered (blacklisted); for a local-folder image we also offer to
    /// move the file to the Trash, since the user owns it.
    func filterCurrentWallpaper() {
        guard let item = currentWallpaper else { return }
        if item.imageURL.isFileURL {
            promptTrashOrFilter(item)
        } else {
            filter(item)
        }
    }

    /// Add `item` to the filter list and immediately rotate to a new one. If a
    /// rotation is already in flight, the guard in `rotateNow` will skip; the
    /// filtered image is still excluded from future picks.
    private func filter(_ item: WallpaperItem) {
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

    /// For a local-folder wallpaper, ask whether to move the file to the Trash
    /// or just filter it out. Cancel is the default so a stray Return never
    /// trashes a file.
    private func promptTrashOrFilter(_ item: WallpaperItem) {
        let alert = NSAlert()
        alert.messageText = "Remove “\(item.imageURL.lastPathComponent)” from rotation?"
        alert.informativeText = "Move the file to the Trash, or keep it on disk and just filter it out of Rollpaper."
        alert.alertStyle = .warning
        let trash = alert.addButton(withTitle: "Move to Trash")
        trash.hasDestructiveAction = true
        trash.keyEquivalent = ""
        alert.addButton(withTitle: "Just Filter")
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            trashCurrentFile(item)
        case .alertSecondButtonReturn:
            filter(item)
        default:
            break
        }
    }

    private func trashCurrentFile(_ item: WallpaperItem) {
        do {
            try FileManager.default.trashItem(at: item.imageURL, resultingItemURL: nil)
        } catch {
            lastError = "Could not move to Trash: \(error.localizedDescription)"
            return
        }
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
