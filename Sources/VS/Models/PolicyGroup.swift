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

/// 把"组"折算成"这一轮该走哪个成员"。
/// 延迟读数只放"这一轮测出来可用"的成员，缺席即视为不可用或未测；
/// 键用节点名，值用毫秒；与 `ProbeCoordinator` 的 `ProbeOutcome` 之间由调用方折算。
struct PolicyResolver {
    static func resolve(_ group: PolicyGroup, latencies: [String: Int]) -> String? {
        switch group.kind {
        case .select: return selectedMember(in: group, latencies: latencies)
        case .urlTest: return fastestMember(in: group, latencies: latencies)
        case .fallback: return firstAvailableMember(in: group, latencies: latencies)
        }
    }

    /// 手选：只认用户点定的那一条，点定的成员没了（删节点/改名）才退回声明的第一条。
    /// 读数只用来判"这个成员还在不在"，快慢不参与选择——用户点谁就是谁。
    private static func selectedMember(in group: PolicyGroup, latencies: [String: Int]) -> String? {
        let candidate: String?
        if let chosen = group.chosen, group.members.contains(chosen) {
            candidate = chosen
        } else {
            candidate = group.members.first
        }
        guard let picked = candidate, latencies[picked] != nil else { return nil }
        return picked
    }

    /// 自动选优：在"有读数的成员"里取最快；当前出口仍可用时，要新出口比它快过 `toleranceMS` 才换，防读数抖动来回跳。
    private static func fastestMember(in group: PolicyGroup, latencies: [String: Int]) -> String? {
        var fastest: (name: String, ms: Int)?
        for member in group.members {
            guard let ms = latencies[member] else { continue }
            if let current = fastest, current.ms <= ms { continue }
            fastest = (member, ms)
        }
        guard let best = fastest else { return nil }
        if let chosen = group.chosen, group.members.contains(chosen), let chosenMS = latencies[chosen] {
            return best.ms < chosenMS - group.toleranceMS ? best.name : chosen
        }
        return best.name
    }

    /// 按序回退：只看声明顺序，第一个有读数的成员胜出，延迟大小不参与。
    private static func firstAvailableMember(in group: PolicyGroup, latencies: [String: Int]) -> String? {
        for member in group.members where latencies[member] != nil {
            return member
        }
        return nil
    }
}
