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
    static let maxProfileBytes = 4 * 1024 * 1024
    static let secondsPerDay: TimeInterval = 86400
    private static let minCandidateBytes = 64
    private static let maxDepth = 24

    /// Picks the profile dictionary out of the signedData envelope. Everything that is not
    /// a readable profile returns nil, so the UI can say "no signing status" out loud.
    static func parse(_ data: Data, now: Date) -> SignatureStatus? {
        for candidate in octetStrings(in: [UInt8](data)) {
            let object = try? PropertyListSerialization.propertyList(
                from: Data(candidate), options: [], format: nil)
            if let body = object as? [String: Any], let status = status(from: body, now: now) {
                return status
            }
        }
        return nil
    }

    static func status(in bundle: Bundle = .main, now: Date = Date()) -> SignatureStatus? {
        let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision")
            ?? bundle.bundleURL.appendingPathComponent("embedded.mobileprovision")
        guard let data = try? Data(contentsOf: url), data.count <= maxProfileBytes else { return nil }
        return parse(data, now: now)
    }

    private static func status(from body: [String: Any], now: Date) -> SignatureStatus? {
        guard let expiresAt = body["ExpirationDate"] as? Date else { return nil }
        let interval = expiresAt.timeIntervalSince(now)
        let isExpired = interval <= 0
        let entitlements = body["Entitlements"] as? [String: Any] ?? [:]
        var bundleIdentifier = ""
        if let appID = entitlements["application-identifier"] as? String,
           let dot = appID.firstIndex(of: ".") {
            bundleIdentifier = String(appID[appID.index(after: dot)...])
        }
        return SignatureStatus(
            profileName: body["Name"] as? String ?? "未记载",
            teamName: body["TeamName"] as? String ?? "未记载",
            bundleIdentifier: bundleIdentifier,
            isDevelopment: entitlements["get-task-allow"] as? Bool == true,
            deviceCount: (body["ProvisionedDevices"] as? [String])?.count,
            expiresAt: expiresAt,
            daysRemaining: isExpired ? 0 : Int(interval / secondsPerDay),
            isExpired: isExpired)
    }

    /// Collects definite-length OCTET STRING payloads, which is where a profile plist lives.
    /// Anything longer than the size policy is skipped, so an unbounded blob never reaches
    /// the plist decoder.
    private static func octetStrings(in bytes: [UInt8], depth: Int = 0) -> [[UInt8]] {
        guard depth < maxDepth else { return [] }
        var found: [[UInt8]] = []
        var index = 0
        while index + 2 <= bytes.count {
            let tag = bytes[index]
            let firstLengthByte = bytes[index + 1]
            let length: Int
            let start: Int
            if firstLengthByte < 0x80 {
                length = Int(firstLengthByte)
                start = index + 2
            } else {
                let byteCount = Int(firstLengthByte & 0x7F)
                guard byteCount > 0, byteCount <= 4, index + 2 + byteCount <= bytes.count else { break }
                var value = 0
                for offset in 0..<byteCount {
                    value = (value << 8) | Int(bytes[index + 2 + offset])
                }
                length = value
                start = index + 2 + byteCount
            }
            let end = start + length
            guard end <= bytes.count else { break }
            if tag == 0x04 {
                if length >= minCandidateBytes, length <= maxProfileBytes {
                    found.append(Array(bytes[start..<end]))
                }
            } else if tag & 0x20 != 0 {
                found.append(contentsOf: octetStrings(in: Array(bytes[start..<end]), depth: depth + 1))
            }
            index = end
        }
        return found
    }
}
