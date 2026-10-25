import XCTest
@testable import VS

final class IKEv2ProfileBuilderTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporaryDirectory)
    }

    private func makeStore() -> ConfigStore {
        ConfigStore(storeURL: temporaryDirectory.appendingPathComponent("vs-config.json"))
    }

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

    func testInvalidInputsAreRejected() throws {
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
        let store = makeStore()
        var s = eapSettings()
        s.name = "VSTest-\(UUID().uuidString.prefix(8))"
        let url = try store.exportProfile(s)
        let names = try store.exportedProfiles().map(\.lastPathComponent)
        XCTAssertTrue(names.contains(url.lastPathComponent))
        let contents = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertTrue(contents.contains("IKEv2"))

        XCTAssertThrowsError(try store.deleteExportedProfile(URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(url.lastPathComponent)))
        XCTAssertTrue(try store.exportedProfiles().map(\.lastPathComponent).contains(url.lastPathComponent),
                      "目录外的同名文件不应被删掉")
        try store.deleteExportedProfile(url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(try store.exportedProfiles().isEmpty)
    }

    func testHiddenProfileIsStillListed() throws {
        let store = makeStore()
        var settings = eapSettings()
        settings.name = ".VSTest-\(UUID().uuidString)"
        let url = try store.exportProfile(settings)
        XCTAssertTrue(try store.exportedProfiles().contains(url), "旧版隐藏文件也必须可见、可删除")
        try store.deleteExportedProfile(url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testFailedDeleteDoesNotReportSuccess() throws {
        let store = makeStore()
        var settings = eapSettings()
        settings.name = "VSTest-\(UUID().uuidString)"
        let url = try store.exportProfile(settings)
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try store.deleteExportedProfile(url))
        XCTAssertFalse(store.lastStatus.hasPrefix("已删除"))
    }

    @MainActor
    func testClearingDiscardsInFlightSubscription() async throws {
        let store = makeStore()
        let url = try XCTUnwrap(URL(string: "https://subscription.example/test"))
        let started = expectation(description: "订阅请求已挂起")
        var response: CheckedContinuation<String, Error>?
        let request = Task { @MainActor in
            try await store.fetchSubscription(url: url, title: "测试", fetch: { _ in
                try await withCheckedThrowingContinuation { continuation in
                    response = continuation
                    started.fulfill()
                }
            })
        }
        await fulfillment(of: [started], timeout: 3)
        try store.removeAll()
        response?.resume(returning: "trojan://fake@public.example:443#Test")
        do {
            _ = try await request.value
            XCTFail("清空之前发出的订阅请求不应再提交")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(store.nodes.isEmpty)
        XCTAssertTrue(store.subscriptions.isEmpty)
        XCTAssertTrue(makeStore().nodes.isEmpty)
    }

    @MainActor
    func testSubscriptionAfterClearCanStillImport() async throws {
        let store = makeStore()
        try store.removeAll()
        let url = try XCTUnwrap(URL(string: "https://subscription.example/test"))
        let report = try await store.fetchSubscription(url: url, title: "测试", fetch: { _ in
            "trojan://fake@public.example:443#Test"
        })
        XCTAssertEqual(report.nodes.count, 1)
        XCTAssertEqual(store.nodes.first?.host, "public.example")
        XCTAssertEqual(makeStore().nodes.count, 1)
    }

    // MARK: - 秘密原样

    func testEmbeddedSecretsKeepSurroundingSpaces() throws {
        var s = eapSettings()
        s.embedSecrets = true
        s.password = "  p@ss word  "
        let ikev2 = try XCTUnwrap(IKEv2ProfileBuilder.vpnPayload(s)["IKEv2"] as? [String: Any])
        XCTAssertEqual(ikev2["AuthPassword"] as? String, "  p@ss word  ",
                       "首尾空格是合法密码字符，裁掉就会连不上")

        var psk = IKEv2TunnelSettings()
        psk.serverHost = "192.0.2.10"
        psk.authMode = .psk
        psk.embedSecrets = true
        psk.sharedSecret = " pad1ng "
        let secret = try XCTUnwrap(IKEv2ProfileBuilder.vpnPayload(psk)["IKEv2"] as? [String: Any])
        XCTAssertEqual(secret["SharedSecret"] as? String, " pad1ng ")

        var blank = psk
        blank.sharedSecret = "   "
        XCTAssertThrowsError(try IKEv2ProfileBuilder.vpnPayload(blank)) { error in
            XCTAssertEqual(error as? IKEv2ProfileError, .missingSecret(.psk))
        }
    }

    // MARK: - 刷新语义

    @MainActor
    func testRefreshingSameSubscriptionReplacesOnlyItsNodes() async throws {
        let store = makeStore()
        let feed = try XCTUnwrap(URL(string: "https://feed.example/suba"))
        _ = try await store.fetchSubscription(url: feed, title: "A") { _ in
            "trojan://p1@one.example:443#one\ntrojan://p2@two.example:443#two"
        }
        _ = try store.importNodes(from: "trojan://manual@other.example:443#manual", title: "手动")
        XCTAssertEqual(store.nodes.count, 3)

        _ = try await store.fetchSubscription(url: feed, title: "A") { _ in
            "trojan://p1@one.example:443#one\ntrojan://p3@three.example:443#three"
        }
        XCTAssertEqual(store.nodes.map(\.host).sorted(),
                       ["one.example", "other.example", "three.example"],
                       "服务端删掉的节点要随刷新消失，其他来源要保留")
        XCTAssertEqual(store.subscriptions.count, 1, "同一订阅地址应归并为一条记录")
        XCTAssertEqual(makeStore().nodes.map(\.host).sorted(),
                       ["one.example", "other.example", "three.example"])
    }

    // MARK: - 落盘内容与失败传播

    func testPersistedFileNeverContainsRawLinks() throws {
        let url = temporaryDirectory.appendingPathComponent("vs-config.json")
        let store = ConfigStore(storeURL: url)
        _ = try store.importNodes(from: "trojan://sup3rsecret@one.example:443#note", title: "t",
                                 url: "https://feed.example/suba")
        let raw = try Data(contentsOf: url)
        let json = String(decoding: raw, as: UTF8.self)
        XCTAssertFalse(json.contains("rawURL"), "整条原始链接是凭据的第二份副本，不得落盘")
        XCTAssertFalse(json.contains("trojan://sup3rsecret"))
        XCTAssertNil(raw.range(of: Data("sup3rsecret".utf8)),
                     "整份配置都要加密，凭据不能再以明文躺在落盘字节里")
    }

    func testWriteFailurePropagatesInsteadOfClaimingSuccess() throws {
        // 模拟器以 runner 普通用户运行，权限位真实生效。
        let directory = temporaryDirectory.appendingPathComponent("readonly", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ConfigStore(storeURL: directory.appendingPathComponent("vs-config.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        XCTAssertThrowsError(try store.importNodes(from: "trojan://p@one.example:443#n", title: "t"))
        XCTAssertFalse(store.lastStatus.hasPrefix("新增"), "写盘失败不能报告“新增 N 个”")
        XCTAssertTrue(store.nodes.isEmpty, "写盘失败时内存不得留下未落盘的节点，重启后不能凭空出现")
    }

    func testCorruptFileReloadDoesNotClaimBackup() throws {
        let directory = temporaryDirectory.appendingPathComponent("corrupt", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("vs-config.json")
        try Data("[1,2,3]".utf8).write(to: url)
        let store = ConfigStore(storeURL: url)
        XCTAssertTrue(store.lastStatus.contains("无法解析") || store.lastStatus.contains("无法读取"),
                      "实际读数：\(store.lastStatus)")
        XCTAssertFalse(store.lastStatus.contains("备份"), "代码里没有备份动作，就不能声称已备份")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
