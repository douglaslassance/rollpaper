import SwiftUI

struct PurchaseView: View {
    @ObservedObject var entitlementManager: EntitlementManager
    @Environment(\.dismiss) var dismiss
    @State private var licenseKey = ""
    @State private var showAlert = false
    @State private var alertMessage = ""

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 12) {
                ProAppIcon(size: 122, showBadge: true)

                Text("Upgrade to Pro")
                    .font(.system(size: 24, weight: .bold))
            }
            .padding(.top, 40)

            Divider()
                .padding(.horizontal, 36)

            VStack(alignment: .leading, spacing: 12) {
                FeatureRow(icon: Image(systemName: "infinity"), text: "Add unlimited feeds")
                FeatureRow(icon: Image(systemName: "line.3.horizontal.decrease.circle"), text: "Filter out wallpapers you don't like")
                FeatureRow(icon: Image(systemName: "wand.and.stars"), text: "Upscale low resolution content")
                FeatureRow(icon: Image(systemName: "heart.fill"), text: "Support independent development")
            }
            .padding(.horizontal, 44)

            Divider()
                .padding(.horizontal, 36)

            VStack(spacing: 12) {
                #if APPSTORE_BUILD
                Button(action: {
                    Task {
                        do {
                            try await entitlementManager.purchasePro()
                            dismiss()
                        } catch {
                            alertMessage = error.localizedDescription
                            showAlert = true
                        }
                    }
                }) {
                    HStack {
                        Text("Upgrade to Pro")
                            .fontWeight(.semibold)
                        Spacer()
                        Text("$4.99")
                            .fontWeight(.bold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)
                .disabled(entitlementManager.isLoading)

                Button("Restore Purchases") {
                    Task {
                        await entitlementManager.restorePurchases()
                        if entitlementManager.hasProAccess {
                            dismiss()
                        } else {
                            alertMessage = "No previous purchases found"
                            showAlert = true
                        }
                    }
                }
                .disabled(entitlementManager.isLoading)
                #else
                VStack(alignment: .leading, spacing: 8) {
                    Text("Enter your license key:")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    TextField("XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX", text: $licenseKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textCase(.uppercase)

                    Button("Activate License") {
                        Task {
                            if await entitlementManager.activateLicenseKey(licenseKey) {
                                dismiss()
                            } else {
                                alertMessage = entitlementManager.errorMessage ?? "Invalid license key"
                                showAlert = true
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .disabled(licenseKey.isEmpty)
                }

                Link("Purchase a license key", destination: URL(string: "https://douglaslassance.gumroad.com/l/rollpaper")!)
                    .font(.subheadline)
                    .foregroundColor(.accentColor)
                #endif
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 36)
        }
        .frame(width: 420)
        .alert("Notice", isPresented: $showAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
    }
}

private struct FeatureRow: View {
    let icon: Image
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            icon
                .font(.body)
                .foregroundColor(.accentColor)
                .frame(width: 20)

            Text(text)
                .font(.body)

            Spacer()
        }
    }
}
