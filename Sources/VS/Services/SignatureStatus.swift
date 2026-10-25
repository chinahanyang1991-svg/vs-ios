import Foundation

/// Facts read out of the app's own embedded.mobileprovision, as displayed in 关于.
/// The free personal provisioning profile lapses, so the user needs to see the
/// remaining days without connecting the phone to a computer.
struct SignatureStatus: Equatable, Sendable {
    var profileName: String
    var teamName: String
    var bundleIdentifier: String
    var isDevelopment: Bool
    /// nil when the profile carries no readable device list.
    var deviceCount: Int?
    var expiresAt: Date
    /// Whole days left, clamped at 0 once the profile has lapsed.
    var daysRemaining: Int
    var isExpired: Bool
}

enum SignatureStatusReader {
    static let profileFileName = "embedded.mobileprovision"
    static let maxProfileBytes = 4 * 1024 * 1024
    static let secondsPerDay: TimeInterval = 86400

    static func parse(_ data: Data, now: Date) -> SignatureStatus? {
        nil
    }

    static func status(in bundle: Bundle = .main, now: Date = Date()) -> SignatureStatus? {
        nil
    }
}
