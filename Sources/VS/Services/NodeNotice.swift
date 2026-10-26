import Foundation
import Observation

/// 节点页失败横幅的归属。R18 红轮：这份占位就是**现状的形状**——只会挂上去，谁都撤不下来。
@Observable
final class NodeNotice {
    private(set) var message: String?

    func raise(_ text: String) {
        message = text
    }

    func clear() {}

    func beginOperation() {}
}
