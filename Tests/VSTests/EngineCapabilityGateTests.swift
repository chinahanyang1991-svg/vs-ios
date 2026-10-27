import XCTest
@testable import VS

/// W4 兼容闸门：内核承载不了的协议，必须先表态、再出声，禁止静默当成可用出口。
/// 口径取自 2026-10-27 外部包评审——那边的问题是在生成配置时把不支持的协议
/// 悄悄降级成直连，"用户以为走代理、实际明文直连"；我们这一层的对应做法是
/// 协议枚举止步于"表态过能不能承载"，且入库的每一类都在结果里如实说明。
/// 判据一律用可选比较，不用 XCTUnwrap 中断，保证每条断言各自记账。
final class EngineCapabilityGateTests: XCTestCase {

    // MARK: - 表态：每一枚协议都要有明确答案

    func testEveryProtocolKindDeclaresItIsNotCarriedYet() {
        // 当前原生路线只生成 IKEv2 描述文件，四类分享协议没有一种经过真机承载验证。
        // 新增协议若在承载表里没表态，编译不过；表了"能承载"却没实测，这条红。
        for kind in NodeKind.allCases {
            XCTAssertFalse(kind.isCarriableByCurrentEngine,
                           "\(kind.displayName) 未经真机承载验证，不得声称当前内核能跑它")
        }
    }

    // MARK: - 出声：入库的每一类非承载协议都要被说明

    func testUncarriableNodesInReportAreAnnouncedByKind() {
        let report = SubscriptionParser.parse(
            "trojan://pw1@one.example:443#甲\nss://YWVzLTI1Ni1nY206cHcy@two.example:8388#乙")
        XCTAssertEqual(report.nodes.count, 2, "夹具前提：两条都要真的入库")
        XCTAssertTrue(report.notices.contains { $0.contains("Trojan") && $0.contains("IKEv2") },
                      "入库了承载不了的类别却不说明，等于让用户以为在走代理，实测 notices=\(report.notices)")
        XCTAssertTrue(report.notices.contains { $0.contains("Shadowsocks") && $0.contains("IKEv2") },
                      "每一类都要各自点名，实测 notices=\(report.notices)")
    }

    func testTheAnnouncementDoesNotEchoTheCredential() {
        let report = SubscriptionParser.parse("trojan://SUPERSECRETPASSWORD@one.example:443#甲")
        XCTAssertTrue(report.notices.contains { $0.contains("IKEv2") },
                      "出声是闸门本体，这条为下面那条断言提供正向对照")
        XCTAssertFalse(report.notices.contains { $0.contains("SUPERSECRETPASSWORD") },
                       "说明文案里不得回显节点凭据，实测 notices=\(report.notices)")
    }

    // MARK: - 反向守卫：没有入库节点时不许瞎出声

    func testNoCarriageWarningWhenNothingWasParsed() {
        let report = SubscriptionParser.parse("hysteria2://tok@hy.example:443#丙")
        XCTAssertTrue(report.nodes.isEmpty, "夹具前提：这条链接本来就解析不进列表")
        XCTAssertFalse(report.notices.contains { $0.contains("IKEv2") },
                       "没有入库任何节点，就不该冒出承载说明，实测 notices=\(report.notices)")
    }
}
