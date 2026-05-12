import AppKit

@MainActor
final class WallpaperFader {
    static let shared = WallpaperFader()

    private var windows: [NSWindow] = []

    private init() {}

    func showOverlay(imageFile: URL, fitMode: FitMode) {
        dismissImmediately()
        guard let image = NSImage(contentsOf: imageFile),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }

        windows = NSScreen.screens.map { screen in
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.ignoresMouseEvents = true
            window.hasShadow = false
            window.animationBehavior = .none
            window.collectionBehavior = [
                .canJoinAllSpaces,
                .stationary,
                .ignoresCycle,
                .fullScreenAuxiliary
            ]
            let iconLevel = CGWindowLevelForKey(.desktopIconWindow)
            window.level = NSWindow.Level(rawValue: Int(iconLevel) - 1)

            let container = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            let imageLayer = CALayer()
            imageLayer.frame = container.bounds
            imageLayer.contents = cgImage
            imageLayer.contentsGravity = fitMode.contentsGravity
            imageLayer.contentsScale = screen.backingScaleFactor
            imageLayer.backgroundColor = NSColor.black.cgColor
            imageLayer.masksToBounds = true
            imageLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            container.layer = imageLayer
            container.wantsLayer = true
            CATransaction.commit()

            window.contentView = container
            window.alphaValue = 1.0
            window.orderFrontRegardless()
            return window
        }
    }

    func fadeOutAndRemove(duration: TimeInterval) async {
        guard !windows.isEmpty else { return }
        let activeWindows = windows
        await withCheckedContinuation { continuation in
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                for window in activeWindows {
                    window.animator().alphaValue = 0
                }
            }, completionHandler: {
                continuation.resume()
            })
        }
        for window in activeWindows {
            window.orderOut(nil)
        }
        windows.removeAll(where: { activeWindows.contains($0) })
    }

    private func dismissImmediately() {
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
    }
}
