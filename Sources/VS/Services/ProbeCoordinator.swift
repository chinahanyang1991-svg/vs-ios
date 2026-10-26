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

    /// R17 占位：复现现状——没有任何门禁，撞进来的第二次调用会照样再跑一整轮。
    func run(nodes: [Node]) async {
        isRunning = true
        for node in nodes {
            outcomes[node.id] = await prober(node)
        }
        isRunning = false
    }
}
