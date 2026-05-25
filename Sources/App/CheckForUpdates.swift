#if !APPSTORE_BUILD
import SwiftUI
import Sparkle

/// File-scoped accessor for the Sparkle updater controller. Used here instead
/// of an instance property on `RollpaperApp` because Rollpaper's UI is a
/// `MenuBarExtra`, and prop-drilling the updater into the menu content view
/// is awkward. The controller is initialized lazily on first access (after
/// the app launches and Info.plist is loadable).
@MainActor
enum SparkleHost {
    static let controller: SPUStandardUpdaterController = {
        SPUStandardUpdaterController(
            startingUpdater: {
                #if DEBUG
                return false  // Sparkle keys aren't in the dev Info.plist
                #else
                return true
                #endif
            }(),
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }()
}

final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject var viewModel: CheckForUpdatesViewModel
    let updater: SPUUpdater

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!viewModel.canCheckForUpdates)
    }
}
#endif
