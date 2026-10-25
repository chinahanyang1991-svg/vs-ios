import XCTest
@testable import VS

// The overview page must only repeat facts the app already owns, so the builder is tested
// on attribution (which node belongs to which subscription), ordering by refresh time and
// the two "unknown" cases (no profile, no refresh yet).
private func node(_ name: String, source: String?) -> Node {
    Node(name: name, kind: .shadowsocks, host: "\(name).example", port: 443,
         credential: nil, method: "chacha20-encrypted", parameters: [:], sourceURL: source)
}

private func subscription(_ title: String, url: String?, addedAt: Date,
                          rejected: Int = 0) -> SubscriptionMeta {
    SubscriptionMeta(id: UUID(), title: title, url: url, addedAt: addedAt, rejectedCount: rejected)
}

final class HomeSummaryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testEmptyStoreReportsNothingImported() {
        let summary = HomeSummaryBuilder.make(subscriptions: [], nodes: [],
                                              profileCount: 0, signature: nil)
        XCTAssertEqual(summary.sources, [])
        XCTAssertEqual(summary.nodeCount, 0)
        XCTAssertEqual(summary.manualNodeCount, 0)
        XCTAssertEqual(summary.profileCount, 0)
        XCTAssertNil(summary.lastRefreshAt)
        XCTAssertNil(summary.signature)
    }

    func testNodesAreAttributedToTheirSubscriptionAndManualPaste() {
        let early = now.addingTimeInterval(-3 * 86400)
        let subs = [subscription("机场甲", url: "https://a.example/sub", addedAt: early),
                    subscription("机场乙", url: "https://b.example/sub", addedAt: early)]
        let nodes = [node("a1", source: "https://a.example/sub"),
                     node("a2", source: "https://a.example/sub"),
                     node("b1", source: "https://b.example/sub"),
                     node("m1", source: nil)]
        let summary = HomeSummaryBuilder.make(subscriptions: subs, nodes: nodes,
                                             profileCount: 0, signature: nil)
        XCTAssertEqual(summary.nodeCount, 4)
        XCTAssertEqual(summary.manualNodeCount, 1, "手动粘贴的节点不能混进任何订阅的计数")
        let first = summary.sources.first { $0.title == "机场甲" }
        XCTAssertEqual(first?.nodeCount, 2)
        let second = summary.sources.first { $0.title == "机场乙" }
        XCTAssertEqual(second?.nodeCount, 1)
    }

    func testRejectedCountsFollowTheirOwnSubscription() {
        let subs = [subscription("机场甲", url: "https://a.example/sub", addedAt: now, rejected: 3),
                    subscription("机场乙", url: "https://b.example/sub", addedAt: now, rejected: 7)]
        let summary = HomeSummaryBuilder.make(subscriptions: subs, nodes: [],
                                             profileCount: 0, signature: nil)
        XCTAssertEqual(summary.sources.count, 2)
        XCTAssertEqual(summary.sources.first { $0.title == "机场甲" }?.rejectedCount, 3)
        XCTAssertEqual(summary.sources.first { $0.title == "机场乙" }?.rejectedCount, 7)
    }

    func testSourcesAreOrderedByNewestRefreshFirst() {
        let subs = [subscription("旧", url: "https://old", addedAt: now.addingTimeInterval(-2 * 86400)),
                    subscription("最新", url: "https://new", addedAt: now),
                    subscription("中", url: "https://mid", addedAt: now.addingTimeInterval(-86400))]
        let summary = HomeSummaryBuilder.make(subscriptions: subs, nodes: [],
                                             profileCount: 0, signature: nil)
        XCTAssertEqual(summary.sources.map(\.title), ["最新", "中", "旧"])
        XCTAssertEqual(summary.lastRefreshAt, now, "最近刷新时间取所有订阅里最新的那一个")
    }

    func testProfileCountAndSignatureAreCarriedThrough() throws {
        let signature = SignatureStatus(profileName: "VS Development", teamName: "VS Personal",
                                        bundleIdentifier: "com.vs.app", isDevelopment: true,
                                        deviceCount: 1, expiresAt: now.addingTimeInterval(7 * 86400),
                                        daysRemaining: 7, isExpired: false)
        let summary = HomeSummaryBuilder.make(subscriptions: [], nodes: [],
                                              profileCount: 2, signature: signature)
        XCTAssertEqual(summary.profileCount, 2)
        XCTAssertEqual(try XCTUnwrap(summary.signature).profileName, "VS Development")
    }

    func testUnreadableProfileFolderStaysUnknownInsteadOfBecomingZero() {
        let summary = HomeSummaryBuilder.make(subscriptions: [], nodes: [],
                                              profileCount: nil, signature: nil)
        XCTAssertNil(summary.profileCount, "读不到描述文件目录要写“读不到”，不能报成 0 个")
    }
}
