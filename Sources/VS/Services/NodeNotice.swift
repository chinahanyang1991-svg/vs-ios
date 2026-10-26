import Foundation
import Observation

/// 节点页失败横幅的归属：一次只挂一条，且新一轮操作开始时旧的一条必须撤下。
@Observable
final class NodeNotice {
    private(set) var message: String?

    func raise(_ text: String) {
        message = text
    }

    func clear() {
        message = nil
    }

    func beginOperation() {
        clear()
    }
}
