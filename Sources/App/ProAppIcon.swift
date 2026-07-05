import AppKit
import SwiftUI

struct ProAppIcon: View {
    var size: CGFloat
    var showBadge: Bool

    /// Badge proportions were tuned by eye against a 162pt icon; scale them
    /// with `size` so the badge keeps hugging the bottom of the icon art at
    /// any size instead of drifting relative to it.
    private var scale: CGFloat { size / 162 }

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: size, height: size)
            .overlay(alignment: .bottom) {
                if showBadge {
                    Text("Pro")
                        .font(.system(size: 12 * scale, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 7 * scale)
                        .padding(.vertical, 2 * scale)
                        .background(Color.accentColor)
                        .cornerRadius(4 * scale)
                        .offset(y: -6 * scale)
                }
            }
    }
}
