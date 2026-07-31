import Foundation

/// Remembers and validates the Beacon license key against the license
/// Worker. Enforcement is deliberately gentle: Beacon is open source, so the
/// paid build reminds rather than locks — the $15/yr buys the signed,
/// auto-updating binary and keeps development funded.
///
/// Validation results are cached; a licensed Mac that goes offline stays
/// licensed for a 14-day grace window from its last successful check.
final class LicenseStore: ObservableObject {
    static let shared = LicenseStore()

    /// License Worker endpoint (Cloudflare Worker on the beaconmac.com zone).
    private static let endpoint = URL(
        string: "https://license.beaconmac.com/validate"
    )!

    /// Checkout / start-trial URL — same one the website's Buy buttons use.
    /// TODO(stripe): swap in the Stripe Payment Link once it's created (success
    /// URL → beaconmac.com/beacon/thanks.html?session_id={CHECKOUT_SESSION_ID}).
    /// Until then this points at the product page (a safe destination if the
    /// license gate is ever re-enabled before the link exists), NOT the defunct
    /// Lemon Squeezy checkout.
    static let checkoutURL = URL(
        string: "https://beaconmac.com/beacon/"
    )!

    enum Status: Equatable {
        case unlicensed
        case licensed
        /// Last check passed but couldn't re-verify recently (offline etc.).
        case grace(daysLeft: Int)
        /// The subscription lapsed or the key stopped validating.
        case lapsed

        /// Whether the app should be usable. Grace keeps a previously-valid
        /// license working through brief offline spells.
        var grantsAccess: Bool {
            switch self {
            case .licensed, .grace: return true
            case .unlicensed, .lapsed: return false
            }
        }
    }

    private let defaults = UserDefaults.standard
    private let keyDefault = "beacon.license.key"
    private let checkedAtDefault = "beacon.license.checkedAt"
    private let validDefault = "beacon.license.lastCheckValid"

    private let graceDays = 14
    /// Re-validate in the background at most every 3 days.
    private let revalidateInterval: TimeInterval = 3 * 86_400

    /// Published mirror of `status` so SwiftUI can gate the UI. Recomputed on
    /// activate / revalidate / remove and via `refresh()` (e.g. on panel show,
    /// which also catches a grace window that has since aged into lapsed).
    @Published private(set) var statusSnapshot: Status = .unlicensed

    private init() { statusSnapshot = status }

    var licenseKey: String? { defaults.string(forKey: keyDefault) }

    /// Master switch for the paywall. OFF during the Lemon Squeezy → Stripe
    /// migration so nobody hits a broken license gate; Beacon is free to use
    /// until the Stripe checkout + license validation is wired back up. Flip to
    /// true (and restore the checkout links) to re-enable enforcement.
    static let enforceLicensing = false

    var status: Status {
        if !Self.enforceLicensing { return .licensed }
        // Developer bypass so local dev builds aren't gated. Never set on a
        // shipped install: `defaults write com.beacon.search beacon.dev.bypass -bool YES`.
        if defaults.bool(forKey: "beacon.dev.bypass") { return .licensed }
        guard licenseKey != nil else { return .unlicensed }
        let lastValid = defaults.bool(forKey: validDefault)
        guard let checkedAt = defaults.object(forKey: checkedAtDefault) as? Date else {
            return lastValid ? .licensed : .unlicensed
        }
        if lastValid {
            let age = Date().timeIntervalSince(checkedAt)
            if age <= revalidateInterval { return .licensed }
            let daysLeft = graceDays - Int(age / 86_400)
            return daysLeft > 0 ? .grace(daysLeft: daysLeft) : .lapsed
        }
        return .lapsed
    }

    /// Recompute and publish the current status (cheap; reads UserDefaults).
    func refresh() {
        let snapshot = status
        if Thread.isMainThread {
            statusSnapshot = snapshot
        } else {
            DispatchQueue.main.async { self.statusSnapshot = snapshot }
        }
    }

    /// Validate and store a key the user just entered.
    func activate(key: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        validate(key: trimmed) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let valid) where valid:
                    self.defaults.set(trimmed, forKey: self.keyDefault)
                    self.defaults.set(Date(), forKey: self.checkedAtDefault)
                    self.defaults.set(true, forKey: self.validDefault)
                    self.refresh()
                    completion(.success(()))
                case .success:
                    completion(.failure(LicenseError.invalidKey))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }

    /// Cheap periodic re-check; called on launch. Never blocks anything —
    /// failures just eat into the grace window.
    func revalidateIfNeeded() {
        guard let key = licenseKey else { return }
        if let checkedAt = defaults.object(forKey: checkedAtDefault) as? Date,
           Date().timeIntervalSince(checkedAt) < revalidateInterval {
            return
        }
        validate(key: key) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                if case .success(let valid) = result {
                    self.defaults.set(Date(), forKey: self.checkedAtDefault)
                    self.defaults.set(valid, forKey: self.validDefault)
                    self.refresh()
                    Log.write("License revalidated: valid=\(valid)")
                }
                // Network errors: leave the stored verdict alone (grace).
            }
        }
    }

    func removeLicense() {
        defaults.removeObject(forKey: keyDefault)
        defaults.removeObject(forKey: checkedAtDefault)
        defaults.removeObject(forKey: validDefault)
        refresh()
    }

    enum LicenseError: LocalizedError {
        case invalidKey
        case network

        var errorDescription: String? {
            switch self {
            case .invalidKey:
                return "That key isn't valid (or its subscription has ended). "
                    + "Check for typos, or find your key on your receipt page."
            case .network:
                return "Couldn't reach the license server. Check your "
                    + "connection and try again."
            }
        }
    }

    private func validate(key: String,
                          completion: @escaping (Result<Bool, Error>) -> Void) {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["key": key])
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { data, response, error in
            if error != nil {
                completion(.failure(LicenseError.network))
                return
            }
            guard let data,
                  let body = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any] else {
                completion(.failure(LicenseError.network))
                return
            }
            // 404/400 mean "known answer: not valid" — not a network failure.
            let valid = body["valid"] as? Bool ?? false
            completion(.success(valid))
        }.resume()
    }
}
