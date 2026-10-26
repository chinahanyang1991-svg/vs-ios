import XCTest
@testable import VS

/// W3 判据：`.conf` 导入导出与 `[Host]` 覆盖。
/// 语法定在 Surge 风格（参照软件通用的 `[General][Proxy Group][Rule][Host]` 四段），
/// 解释不了的行必须落到 `unparsedLines`，不允许静默丢、也不允许瞎猜。
/// 每条红用例只容许一处断言失败：取东西一律先走 `XCTUnwrap`，取不到即失败并结束该条。
final class ConfDocumentTests: XCTestCase {

    private static let sample = """
    [General]
    log-level = notify
    skip-proxy = 192.168.0.0/16, 10.0.0.0/8

    # 井号开头的整行注释
    // 双斜杠开头的整行注释

    [Proxy Group]
    手选出口 = select, HK-1, JP-1, US-1
    自动选优 = url-test, HK-1, JP-1, url=http://cp.cloudflare.com/generate_204, interval=300
    故障回退 = fallback, HK-1, JP-1, url=http://www.google.com/generate_204

    [Rule]
    DOMAIN-SUFFIX,google.com,PROXY,手选出口
    DOMAIN,ad.example.com,REJECT
    DOMAIN-KEYWORD,amazon,PROXY,自动选优
    IP-CIDR,1.2.3.0/24,DIRECT,no-resolve
    IP-CIDR6,2001:db8::/32,PROXY,自动选优,force-remote-dns
    PORT,853,REJECT   # 853 是 DoT
    GEOIP,CN,DIRECT
    USER-AGENT,*ad*,REJECT
    MATCH,PROXY,手选出口
    FINAL,DIRECT
    PROCESS,WeChat,REJECT
    USER-AGENT,Gecko, Firefox,PROXY

    [Host]
    example.com = 1.2.3.4
    cdn.example.net = 5.6.7.8

    [URL Rewrite]
    https://ads.example.com https://ok.example.com 3
    """

    private func parsed() -> ConfDocument { ConfCodec.parse(Self.sample) }

    // MARK: - [Rule]

    func testRuleSectionParsesEverySupportedLine() throws {
        let doc = parsed()
        let first = try XCTUnwrap(doc.rules.first)
        XCTAssertEqual(doc.rules.count, 10)
        XCTAssertEqual(first.matchType, .domainSuffix)
    }

    func testDomainSuffixRuleKeepsPatternActionAndGroupName() throws {
        let rule = try XCTUnwrap(parsed().rules.first { $0.matchType == .domainSuffix })
        XCTAssertEqual(rule.pattern, "google.com")
        XCTAssertEqual(rule.action, .proxy)
        XCTAssertEqual(rule.policy, "手选出口")
    }

    func testPlainDomainAndKeywordRulesMapToTheirOwnTypes() throws {
        let plain = try XCTUnwrap(parsed().rules.first { $0.matchType == .domain })
        XCTAssertEqual(plain.pattern, "ad.example.com")
        XCTAssertEqual(plain.action, .reject)
        let keyword = try XCTUnwrap(parsed().rules.first { $0.matchType == .domainKeyword })
        XCTAssertEqual(keyword.pattern, "amazon")
        XCTAssertEqual(keyword.policy, "自动选优")
    }

    func testIpCidrRuleKeepsPrefixAndNoResolveFlag() throws {
        let rule = try XCTUnwrap(parsed().rules.first { $0.matchType == .ipCIDR })
        XCTAssertEqual(rule.pattern, "1.2.3.0/24")
        XCTAssertEqual(rule.action, .direct)
        XCTAssertTrue(rule.noResolve)
        XCTAssertFalse(rule.forceRemoteDNS)
    }

    func testIp6CidrRuleIsSeparateFromIpCidr() throws {
        let rule = try XCTUnwrap(parsed().rules.first { $0.matchType == .ip6CIDR })
        XCTAssertEqual(rule.pattern, "2001:db8::/32")
        XCTAssertEqual(rule.policy, "自动选优")
        XCTAssertTrue(rule.forceRemoteDNS)
        XCTAssertFalse(rule.noResolve)
    }

    func testPortRulePatternIsThePortNumber() throws {
        let rule = try XCTUnwrap(parsed().rules.first { $0.matchType == .port })
        XCTAssertEqual(rule.pattern, "853")
        XCTAssertEqual(rule.action, .reject)
    }

    func testTrailingCommentNeverBecomesPartOfAPattern() throws {
        let rule = try XCTUnwrap(parsed().rules.first { $0.matchType == .port })
        XCTAssertFalse(rule.pattern.contains("#"))
        XCTAssertFalse(parsed().rules.contains { $0.action == .proxy && $0.policy?.contains("#") == true })
    }

    func testGeoIPRuleKeepsCountryCode() throws {
        let rule = try XCTUnwrap(parsed().rules.first { $0.matchType == .geoIP })
        XCTAssertEqual(rule.pattern, "CN")
        XCTAssertEqual(rule.action, .direct)
    }

    func testUserAgentGlobPatternIsKept() throws {
        let rule = try XCTUnwrap(parsed().rules.first { $0.matchType == .userAgent })
        XCTAssertEqual(rule.pattern, "*ad*")
        XCTAssertEqual(rule.action, .reject)
    }

    func testMatchAndFinalAliasesBothBecomeFinalRules() throws {
        let finals = parsed().rules.filter { $0.matchType == .final }
        let firstFinal = try XCTUnwrap(finals.first)
        XCTAssertEqual(finals.count, 2)
        XCTAssertEqual(firstFinal.action, .proxy)
        XCTAssertEqual(firstFinal.policy, "手选出口")
        XCTAssertEqual(finals.last?.action, .direct)
    }

    func testDirectAndRejectRulesCarryNoPolicy() throws {
        let plain = try XCTUnwrap(parsed().rules.first { $0.matchType == .domain })
        XCTAssertNil(plain.policy)
        let port = try XCTUnwrap(parsed().rules.first { $0.matchType == .port })
        XCTAssertNil(port.policy)
    }

    func testWholeLineCommentsAndBlankLinesYieldNoRules() throws {
        let doc = parsed()
        let first = try XCTUnwrap(doc.rules.first)
        XCTAssertEqual(first.pattern, "google.com")
        XCTAssertEqual(doc.rules.count, 10)
        XCTAssertFalse(doc.unparsedLines.contains { $0.hasPrefix("//") })
        XCTAssertFalse(doc.unparsedLines.contains { $0.hasPrefix("#") })
    }

    func testUnknownMatchTypeLineIsUnparsedNotGuessed() throws {
        let line = try XCTUnwrap(parsed().unparsedLines.first { $0.hasPrefix("PROCESS,") })
        XCTAssertEqual(line, "PROCESS,WeChat,REJECT")
        XCTAssertNil(parsed().rules.first { $0.pattern == "WeChat" })
    }

    func testAmbiguousUserAgentLineIsUnparsed() throws {
        let line = try XCTUnwrap(parsed().unparsedLines.first { $0.hasPrefix("USER-AGENT,Gecko") })
        XCTAssertEqual(line, "USER-AGENT,Gecko, Firefox,PROXY")
        XCTAssertEqual(parsed().rules.filter { $0.matchType == .userAgent }.count, 1)
    }

    func testUnsupportedSectionContentIsUnparsed() throws {
        let line = try XCTUnwrap(parsed().unparsedLines.first { $0.hasPrefix("https://ads.example.com") })
        XCTAssertTrue(line.contains("https://ok.example.com"))
    }

    // MARK: - [Proxy Group]

    func testProxyGroupSelectKeepsMembersInOrder() throws {
        let group = try XCTUnwrap(parsed().groups.first { $0.name == "手选出口" })
        XCTAssertEqual(group.kind, .select)
        XCTAssertEqual(group.members, ["HK-1", "JP-1", "US-1"])
    }

    func testUrlTestAndFallbackGroupsGetTheirKinds() throws {
        let auto = try XCTUnwrap(parsed().groups.first { $0.kind == .urlTest })
        XCTAssertEqual(auto.name, "自动选优")
        XCTAssertEqual(parsed().groups.filter { $0.kind == .fallback }.count, 1)
        XCTAssertEqual(parsed().groups.count, 3)
    }

    func testGroupParametersAreNotTreatedAsMembers() throws {
        let auto = try XCTUnwrap(parsed().groups.first { $0.kind == .urlTest })
        XCTAssertEqual(auto.members, ["HK-1", "JP-1"])
    }

    // MARK: - [General] 与 [Host]

    func testGeneralSectionKeyValuesAreCollected() throws {
        let level = try XCTUnwrap(parsed().general["log-level"])
        XCTAssertEqual(level, "notify")
        XCTAssertEqual(parsed().general["skip-proxy"], "192.168.0.0/16, 10.0.0.0/8")
    }

    func testHostSectionMapsNameToAddress() throws {
        let address = try XCTUnwrap(parsed().hosts["example.com"])
        XCTAssertEqual(address, "1.2.3.4")
        XCTAssertEqual(parsed().hosts.count, 2)
    }

    // MARK: - 语法宽容与导出

    func testSectionHeadersAreCaseInsensitive() throws {
        let doc = ConfCodec.parse("[rule]\nDOMAIN,a.example.com,DIRECT\n[RULE]\nDOMAIN,b.example.com,REJECT\n")
        let first = try XCTUnwrap(doc.rules.first)
        XCTAssertEqual(doc.rules.count, 2)
        XCTAssertEqual(first.pattern, "a.example.com")
    }

    func testEmptyTextYieldsEmptyDocument() {
        let doc = ConfCodec.parse("")
        XCTAssertEqual(doc.rules.count, 0)
        XCTAssertEqual(doc.groups.count, 0)
        XCTAssertTrue(doc.hosts.isEmpty)
        XCTAssertTrue(doc.general.isEmpty)
        XCTAssertTrue(doc.unparsedLines.isEmpty)
    }

    func testRenderParsesBackToTheSameDocument() throws {
        let doc = parsed()
        let first = try XCTUnwrap(doc.rules.first)
        XCTAssertEqual(first.matchType, .domainSuffix)
        XCTAssertEqual(ConfCodec.parse(ConfCodec.render(doc)), doc)
    }

    func testRenderKeepsDeclaredRuleOrder() throws {
        let rendered = ConfCodec.render(parsed())
        let ruleLines = rendered.split(separator: "\n").filter { $0.hasPrefix("DOMAIN") }
        let head = try XCTUnwrap(ruleLines.first)
        XCTAssertEqual(String(head), "DOMAIN-SUFFIX,google.com,PROXY,手选出口")
    }
}
