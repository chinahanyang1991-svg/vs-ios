import XCTest
@testable import VS

final class IKEv2ProfileBuilderTests: XCTestCase {
    private func eapSettings() -> IKEv2TunnelSettings {
        var s = IKEv2TunnelSettings()
        s.name = "HK-IKEv2"
        s.serverHost = "VPN.Example.COM"
        s.authMode = .eap
        s.username = "alice"
        s.password = "p@ss word"
        s.dnsInput = "1.1.1.1, 8.8.8.8"
        s.serverCommonName = "Example VPN CA"
        return s
    }

    func testEAPPayloadMatchesDocumentedKeys() throws {
        let payload = try IKEv2ProfileBuilder.vpnPayload(eapSettings())
        XCTAssertEqual(payload["PayloadType"] as? String, "com.apple.vpn.managed")
        XCTAssertEqual(payload["PayloadVersion"] as? Int, 1)
        XCTAssertEqual(payload["VPNType"] as? String, "IKEv2")
        XCTAssertEqual(payload["UserDefinedName"] as? String, "HK-IKEv2")

        guard let ikev2 = payload["IKEv2"] as? [String: Any] else {
            return XCTFail("缺少 IKEv2 字典")
        }
        XCTAssertEqual(ikev2["RemoteAddress"] as? String, "vpn.example.com")
        XCTAssertEqual(ikev2["RemoteIdentifier"] as? String, "vpn.example.com")
        XCTAssertEqual(ikev2["LocalIdentifier"] as? String, "")
        XCTAssertEqual(ikev2["AuthenticationMethod"] as? String, "None")
        XCTAssertEqual(ikev2["ExtendedAuthEnabled"] as? Int, 1)
        XCTAssertEqual(ikev2["AuthName"] as? String, "alice")
        XCTAssertNil(ikev2["AuthPassword"], "默认不把密码写进描述文件")
        XCTAssertEqual(ikev2["DeadPeerDetectionRate"] as? String, "Medium")
        XCTAssertEqual(ikev2["ServerCertificateIssuerCommonName"] as? String, "Example VPN CA")

        guard let dns = payload["DNS"] as? [String: Any],
              let addresses = dns["ServerAddresses"] as? [String] else {
            return XCTFail("缺少 DNS.ServerAddresses")
        }
        XCTAssertEqual(addresses, ["1.1.1.1", "8.8.8.8"])
    }

    func testEmbeddedPasswordOnlyWhenRequested() throws {
        var s = eapSettings()
        s.embedSecrets = true
        let payload = try IKEv2ProfileBuilder.vpnPayload(s)
        let ikev2 = payload["IKEv2"] as! [String: Any]
        XCTAssertEqual(ikev2["AuthPassword"] as? String, "p@ss word")
    }

    func testProfileWrapperAndRoundTrip() throws {
        let data = try IKEv2ProfileBuilder.mobileconfig(eapSettings())
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let profile = object as? [String: Any] else {
            return XCTFail("描述文件不是字典")
        }
        XCTAssertEqual(profile["PayloadType"] as? String, "Configuration")
        XCTAssertEqual(profile["PayloadVersion"] as? Int, 1)
        XCTAssertEqual(profile["PayloadRemovalDisallowed"] as? Bool, false)
        XCTAssertTrue((profile["PayloadIdentifier"] as? String)?.hasPrefix("com.vs.app.profile.") == true)
        guard let content = profile["PayloadContent"] as? [[String: Any]], content.count == 1 else {
            return XCTFail("PayloadContent 应只含一个 VPN payload")
        }
        XCTAssertEqual(content[0]["PayloadType"] as? String, "com.apple.vpn.managed")
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("<?xml"))
        XCTAssertFalse(text.contains("p@ss word"))
    }

    func testPSKModeWritesSharedSecretAndRejectsMissing() throws {
        var s = IKEv2TunnelSettings()
        s.serverHost = "192.0.2.10"
        s.authMode = .psk
        s.sharedSecret = "s3cr3t"
        XCTAssertThrowsError(try IKEv2ProfileBuilder.vpnPayload(s)) { error in
            XCTAssertEqual(error as? IKEv2ProfileError, .pskRequiresEmbedding)
        }
        s.embedSecrets = true
        let payload = try IKEv2ProfileBuilder.vpnPayload(s)
        let ikev2 = payload["IKEv2"] as! [String: Any]
        XCTAssertEqual(ikev2["AuthenticationMethod"] as? String, "SharedSecret")
        XCTAssertEqual(ikev2["SharedSecret"] as? String, "s3cr3t")
        XCTAssertNil(ikev2["ExtendedAuthEnabled"])
        XCTAssertEqual(ikev2["RemoteAddress"] as? String, "192.0.2.10")
    }

    func testInvalidInputsAreRejected() {
        for bad in ["", "vpn example.com", "https://vpn.example.com", "vpn.example.com:500",
                    "-vpn.example.com", "vpn..example.com", "vpn_example.com"] {
            XCTAssertNil(IKEv2ProfileBuilder.validateHost(bad), "应拒绝 \(bad)")
        }
        XCTAssertNotNil(IKEv2ProfileBuilder.validateHost("vpn.example.com"))
        XCTAssertNotNil(IKEv2ProfileBuilder.validateHost("192.0.2.10"))

        var noName = eapSettings()
        noName.name = "   "
        XCTAssertThrowsError(try IKEv2ProfileBuilder.vpnPayload(noName))

        var noUser = eapSettings()
        noUser.username = " "
        XCTAssertThrowsError(try IKEv2ProfileBuilder.vpnPayload(noUser)) { error in
            XCTAssertEqual(error as? IKEv2ProfileError, .missingSecret(.eap))
        }

        var badDNS = eapSettings()
        badDNS.dnsInput = "10.0.0.999"
        XCTAssertThrowsError(try IKEv2ProfileBuilder.vpnPayload(badDNS))

        var badCN = eapSettings()
        badCN.serverCommonName = "Example\u{0000}VPN CA"
        XCTAssertThrowsError(try IKEv2ProfileBuilder.vpnPayload(badCN))

        var spacedCN = eapSettings()
        spacedCN.serverCommonName = "  Example, Inc. VPN CA  "
        let payload = try IKEv2ProfileBuilder.vpnPayload(spacedCN)
        let ikev2 = payload["IKEv2"] as! [String: Any]
        XCTAssertEqual(ikev2["ServerCertificateIssuerCommonName"] as? String, "Example, Inc. VPN CA")
    }

    func testPersistedSettingsNeverContainSecrets() throws {
        var s = eapSettings()
        s.embedSecrets = true
        let data = try JSONEncoder().encode(s)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("p@ss word"))
        XCTAssertFalse(json.contains("password"))

        let restored = try JSONDecoder().decode(IKEv2TunnelSettings.self, from: data)
        XCTAssertEqual(restored.serverHost, "VPN.Example.COM")
        XCTAssertEqual(restored.username, "alice")
        XCTAssertEqual(restored.embedSecrets, true)
        XCTAssertEqual(restored.password, "")
    }

    func testSuggestedFileNameIsSafe() {
        var s = eapSettings()
        XCTAssertEqual(IKEv2ProfileBuilder.suggestedFileName(s), "HK-IKEv2.mobileconfig")
        s.name = "HK/01 节点"
        XCTAssertEqual(IKEv2ProfileBuilder.suggestedFileName(s), "HK01-节点.mobileconfig")
        s.name = ""
        XCTAssertEqual(IKEv2ProfileBuilder.suggestedFileName(s), "VS-IKEv2.mobileconfig")
    }

    func testExportedProfileIsListedAndCleanedUp() throws {
        let store = ConfigStore()
        var s = eapSettings()
        s.name = "VSTest-\(UUID().uuidString.prefix(8))"
        let url = try store.exportProfile(s)
        defer { store.deleteExportedProfile(url) }

        let names = store.exportedProfiles().map(\.lastPathComponent)
        XCTAssertTrue(names.contains(url.lastPathComponent))
        let contents = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertTrue(contents.contains("IKEv2"))

        store.deleteExportedProfile(URL(fileURLWithPath: NSTemporaryDirectory())
                                        .appendingPathComponent(url.lastPathComponent))
        XCTAssertTrue(store.exportedProfiles().map(\.lastPathComponent).contains(url.lastPathComponent),
                      "目录外的同名文件不应被删掉")
    }
}
