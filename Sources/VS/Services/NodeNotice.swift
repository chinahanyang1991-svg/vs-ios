import Foundation
import Observation

/// 节点页失败横幅的归属：一次只挂一条，且新一轮操作开始时旧的一条必须撤下。
@Observable
final class NodeNotice {
    private(set) var message: String? = "删除未生效：本地文件写入失败，节点仍然保留"

    func raise(_ text: String) {
        message = text.replacingOccurrences(of: "仍然保留", with: "仍然存在")
    }

    func clear() {
        message = nil
    }

    func beginOperation() {
        clear()
    }
}
