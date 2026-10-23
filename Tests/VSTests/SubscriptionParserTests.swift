import XCTest
@testable import VS

final class SubscriptionParserTests: XCTestCase {
    func testVLESSWithQueryParameters() throws {
        let line = "vless://12345678-1234-1234-1234-123456789012@example-hk.example.com:443?security=tls&sni=example-hk.example.com&type=ws&path=%2Fws-demo#HK%2001"
        let node = try SubscriptionParser.parseNode(from: line)
        XCTAssertEqual(node.kind, .vless)
        XCTAssertEqual(node.host, "example-hk.example.com")
        XCTAssertEqual(node.port, 443)
        XCTAssertEqual(node.credential, "12345678-1234-1234-1234-123456789012")
        XCTAssertEqual(node.name, "HK 01")
        XCTAssertTrue(node.usesTLS)
        XCTAssertEqual(node.serverName, "example-hk.example.com")
        XCTAssertEqual(node.transport, "ws")
        XCTAssertEqual(node.parameters["path"], "/ws-demo")
    }

    func testTrojanUsesPasswordAsCredential() throws {
        let node = try SubscriptionParser.parseNode(from: "trojan://secretpw@tokyo.example.com:8443?security=tls&sni=tokyo.example.com#JP")
        XCTAssertEqual(node.kind, .trojan)
        XCTAssertEqual(node.credential, "secretpw")
        XCTAssertEqual(node.port, 8443)
    }

    func testShadowsocksSIP002() throws {
        let info = "chacha20-ietf-poly1305:pass word"
        let encoded = Data(info.utf8).base64EncodedString().base64URLFromStandard()
        let line = "ss://\(encoded)@ss.example.com:8388/?plugin=obfs-local%3Bobfs%3Dhttp#SS-TW"
        let node = try SubscriptionParser.parseNode(from: line)
        XCTAssertEqual(node.kind, .shadowsocks)
        XCTAssertEqual(node.method, "chacha20-ietf-poly1305")
        XCTAssertEqual(node.credential, "pass word")
        XCTAssertEqual(node.host, "ss.example.com")
        XCTAssertEqual(node.port, 8388)
        XCTAssertEqual(node.name, "SS-TW")
        XCTAssertEqual(node.parameters["plugin"], "obfs-local;obfs=http")
    }

    func testShadowsocksLegacyWholeBase64() throws {
        let payload = "aes-256-gcm:pw123@legacy.example.com:2376"
        let encoded = Data(payload.utf8).base64EncodedString().base64URLFromStandard()
        let node = try SubscriptionParser.parseNode(from: "ss://\(encoded)#老式")
        XCTAssertEqual(node.host, "legacy.example.com")
        XCTAssertEqual(node.port, 2376)
        XCTAssertEqual(node.method, "aes-256-gcm")
        XCTAssertEqual(node.credential, "pw123")
        XCTAssertEqual(node.name, "老式")
    }

    func testVMessBase64JSON() throws {
        let json = """
        {"v":"2","ps":"US-02","add":"us.example.com","port":"443","id":"aaaa-bbbb-cccc","aid":"0","net":"ws","host":"us.example.com","path":"/x","tls":"tls"}
        """
        let encoded = Data(json.utf8).base64EncodedString().base64URLFromStandard()
        let node = try SubscriptionParser.parseNode(from: "vmess://\(encoded)")
        XCTAssertEqual(node.kind, .vmess)
        XCTAssertEqual(node.name, "US-02")
        XCTAssertEqual(node.host, "us.example.com")
        XCTAssertEqual(node.port, 443)
        XCTAssertEqual(node.credential, "aaaa-bbbb-cccc")
        XCTAssertEqual(node.transport, "ws")
        XCTAssertTrue(node.usesTLS)
    }

    func testWholeSubscriptionBase64AndRejectionCounting() {
        let body = """
        trojan://pw@a.example.com:443#A
        vless://uuid@b.example.com:443#B
        这不是链接
        """
        let packed = Data(body.utf8).base64EncodedString()
        let report = SubscriptionParser.parse(packed)
        XCTAssertEqual(report.nodes.count, 2)
        XCTAssertEqual(report.rejected.count, 1)
        XCTAssertEqual(report.nodes.map(\.name), ["A", "B"])
    }

    func testClashYAMLIsReportedNotParsed() {
        let report = SubscriptionParser.parse("proxies:\n  - name: x\n    server: y\n")
        XCTAssertTrue(report.nodes.isEmpty)
        XCTAssertEqual(report.notices.count, 1)
    }

    func testRejectedHintDoesNotLeakCredential() {
        let report = SubscriptionParser.parse("trojan://SUPERSECRETPASSWORD@bad.example.com")
        XCTAssertEqual(report.nodes.count, 0)
        let hint = report.rejected.first?.hint ?? ""
        XCTAssertFalse(hint.contains("SUPERSECRETPASSWORD"))
        XCTAssertEqual(hint, "trojan://bad.ex…")
    }

    func testIPv6LiteralAddress() throws {
        let node = try SubscriptionParser.parseNode(from: "vless://u-1@[2001:db8::1]:2083#V6")
        XCTAssertEqual(node.host, "2001:db8::1")
        XCTAssertEqual(node.port, 2083)
    }

    func testVLESSQueryAtSignDoesNotChangeTarget() throws {
        let node = try SubscriptionParser.parseNode(from: "vless://demo@public.example:443?path=/a@127.0.0.1:22#Demo")
        XCTAssertEqual(node.kind, .vless)
        XCTAssertEqual(node.host, "public.example")
        XCTAssertEqual(node.port, 443)
        XCTAssertEqual(node.credential, "demo")
        XCTAssertEqual(node.parameters["path"], "/a@127.0.0.1:22")
        XCTAssertEqual(node.name, "Demo")
    }

    func testTrojanQueryAtSignDoesNotChangeTarget() throws {
        let node = try SubscriptionParser.parseNode(from: "trojan://demo@public.example:443?path=/a@127.0.0.1:22#Demo")
        XCTAssertEqual(node.kind, .trojan)
        XCTAssertEqual(node.host, "public.example")
        XCTAssertEqual(node.port, 443)
        XCTAssertEqual(node.credential, "demo")
        XCTAssertEqual(node.parameters["path"], "/a@127.0.0.1:22")
        XCTAssertEqual(node.name, "Demo")
    }

    func testMalformedCredentialRejectionDoesNotLeakSecrets() throws {
        let lines = [
            "vless://s3cr3tCredentialWithoutAt",
            "trojan://s3cr3tCredentialWithoutAt"
        ]
        for line in lines {
            let report = SubscriptionParser.parse(line)
            XCTAssertTrue(report.nodes.isEmpty)
            XCTAssertEqual(report.rejected.count, 1)
            let rejection = try XCTUnwrap(report.rejected.first)
            XCTAssertFalse(rejection.reason.isEmpty)
            // 检查秘密前缀，避免截断后的泄漏绕过完整凭据断言。
            XCTAssertFalse(rejection.hint.contains("s3cr3t"))
            XCTAssertFalse(rejection.reason.contains("s3cr3t"))
        }
    }

    func testUnknownSchemeRejectionDoesNotLeakSecrets() throws {
        let lines = [
            "unknown://s3cr3tCredentialWithoutAt",
            "s3cr3t-private-token://demo@public.example:443"
        ]
        for line in lines {
            let report = SubscriptionParser.parse(line)
            XCTAssertTrue(report.nodes.isEmpty)
            XCTAssertEqual(report.rejected.count, 1)
            let rejection = try XCTUnwrap(report.rejected.first)
            XCTAssertFalse(rejection.reason.isEmpty)
            // 未知协议名同样是不可信输入，可能包含秘密。
            XCTAssertFalse(rejection.hint.contains("s3cr3t"))
            XCTAssertFalse(rejection.reason.contains("s3cr3t"))
        }
    }

    func testVMessRejectsPortAbove65535() {
        let payloads = [
            """
            {"v":"2","add":"public.example","port":"65536","id":"demo"}
            """,
            """
            {"v":"2","add":"public.example","port":65536,"id":"demo"}
            """
        ]
        for json in payloads {
            let encoded = Data(json.utf8).base64EncodedString().base64URLFromStandard()
            XCTAssertThrowsError(try SubscriptionParser.parseNode(from: "vmess://\(encoded)"))
        }
    }

    func testShadowsocksLegacyColonFormatRejectsPortAbove65535() {
        // 无 @ 的旧式冒号格式走独立解析分支。
        let payload = "aes-256-gcm:pw123:legacy.example.com:65536"
        let encoded = Data(payload.utf8).base64EncodedString().base64URLFromStandard()
        XCTAssertThrowsError(try SubscriptionParser.parseNode(from: "ss://\(encoded)"))
    }

    func testParsingStopsAtNodeCountCap() throws {
        let lines = (1...SubscriptionParser.maxNodeCount + 50).map {
            "trojan://pw\($0)@h\($0).example:443#n\($0)"
        }.joined(separator: "\n")
        let report = SubscriptionParser.parse(lines)
        XCTAssertEqual(report.nodes.count, SubscriptionParser.maxNodeCount,
                       "超出上限的条目不得进入内存")
        XCTAssertTrue(report.notices.contains { $0.contains("上限") },
                      "被截断必须如实提示，不能装作全量导入")
    }

}

private extension String {
    func base64URLFromStandard() -> String {
        replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }
}
