import Foundation

/// 规则匹配类型，取自四个参照软件包内 `default.conf` 的 `[Rule]` 段字面量。
enum RuleMatchType: String, Codable, CaseIterable {
    case domain
    case domainSuffix
    case domainKeyword
    case ipCIDR
    case ip6CIDR
    case port
    case userAgent
    case geoIP
    case final

    var displayName: String {
        switch self {
        case .domain: return "DOMAIN"
        case .domainSuffix: return "DOMAIN-SUFFIX"
        case .domainKeyword: return "DOMAIN-KEYWORD"
        case .ipCIDR: return "IP-CIDR"
        case .ip6CIDR: return "IP-CIDR6"
        case .port: return "PORT"
        case .userAgent: return "USER-AGENT"
        case .geoIP: return "GEOIP"
        case .final: return "FINAL"
        }
    }
}

enum RuleAction: String, Codable, CaseIterable {
    case direct
    case proxy
    case reject

    var displayName: String {
        switch self {
        case .direct: return "DIRECT"
        case .proxy: return "PROXY"
        case .reject: return "REJECT"
        }
    }
}

struct TrafficRule: Codable, Hashable {
    var matchType: RuleMatchType
    var pattern: String
    var action: RuleAction
    /// 动作为 PROXY 时的目标：策略组名或节点名。其余动作为 nil。
    var policy: String?
    var forceRemoteDNS: Bool
    var noResolve: Bool

    init(matchType: RuleMatchType, pattern: String, action: RuleAction,
         policy: String? = nil, forceRemoteDNS: Bool = false, noResolve: Bool = false) {
        self.matchType = matchType
        self.pattern = pattern
        self.action = action
        self.policy = policy
        self.forceRemoteDNS = forceRemoteDNS
        self.noResolve = noResolve
    }
}

/// 一次待判定的连接。域名与 IP 未必同时存在：解析前只有 host，直连 IP 只有 ip。
struct FlowRequest: Hashable {
    var host: String?
    var ip: String?
    var port: Int
    var userAgent: String?

    init(host: String? = nil, ip: String? = nil, port: Int, userAgent: String? = nil) {
        self.host = host
        self.ip = ip
        self.port = port
        self.userAgent = userAgent
    }
}

struct RuleDecision: Hashable {
    /// 命中的规则在列表里的下标，供界面回显"这条规则管住了它"。
    var ruleIndex: Int
    var action: RuleAction
    var policy: String?
    var forceRemoteDNS: Bool
    var noResolve: Bool
}
