import XCTest
@testable import VS

// Fixtures are synthesized here so the reader is tested against the same envelope
// shape a signed IPA carries (a PKCS#7 signedData wrapper around a binary plist).
private func derLength(_ count: Int) -> [UInt8] {
    if count < 0x80 { return [UInt8(count)] }
    var value = count
    var raw: [UInt8] = []
    while value > 0 {
        raw.insert(UInt8(value & 0xFF), at: 0)
        value >>= 8
    }
    return [UInt8(0x80 | raw.count)] + raw
}

private func der(_ tag: UInt8, _ payload: [UInt8]) -> [UInt8] {
    [tag] + derLength(payload.count) + payload
}

private func envelope(_ content: [UInt8]) -> [UInt8] {
    let oid: [UInt8] = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x02]
    return der(0x30, der(0x06, oid) + der(0xa0, der(0x30, der(0x04, content))))
}

private func binaryPlist(_ object: Any) -> Data {
    try! PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
}

private let udid = "00008030-001430213460402E"

/// Mirrors the fields a free personal development profile carries.
private func profileBody(issuedAt: Date, ttlDays: Int, devices: Any? = [udid],
                         getTaskAllow: Bool = true, appID: String = "8A8V8S8F8A.com.vs.app") -> [String: Any] {
    var body: [String: Any] = [
        "Name": "VS Development",
        "TeamName": "VS Personal",
        "TeamIdentifier": ["8A8V8S8F8A"],
        "CreationDate": issuedAt,
        "ExpirationDate": issuedAt.addingTimeInterval(TimeInterval(ttlDays) * 86400),
        "TimeToLive": ttlDays * 24 * 60,
        "Entitlements": [
            "application-identifier": appID,
            "com.apple.developer.team-identifier": "8A8V8S8F8A",
            "get-task-allow": getTaskAllow,
        ] as [String: Any],
    ]
    if let devices { body["ProvisionedDevices"] = devices }
    return body
}

private func signedEnvelope(_ body: [String: Any]) -> Data {
    Data(envelope([UInt8](binaryPlist(body))))
}

final class SignatureStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // ---------- the gate exists at all ----------
    func testGarbageEnvelopeReportsNoSignature() {
        XCTAssertNil(SignatureStatusReader.parse(Data([UInt8](repeating: 0, count: 512)), now: now),
                     "random bytes must not be presented as a signing status")
    }

    func testProfileWithoutExpirationDateReportsNoSignature() {
        var body = profileBody(issuedAt: now, ttlDays: 7)
        body.removeValue(forKey: "ExpirationDate")
        XCTAssertNil(SignatureStatusReader.parse(signedEnvelope(body), now: now))
    }

    func testOversizedEnvelopeIsRefusedByTheSizePolicy() {
        // A valid profile padded past the size policy must be refused instead of parsed,
        // so an unbounded blob inside a package can never reach the plist decoder.
        var body = profileBody(issuedAt: now, ttlDays: 7)
        body["Pad"] = Data(repeating: 0, count: SignatureStatusReader.maxProfileBytes)
        XCTAssertNil(SignatureStatusReader.parse(signedEnvelope(body), now: now))
    }

    func testMissingProfileInBundleReportsNoSignature() {
        // The unit-test host runs an unsigned simulator build, which carries no profile:
        // the reader must report "no signing status" rather than invent one.
        XCTAssertNil(SignatureStatusReader.status(in: .main, now: now))
    }

    // ---------- the facts the UI shows ----------
    // These use `throws` + `try XCTUnwrap` on purpose: `try!` turns a missing value into a
    // crash, and a crashed host is recorded as "Executed 0 tests, with 0 failures" instead
    // of a red assertion, which would hide the failure in the aggregate counts.
    func testValidDevelopmentProfileReportsDaysAndDevices() throws {
        let status = try XCTUnwrap(
            SignatureStatusReader.parse(signedEnvelope(profileBody(issuedAt: now, ttlDays: 7)), now: now))
        XCTAssertEqual(status.profileName, "VS Development")
        XCTAssertEqual(status.teamName, "VS Personal")
        XCTAssertEqual(status.bundleIdentifier, "com.vs.app")
        XCTAssertTrue(status.isDevelopment)
        XCTAssertEqual(status.deviceCount, .some(1))
        XCTAssertEqual(status.daysRemaining, 7)
        XCTAssertFalse(status.isExpired)
        XCTAssertEqual(status.expiresAt.timeIntervalSince(now), 7 * 86400, accuracy: 1)
    }

    func testProfileExpiringWithinSixHoursIsValidWithZeroDaysLeft() throws {
        let issued = now.addingTimeInterval(-7 * 86400 + 6 * 3600)
        let status = try XCTUnwrap(
            SignatureStatusReader.parse(signedEnvelope(profileBody(issuedAt: issued, ttlDays: 7)), now: now))
        XCTAssertEqual(status.daysRemaining, 0)
        XCTAssertFalse(status.isExpired, "six hours of validity is not an expired profile")
    }

    func testLapsedProfileIsFlaggedExpired() throws {
        let issued = now.addingTimeInterval(-7 * 86400 - 3600)
        let status = try XCTUnwrap(
            SignatureStatusReader.parse(signedEnvelope(profileBody(issuedAt: issued, ttlDays: 7)), now: now))
        XCTAssertTrue(status.isExpired)
        XCTAssertEqual(status.daysRemaining, 0, "a lapsed profile must not report days left")
    }

    func testProfileWithoutDeviceListReportsUnknownDeviceCount() throws {
        let status = try XCTUnwrap(SignatureStatusReader.parse(
            signedEnvelope(profileBody(issuedAt: now, ttlDays: 30, devices: nil, getTaskAllow: false)),
            now: now))
        XCTAssertNil(status.deviceCount)
        XCTAssertFalse(status.isDevelopment)
        XCTAssertEqual(status.daysRemaining, 30)
    }
}
