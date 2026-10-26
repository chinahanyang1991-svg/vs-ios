import Foundation
import Observation

/// 整轮测速的归属：视图只留入口，「一次只许一轮」的门禁与结果都在这里。
@Observable
final class ProbeCoordinator {
    private(set) var isRunning = false
    private(set) var outcomes: [String: ProbeOutcome] = [:]

    private let prober: (Node) async -> ProbeOutcome

    init(prober: @escaping (Node) async -> ProbeOutcome = { await NodeProber().probe($0) }) {
        self.prober = prober
    }

    /// 一次只许一轮：还在飞行中时，第二次发起（下拉刷新撞上来那一下）直接返回，不留任何探测。
    func run(nodes: [Node]) async {
        guard !isRunning else { return }
        isRunning = true
        for node in nodes {
            outcomes[node.id] = await prober(node)
        }
        isRunning = false
    }

    /// 节点被删除或改了地址后，旧一轮的结果不得再挂到它身上。
    func forgetOutcome(for id: String) {
        outcomes[id] = nil
    }
}
