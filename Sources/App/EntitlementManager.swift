import Foundation
import StoreKit

/// Manages user entitlements across both App Store (StoreKit) and Homebrew (license keys)
@MainActor
class EntitlementManager: ObservableObject {
    @Published var hasProAccess: Bool = false
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    static let shared = EntitlementManager()

    private let licenseKeyKey = "proLicenseKey"
    private let proProductID = "me.douglaslassance.Rollpaper.pro"
    private let gumroadProductID = "rollpaper-pro"

    private init() {
        checkEntitlementsSync()

        Task {
            await checkEntitlements()
        }
    }

    // MARK: - License Storage

    /// In DEBUG builds, use UserDefaults to avoid keychain prompts on every rebuild.
    private func loadStoredLicenseKey() -> String? {
        #if DEBUG
        return UserDefaults.standard.string(forKey: licenseKeyKey)
        #else
        return KeychainHelper.loadString(forKey: licenseKeyKey)
        #endif
    }

    @discardableResult
    private func saveStoredLicenseKey(_ key: String) -> Bool {
        #if DEBUG
        UserDefaults.standard.set(key, forKey: licenseKeyKey)
        return true
        #else
        return KeychainHelper.saveString(key, forKey: licenseKeyKey)
        #endif
    }

    private func deleteStoredLicenseKey() {
        #if DEBUG
        UserDefaults.standard.removeObject(forKey: licenseKeyKey)
        #else
        _ = KeychainHelper.delete(forKey: licenseKeyKey)
        #endif
    }

    // MARK: - Entitlement Checks

    private func checkEntitlementsSync() {
        #if APPSTORE_BUILD
        hasProAccess = false
        #else
        hasProAccess = loadStoredLicenseKey() != nil
        #endif
    }

    func checkEntitlements() async {
        isLoading = true
        defer { isLoading = false }

        #if APPSTORE_BUILD
        hasProAccess = await checkStoreKitPurchase()
        #else
        guard let key = loadStoredLicenseKey() else {
            hasProAccess = false
            return
        }

        let result = await withCheckedContinuation { continuation in
            verifyWithGumroad(licenseKey: key) { continuation.resume(returning: $0) }
        }

        switch result {
        case .success:
            hasProAccess = true
        case .failure(let error):
            switch error {
            case .networkError:
                // Offline — fail open, keep existing access
                hasProAccess = true
            case .invalidKey, .invalidResponse:
                deleteStoredLicenseKey()
                hasProAccess = false
            }
        }
        #endif
    }

    private func checkStoreKitPurchase() async -> Bool {
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == proProductID {
                return true
            }
        }
        return false
    }

    // MARK: - License Activation

    func activateLicenseKey(_ key: String) async -> Bool {
        let cleanedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanedKey.isEmpty else {
            errorMessage = "Please enter a license key"
            return false
        }

        let result = await withCheckedContinuation { continuation in
            verifyWithGumroad(licenseKey: cleanedKey) { result in
                continuation.resume(returning: result)
            }
        }

        switch result {
        case .success:
            let success = saveStoredLicenseKey(cleanedKey)
            if success {
                hasProAccess = true
                errorMessage = nil
                return true
            } else {
                errorMessage = "Failed to save license key securely"
                return false
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
            return false
        }
    }

    private nonisolated func verifyWithGumroad(licenseKey: String, completion: @escaping @Sendable (Result<Void, LicenseError>) -> Void) {
        guard let url = URL(string: "https://api.gumroad.com/v2/licenses/verify") else {
            completion(.failure(.networkError))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let productID = self.gumroadProductID
        let body = "product_id=\(productID)&license_key=\(licenseKey)"
        request.httpBody = body.data(using: .utf8)

        URLSession.shared.dataTask(with: request) { data, _, error in
            if error != nil {
                completion(.failure(.networkError))
                return
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure(.invalidResponse))
                return
            }

            let success = json["success"] as? Bool ?? false

            if success {
                completion(.success(()))
            } else {
                let message = json["message"] as? String ?? "Invalid license key"
                completion(.failure(.invalidKey(message)))
            }
        }.resume()
    }

    // MARK: - Debug/Testing Helpers

    #if DEBUG
    func toggleProForTesting() {
        hasProAccess.toggle()
        if hasProAccess {
            saveStoredLicenseKey("DEBUG-TEST-KEY")
        } else {
            deleteStoredLicenseKey()
        }
    }

    func resetForTesting() {
        hasProAccess = false
        deleteStoredLicenseKey()
        errorMessage = nil
    }

    var isUsingTestLicense: Bool {
        return loadStoredLicenseKey() == "DEBUG-TEST-KEY"
    }

    var hasRealLicenseKey: Bool {
        let key = loadStoredLicenseKey()
        return key != nil && key != "DEBUG-TEST-KEY"
    }
    #endif

    #if APPSTORE_BUILD
    func purchasePro() async throws {
        isLoading = true
        defer { isLoading = false }

        let products = try await Product.products(for: [proProductID])
        guard let product = products.first else {
            throw PurchaseError.productNotFound
        }

        let result = try await product.purchase()

        switch result {
        case .success(let verification):
            switch verification {
            case .verified(let transaction):
                hasProAccess = true
                await transaction.finish()
            case .unverified(_, let error):
                throw PurchaseError.verificationFailed(error)
            }
        case .userCancelled:
            throw PurchaseError.cancelled
        case .pending:
            throw PurchaseError.pending
        @unknown default:
            throw PurchaseError.unknown
        }
    }

    func restorePurchases() async {
        isLoading = true
        defer { isLoading = false }

        do {
            try await AppStore.sync()
            await checkEntitlements()
        } catch {
            errorMessage = "Failed to restore purchases: \(error.localizedDescription)"
        }
    }
    #endif
}

enum LicenseError: LocalizedError {
    case networkError
    case invalidResponse
    case invalidKey(String)

    var errorDescription: String? {
        switch self {
        case .networkError:
            return "Could not connect to the license server. Please check your internet connection."
        case .invalidResponse:
            return "Unexpected response from the license server."
        case .invalidKey(let message):
            return message
        }
    }
}

enum PurchaseError: LocalizedError {
    case productNotFound
    case cancelled
    case pending
    case verificationFailed(Error)
    case unknown

    var errorDescription: String? {
        switch self {
        case .productNotFound: return "Product not found"
        case .cancelled: return "Purchase cancelled"
        case .pending: return "Purchase is pending approval"
        case .verificationFailed(let error): return "Verification failed: \(error.localizedDescription)"
        case .unknown: return "Unknown error occurred"
        }
    }
}

/// Free vs Pro feature gates.
enum AppLimits {
    static let freeMaxFeeds = 2
    static let proMaxFeeds = Int.max

    static func maxFeeds(isPro: Bool) -> Int {
        return isPro ? proMaxFeeds : freeMaxFeeds
    }
}
