import AppKit
import QuartzCore

enum FitMode: String, Codable, CaseIterable, Sendable {
    case fill
    case fit
    case stretch
    case center

    var displayName: String {
        switch self {
        case .fill: return "Fill"
        case .fit: return "Fit"
        case .stretch: return "Stretch"
        case .center: return "Center"
        }
    }

    var imageScaling: NSImageScaling {
        switch self {
        case .fill, .fit: return .scaleProportionallyUpOrDown
        case .stretch: return .scaleAxesIndependently
        case .center: return .scaleNone
        }
    }

    var allowsClipping: Bool { self == .fill }

    var contentsGravity: CALayerContentsGravity {
        switch self {
        case .fill: return .resizeAspectFill
        case .fit: return .resizeAspect
        case .stretch: return .resize
        case .center: return .center
        }
    }
}
