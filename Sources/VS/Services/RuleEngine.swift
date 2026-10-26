import Foundation

struct RuleEngine {
    var rules: [TrafficRule]

    init(rules: [TrafficRule] = []) {
        self.rules = rules
    }

    /// 需要 GeoIP 库才能判定的规则条数。库里没有随包发布，这些规则不参与匹配。
    var geoIPRuleCount: Int {
        rules.filter { $0.matchType == .geoIP }.count
    }

    /// W1 红轮占位：复刻现状——软件里没有任何分流判定，所有连接一律走默认路线。
    func decide(_ request: FlowRequest) -> RuleDecision? {
        nil
    }
}
