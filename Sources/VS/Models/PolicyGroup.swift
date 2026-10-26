import Foundation

/// 策略组类型：手选 / 自动挑最快（带迟滞防抖）/ 按声明顺序回退。
/// 参照软件里 PROXY 动作指向的就是这种组名（见 ci-out/ref-apps/feature-surface.md）。
enum PolicyKind: String, Codable, CaseIterable {
    case select
    case urlTest
    case fallback

    var displayName: String {
        switch self {
        case .select: return "手动选择"
        case .urlTest: return "自动选优"
        case .fallback: return "按序回退"
        }
    }
}

struct PolicyGroup: Codable, Hashable, Identifiable {
    var name: String
    var kind: PolicyKind
    /// 成员按声明顺序存；引用的是节点名。
    var members: [String]
    /// select 组由用户点定；url-test 用它做防抖的"当前出口"。
    var chosen: String?
    /// 自动选优的迟滞：新出口要快过当前出口这么多毫秒才换，避免来回跳。
    var toleranceMS: Int

    var id: String { name }

    init(name: String, kind: PolicyKind, members: [String],
         chosen: String? = nil, toleranceMS: Int = 50) {
        self.name = name
        self.kind = kind
        self.members = members
        self.chosen = chosen
        self.toleranceMS = toleranceMS
    }
}

/// 延迟读数：只放"这一轮测出来可用"的成员，缺席即视为不可用或未测。
/// 键用节点名，值用毫秒；与 `ProbeCoordinator` 的 `ProbeOutcome` 之间由调用方折算。
struct PolicyResolver {
    /// W2 红轮占位：复刻现状——软件里没有策略组这层，任何组都解析不出出口。
    static func resolve(_ group: PolicyGroup, latencies: [String: Int]) -> String? {
        _ = group
        _ = latencies
        return nil
    }
}
