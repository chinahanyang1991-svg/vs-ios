import XCTest
@testable import VS

/// W1 分流规则引擎判据。匹配类型与动作取自四个参照软件包内 `default.conf` 的 `[Rule]` 段。
/// 每条红用例只容许一处断言失败：取判定一律走 `XCTUnwrap`，nil 即失败并结束该条。
final class TrafficRuleEngineTests: XCTestCase {

    // MARK: - DOMAIN

    func testDomainRuleMatchesTheExactHostOnly() throws {
        let engine = RuleEngine(rules: [
            TrafficRule(matchType: .domain, pattern: "example.com", action: .proxy, policy: "自动选择"),
        ])
        let decision = try XCTUnwrap(engine.decide(FlowRequest(host: "example.com", port: 443)))
        XCTAssertEqual(decision.action, .proxy)
        XCTAssertEqual(decision.policy, "自动选择")
    }

    func testDomainRuleIsCaseInsensitive() throws {
        let engine = RuleEngine(rules: [
            TrafficRule(matchType: .domain, pattern: "Example.COM", action: .direct),
        ])
        _ = try XCTUnwrap(engine.decide(FlowRequest(host: "example.com", port: 80)))
    }

    // MARK: - DOMAIN-SUFFIX

    func testDomainSuffixRuleMatchesTheBareDomainAndSubdomains() throws {
        let engine = RuleEngine(rules: [
            TrafficRule(matchType: .domainSuffix, pattern: "example.com", action: .direct),
        ])
        let bare = try XCTUnwrap(engine.decide(FlowRequest(host: "example.com", port: 443)))
        XCTAssertEqual(bare.action, .direct)
    }

    func testDomainSuffixRuleDoesNotMatchUnrelatedDomain() throws {
        let engine = RuleEngine(rules: [
            TrafficRule(matchType: .domainSuffix, pattern: "example.com", action: .direct),
        ])
        XCTAssertNil(engine.decide(FlowRequest(host: "notexample.com", port: 443)))
        XCTAssertNil(engine.decide(FlowRequest(host: "example.net", port: 443)))
    }

    // MARK: - DOMAIN-KEYWORD

    func testDomainKeywordRuleMatchesSubstringAnywhere() throws {
        let engine = RuleEngine(rules: [
            TrafficRule(matchType: .domainKeyword, pattern: "github", action: .proxy, policy: "国外"),
        ])
        let decision = try XCTUnwrap(engine.decide(FlowRequest(host: "api.github.com", port: 443)))
        XCTAssertEqual(decision.policy, "国外")
    }

    // MARK: - 首条命中即停

    func testFirstMatchedRuleWins() throws {
        let engine = RuleEngine(rules: [
            TrafficRule(matchType: .domainKeyword, pattern: "git", action: .reject),
            TrafficRule(matchType: .domainSuffix, pattern: "github.com", action: .proxy, policy: "国外"),
        ])
        let decision = try XCTUnwrap(engine.decide(FlowRequest(host: "api.github.com", port: 443)))
        XCTAssertEqual(decision.ruleIndex, 0)
        XCTAssertEqual(decision.action, .reject)
    }

    // MARK: - IP-CIDR

    func testIpCIDRRuleMatchesAddressInsideRange() throws {
        let engine = RuleEngine(rules: [
            TrafficRule(matchType: .ipCIDR, pattern: "10.0.0.0/8", action: .direct),
        ])
        let decision = try XCTUnwrap(engine.decide(FlowRequest(ip: "10.20.30.40", port: 80)))
        XCTAssertEqual(decision.action, .direct)
    }

    func testIpCIDRRuleDoesNotMatchAddressOutsideRange() throws {
        let engine = RuleEngine(rules: [
            TrafficRule(matchType: .ipCIDR, pattern: "10.0.0.0/8", action: .direct),
        ])
        XCTAssertNil(engine.decide(FlowRequest(ip: "11.0.0.1", port: 80)))
    }

    func testIpCIDRRuleMatchesExactHostWithSlash32() throws {
        let engine = RuleEngine(rules: [
            TrafficRule(matchType: .ipCIDR, pattern: "192.168.1.7/32", action: .direct),
        ])
        _ = try XCTUnwrap(engine.decide(FlowRequest(ip: "192.168.1.7", port: 53)))
    }

    func testIPv6CIDRRuleMatchesRange() throws {
        let engine = RuleEngine(rules: [
            TrafficRule(matchType: .ip6CIDR, pattern: "fd00::/8", action: .direct),
        ])
        _ = try XCTUnwrap(engine.decide(FlowRequest(ip: "fd12::1", port: 443)))
    }

    // MARK: - PORT

    func testPortRuleMatchesPortRegardlessOfHost() throws {
        let engine = RuleEngine(rules: [
            TrafficRule(matchType: .port, pattern: "443", action: .proxy, policy: "国外"),
        ])
        let decision = try XCTUnwrap(engine.decide(FlowRequest(host: "anything.test", port: 443)))
        XCTAssertEqual(decision.action, .proxy)
    }

    // MARK: - USER-AGENT

    func testUserAgentRuleMatchesWildcardPattern() throws {
        let engine = RuleEngine(rules: [
            TrafficRule(matchType: .userAgent, pattern: "*WeChat*", action: .direct),
        ])
        let decision = try XCTUnwrap(engine.decide(
            FlowRequest(host: "example.com", port: 443, userAgent: "Mozilla/5.0 WeChat/8.0")))
        XCTAssertEqual(decision.action, .direct)
    }

    func testUserAgentRuleDoesNotMatchWhenRequestHasNoUserAgent() throws {
        let engine = RuleEngine(rules: [
            TrafficRule(matchType: .userAgent, pattern: "*WeChat*", action: .direct),
        ])
        XCTAssertNil(engine.decide(FlowRequest(host: "example.com", port: 443)))
    }

    // MARK: - FINAL 与兜底

    func testFinalRuleCatchesWhatEarlierRulesMissed() throws {
        let engine = RuleEngine(rules: [
            TrafficRule(matchType: .domain, pattern: "a.test", action: .direct),
            TrafficRule(matchType: .final, pattern: "", action: .proxy, policy: "国外"),
        ])
        let decision = try XCTUnwrap(engine.decide(FlowRequest(host: "b.test", port: 443)))
        XCTAssertEqual(decision.ruleIndex, 1)
        XCTAssertEqual(decision.policy, "国外")
    }

    func testEmptyRuleListMakesNoDecision() {
        let engine = RuleEngine(rules: [])
        XCTAssertNil(engine.decide(FlowRequest(host: "example.com", port: 443)))
    }

    func testUnmatchedRequestMakesNoDecision() throws {
        let engine = RuleEngine(rules: [
            TrafficRule(matchType: .domain, pattern: "a.test", action: .direct),
        ])
        XCTAssertNil(engine.decide(FlowRequest(host: "b.test", port: 443)))
    }

    // MARK: - 标记位

    func testDecisionCarriesForceRemoteDNSAndNoResolveFlags() throws {
        let engine = RuleEngine(rules: [
            TrafficRule(matchType: .domainSuffix, pattern: "example.com", action: .proxy,
                        policy: "国外", forceRemoteDNS: true, noResolve: true),
        ])
        let decision = try XCTUnwrap(engine.decide(FlowRequest(host: "example.com", port: 443)))
        XCTAssertTrue(decision.forceRemoteDNS)
        XCTAssertTrue(decision.noResolve)
    }

    // MARK: - REJECT

    func testRejectActionNeedsNoPolicy() throws {
        let engine = RuleEngine(rules: [
            TrafficRule(matchType: .domainSuffix, pattern: "ads.example", action: .reject),
        ])
        let decision = try XCTUnwrap(engine.decide(FlowRequest(host: "x.ads.example", port: 443)))
        XCTAssertEqual(decision.action, .reject)
        XCTAssertNil(decision.policy)
    }

    // MARK: - GEOIP 缺库：跳过不猜

    func testGeoIPRuleIsSkippedBecauseTheDatabaseIsNotShipped() throws {
        let engine = RuleEngine(rules: [
            TrafficRule(matchType: .geoIP, pattern: "cn", action: .direct),
        ])
        XCTAssertEqual(engine.geoIPRuleCount, 1)
        XCTAssertNil(engine.decide(FlowRequest(ip: "1.2.3.4", port: 443)))
    }
}
