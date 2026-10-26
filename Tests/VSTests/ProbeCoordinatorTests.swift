import XCTest
@testable import VS

/// R17：把「测速中不许再发起一轮」从视图里的 @State 搬进 ProbeCoordinator 的实身。
/// 判据全走可注入的 prober 闭包接缝——嵌套那一次调用就是"用户在下拉刷新上又按了一次"的等价形状，
/// 且嵌套发生在第一次探测的 await 点上（外层确实挂起），所以读数不靠调度时序。
/// 红轮写死预期：用例级 1 红（本文件第 1 条），断言级 2（第 1 条的两条断言各读一个被改的值）；
/// 其余 4 条在占位上天生绿，属反向守卫（防把门禁实现成"永久锁死"、防结果没按节点记账）。
final class ProbeCoordinatorTests: XCTestCase {

    private final class ProbeLog {
        var calls: [String] = []
        var runningWhileInFlight: [Bool] = []
        var runningAfterNestedLaunch: Bool?
        /// 嵌套只许发生一次：不限次数的话，占位实现（无门禁）会自我递归到底，
        /// 读数就变成任务堆栈耗尽而不是「第二次发起没被挡下」。
        var nestedLaunchesLeft = 1
    }

    private final class CoordinatorRef {
        var value: ProbeCoordinator?
    }

    private func makeNode(_ name: String, port: Int) -> Node {
        Node(name: name, kind: .trojan, host: "\(name).example", port: port,
             credential: "secret", method: nil, parameters: [:])
    }

    private var nodeA: Node { makeNode("甲", port: 443) }
    private var nodeB: Node { makeNode("乙", port: 8443) }

    /// 关键判据：一轮还在飞行中时，第二次发起必须一点事都不做。
    func testRefreshWhileAPassIsInFlightStartsNoSecondPass() async {
        let log = ProbeLog()
        let ref = CoordinatorRef()
        let coordinator = ProbeCoordinator { node in
            log.calls.append(node.name)
            if node.name == "甲", let running = ref.value, log.nestedLaunchesLeft > 0 {
                log.nestedLaunchesLeft -= 1
                await running.run(nodes: [node])
                log.runningAfterNestedLaunch = running.isRunning
            }
            return .tcpConnected(latencyMS: node.port)
        }
        ref.value = coordinator
        await coordinator.run(nodes: [nodeA, nodeB])

        XCTAssertEqual(log.calls, ["甲", "乙"],
                       "被挡下的那次不许留下任何探测，实测探测了 \(log.calls) 次")
        XCTAssertEqual(log.runningAfterNestedLaunch, true,
                       "嵌套那一次不许把还在飞行中的标志抹掉")
    }

    /// 反向守卫：门禁必须只在"这一轮跑完了"之后松开，不能永久锁死。
    func testCompletedPassAllowsTheNextOne() async {
        let log = ProbeLog()
        let coordinator = ProbeCoordinator { node in
            log.calls.append(node.name)
            return .tcpConnected(latencyMS: node.port)
        }
        await coordinator.run(nodes: [nodeA, nodeB])
        await coordinator.run(nodes: [nodeA, nodeB])

        XCTAssertEqual(log.calls, ["甲", "乙", "甲", "乙"], "第一轮结束后第二轮要照常发起")
        XCTAssertFalse(coordinator.isRunning, "两轮都结束后标志要落回 false")
    }

    /// 飞行中标志为真、结束后为假——按钮与下拉刷新都读这一个标志。
    func testRunningFlagIsTrueInsideAPassAndClearedAfter() async {
        let log = ProbeLog()
        let ref = CoordinatorRef()
        let coordinator = ProbeCoordinator { node in
            if let running = ref.value {
                log.runningWhileInFlight.append(running.isRunning)
            }
            return .tcpConnected(latencyMS: node.port)
        }
        ref.value = coordinator
        await coordinator.run(nodes: [nodeA, nodeB])

        XCTAssertEqual(log.runningWhileInFlight, [true, true], "探测进行中标志必须为真")
        XCTAssertFalse(coordinator.isRunning, "整轮结束后标志必须落回 false")
    }

    /// 结果按节点 id 记账，一个节点都不许漏。
    func testOutcomesAreRecordedPerNodeID() async {
        let coordinator = ProbeCoordinator { node in
            .tcpConnected(latencyMS: node.port)
        }
        await coordinator.run(nodes: [nodeA, nodeB])

        XCTAssertEqual(coordinator.outcomes.keys.sorted(), [nodeA.id, nodeB.id].sorted())
        XCTAssertEqual(coordinator.outcomes[nodeA.id], .tcpConnected(latencyMS: 443))
        XCTAssertEqual(coordinator.outcomes[nodeB.id], .tcpConnected(latencyMS: 8443))
    }

    /// 空列表那一轮不许把标志留在 true，否则之后再也发不起测速。
    func testEmptyPassLeavesCoordinatorReadyForTheNextOne() async {
        let log = ProbeLog()
        let coordinator = ProbeCoordinator { node in
            log.calls.append(node.name)
            return .tcpConnected(latencyMS: node.port)
        }
        await coordinator.run(nodes: [])
        XCTAssertFalse(coordinator.isRunning, "空列表这一轮结束后标志要落回 false")

        await coordinator.run(nodes: [nodeA])
        XCTAssertEqual(log.calls, ["甲"], "空列表之后仍要能发起真探测")
    }
}
