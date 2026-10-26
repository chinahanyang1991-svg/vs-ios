import XCTest
@testable import VS

/// W2 策略组判据。三类组的语义按参照软件用法：手选听用户的、自动选优挑最快但带迟滞、按序回退只看声明顺序。
/// 每条红用例只容许一处断言失败：取结果一律走 `XCTUnwrap`，nil 即失败并结束该条。
final class PolicyGroupTests: XCTestCase {

    // MARK: - select

    func testSelectGroupKeepsTheUserChoice() throws {
        let group = PolicyGroup(name: "出口", kind: .select, members: ["HK-1", "HK-2"], chosen: "HK-2")
        let picked = try XCTUnwrap(PolicyResolver.resolve(group, latencies: ["HK-1": 120, "HK-2": 60]))
        XCTAssertEqual(picked, "HK-2")
    }

    func testSelectGroupFallsBackToFirstMemberWhenChoiceIsGone() throws {
        let group = PolicyGroup(name: "出口", kind: .select, members: ["HK-1", "HK-2"], chosen: "已删除的节点")
        let picked = try XCTUnwrap(PolicyResolver.resolve(group, latencies: ["HK-1": 120]))
        XCTAssertEqual(picked, "HK-1")
    }

    func testSelectGroupDefaultsToFirstMemberWhenNothingChosenYet() throws {
        let group = PolicyGroup(name: "出口", kind: .select, members: ["JP-1", "HK-1"])
        let picked = try XCTUnwrap(PolicyResolver.resolve(group, latencies: ["HK-1": 30, "JP-1": 90]))
        XCTAssertEqual(picked, "JP-1")
    }

    func testSelectGroupIgnoresLatency() throws {
        let group = PolicyGroup(name: "出口", kind: .select, members: ["HK-1", "HK-2"], chosen: "HK-1")
        let picked = try XCTUnwrap(PolicyResolver.resolve(group, latencies: ["HK-1": 400, "HK-2": 10]))
        XCTAssertEqual(picked, "HK-1")
    }

    // MARK: - url-test

    func testUrlTestPicksTheFastestAvailable() throws {
        let group = PolicyGroup(name: "自动", kind: .urlTest, members: ["HK-1", "HK-2"], chosen: "HK-1", toleranceMS: 0)
        let picked = try XCTUnwrap(PolicyResolver.resolve(group, latencies: ["HK-1": 120, "HK-2": 60]))
        XCTAssertEqual(picked, "HK-2")
    }

    func testUrlTestIgnoresMembersMissingFromReadings() throws {
        let group = PolicyGroup(name: "自动", kind: .urlTest, members: ["HK-1", "HK-2"], toleranceMS: 0)
        let picked = try XCTUnwrap(PolicyResolver.resolve(group, latencies: ["HK-2": 200]))
        XCTAssertEqual(picked, "HK-2")
    }

    func testUrlTestKeepsCurrentChoiceWithinTolerance() throws {
        let group = PolicyGroup(name: "自动", kind: .urlTest, members: ["HK-1", "HK-2"],
                                chosen: "HK-1", toleranceMS: 50)
        let picked = try XCTUnwrap(PolicyResolver.resolve(group, latencies: ["HK-1": 100, "HK-2": 90]))
        XCTAssertEqual(picked, "HK-1")
    }

    func testUrlTestSwitchesWhenToleranceIsExceeded() throws {
        let group = PolicyGroup(name: "自动", kind: .urlTest, members: ["HK-1", "HK-2"],
                                chosen: "HK-1", toleranceMS: 50)
        let picked = try XCTUnwrap(PolicyResolver.resolve(group, latencies: ["HK-1": 300, "HK-2": 60]))
        XCTAssertEqual(picked, "HK-2")
    }

    func testUrlTestResolvesToNothingWhenNobodyIsAvailable() {
        let group = PolicyGroup(name: "自动", kind: .urlTest, members: ["HK-1", "HK-2"])
        XCTAssertNil(PolicyResolver.resolve(group, latencies: [:]))
    }

    // MARK: - fallback

    func testFallbackKeepsDeclaredOrderOverLatency() throws {
        let group = PolicyGroup(name: "回退", kind: .fallback, members: ["HK-1", "HK-2"])
        let picked = try XCTUnwrap(PolicyResolver.resolve(group, latencies: ["HK-1": 200, "HK-2": 50]))
        XCTAssertEqual(picked, "HK-1")
    }

    func testFallbackSkipsUnavailableMemberAndTakesNext() throws {
        let group = PolicyGroup(name: "回退", kind: .fallback, members: ["HK-1", "HK-2", "US-1"])
        let picked = try XCTUnwrap(PolicyResolver.resolve(group, latencies: ["HK-2": 80, "US-1": 10]))
        XCTAssertEqual(picked, "HK-2")
    }

    func testFallbackResolvesToNothingWhenAllMembersFail() {
        let group = PolicyGroup(name: "回退", kind: .fallback, members: ["HK-1", "HK-2"])
        XCTAssertNil(PolicyResolver.resolve(group, latencies: ["US-1": 10]))
    }

    // MARK: - 边界

    func testEmptyGroupResolvesToNothing() {
        let group = PolicyGroup(name: "空组", kind: .select, members: [])
        XCTAssertNil(PolicyResolver.resolve(group, latencies: ["HK-1": 10]))
    }

    /// 成员名指向另一个组时不递归展开——本轮只认节点名，拿不准就判"无可用出口"，不瞎猜。
    func testNestedGroupNameIsNotSilentlyResolved() {
        let group = PolicyGroup(name: "外层", kind: .select, members: ["内层组"], chosen: "内层组")
        XCTAssertNil(PolicyResolver.resolve(group, latencies: ["HK-1": 10]))
    }
}
