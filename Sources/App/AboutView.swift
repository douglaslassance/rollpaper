import AppKit
import SwiftUI

struct AboutView: View {
    @EnvironmentObject var entitlementManager: EntitlementManager

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 162, height: 162)
                    .offset(y: -2)
                    .overlay(alignment: .bottom) {
                        if entitlementManager.hasProAccess {
                            Text("Pro")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.accentColor)
                                .cornerRadius(4)
                                .offset(y: -8)
                        }
                    }

                VStack(spacing: 4) {
                    Text(entitlementManager.hasProAccess ? "Rollpaper Pro" : "Rollpaper")
                        .font(.system(size: 24, weight: .bold))

                    Text("Version \(currentVersion)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }

            Button(action: {
                NSWorkspace.shared.open(URL(string: "https://douglaslassance.me/contact")!)
            }) {
                Label("Contact", systemImage: "envelope")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            Spacer()

            HStack(spacing: 4) {
                Text("©")
                    .foregroundColor(.secondary)
                Text("2026")
                    .foregroundColor(.secondary)
                Button(action: {
                    if let url = URL(string: "https://douglaslassance.me") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Text("Douglas Lassance")
                        .underline()
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                .onHover { hovering in
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
            }
            .font(.caption)
            .padding(.bottom, 8)
        }
        .padding(30)
        .frame(width: 320, height: 340)
    }
}
