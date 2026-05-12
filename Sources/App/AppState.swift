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

    init() {
        self.feeds = Self.loadFeeds()
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
            guard let pick = pickWeighted(items) else {
                lastError = feeds.isEmpty ? "No feeds configured" : "No images in feeds"
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
        let decay = 0.1
        let weights = (0..<sorted.count).map { exp(-decay * Double($0)) }
        let total = weights.reduce(0, +)
        let target = Double.random(in: 0..<total)
        var acc = 0.0
        for (idx, weight) in weights.enumerated() {
            acc += weight
            if target < acc { return sorted[idx] }
        }
        return sorted.last
    }

    // MARK: - Persistence

    private static let feedsKey = "feeds.v1"

    private static func loadFeeds() -> [FeedConfig] {
        guard let data = UserDefaults.standard.data(forKey: feedsKey) else { return [] }
        return (try? JSONDecoder().decode([FeedConfig].self, from: data)) ?? []
    }

    private func persistFeeds() {
        guard let data = try? JSONEncoder().encode(feeds) else { return }
        UserDefaults.standard.set(data, forKey: Self.feedsKey)
    }
}
