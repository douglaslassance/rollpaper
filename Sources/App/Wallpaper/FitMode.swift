import AppKit
import QuartzCore

enum FitMode: String, Codable, CaseIterable, Sendable {
    case fill
    case fit
    case stretch
    case center
    case smart

    var displayName: String {
        switch self {
        case .fill: return "Fill"
        case .fit: return "Fit"
        case .stretch: return "Stretch"
        case .center: return "Center"
        case .smart: return "Smart"
        }
    }

    /// One-line explanation shown under the picker. Every mode carries one, and
    /// each is short enough to stay on a single line at the settings window's
    /// width, so the pane is exactly as tall whichever mode is selected.
    var summary: String {
        switch self {
        case .fill:
            return "Covers the screen, cropping from the center whatever doesn't fit."
        case .fit:
            return "Shows the whole image, with bars where its shape doesn't match."
        case .stretch:
            return "Stretches the image to the screen, distorting it if the shapes differ."
        case .center:
            return "Places the image at its own size, without scaling it."
        case .smart:
            // Deliberately parallel to Fill, since the contrast between them is
            // the whole point of the mode.
            return "Covers the screen, cropping around the subject instead of the center."
        }
    }

    var imageScaling: NSImageScaling {
        switch self {
        case .fill, .fit, .smart: return .scaleProportionallyUpOrDown
        case .stretch: return .scaleAxesIndependently
        case .center: return .scaleNone
        }
    }

    var allowsClipping: Bool { self == .fill || self == .smart }

    var contentsGravity: CALayerContentsGravity {
        switch self {
        case .fill, .smart: return .resizeAspectFill
        case .fit: return .resizeAspect
        case .stretch: return .resize
        case .center: return .center
        }
    }

    /// Smart is Fill with the crop decided by us rather than by macOS: we
    /// pre-crop the image to the display's aspect ratio around its subject, so
    /// by the time macOS scales it there is nothing left to clip. The scaling
    /// options above still mirror Fill, since a skipped pre-crop (the image
    /// already fits, nothing was detected, or the user is not on Pro) has to
    /// degrade to plain Fill.
    var preCropsToDisplay: Bool { self == .smart }

    /// Pro-only, like upscaling. Gated at use-time on `hasProAccess` rather
    /// than hidden, so picking it prompts for a key instead of the mode
    /// quietly not being there.
    var requiresPro: Bool { self == .smart }
}
