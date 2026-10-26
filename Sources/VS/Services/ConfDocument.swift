import Foundation

/// Surge/Quantumult 风格 `.conf` 的文档模型。
/// 本轮只解释四段：`[General]`、`[Proxy Group]`、`[Rule]`、`[Host]`；
/// 其余段（`[URL Rewrite]` 等）与解释不了的行一律进 `unparsedLines` 如实记账，不静默丢也不瞎猜。
struct ConfDocument: Codable, Hashable {
    var general: [String: String]
    var groups: [PolicyGroup]
    var rules: [TrafficRule]
    /// `[Host]` 段：主机名 → 指定地址（对应参照软件的本地 DNS 覆盖）。
    var hosts: [String: String]
    /// 原文行（去掉了整行注释与空行），用于把"没吃进去的东西"摆到明面上。
    var unparsedLines: [String]

    init(general: [String: String] = [:],
         groups: [PolicyGroup] = [],
         rules: [TrafficRule] = [],
         hosts: [String: String] = [:],
         unparsedLines: [String] = []) {
        self.general = general
        self.groups = groups
        self.rules = rules
        self.hosts = hosts
        self.unparsedLines = unparsedLines
    }
}

/// `.conf` 文本 ⇄ `ConfDocument`。
enum ConfCodec {
    /// 没吃进去的原文行导出时挂在这个段名下带走——段名不解释，重读时它们照样回到 `unparsedLines`，
    /// 往返不会因为"导出把不认识的东西弄丢"而悄悄改样。
    private static let unparsedSection = "VS-Unparsed"

    static func parse(_ text: String) -> ConfDocument {
        var general: [String: String] = [:]
        var groups: [PolicyGroup] = []
        var rules: [TrafficRule] = []
        var hosts: [String: String] = [:]
        var unparsed: [String] = []
        var section = ""
        for raw in text.components(separatedBy: .newlines) {
            guard let line = meaningful(raw) else { continue }
            if let name = sectionName(of: line) {
                section = name
                continue
            }
            switch section {
            case "general":
                if let (key, value) = keyValue(line) { general[key] = value } else { unparsed.append(line) }
            case "host":
                if let (key, value) = keyValue(line) { hosts[key] = value } else { unparsed.append(line) }
            case "proxy group":
                if let group = policyGroup(from: line) { groups.append(group) } else { unparsed.append(line) }
            case "rule":
                if let rule = trafficRule(from: line) { rules.append(rule) } else { unparsed.append(line) }
            default:
                unparsed.append(line)
            }
        }
        return ConfDocument(general: general, groups: groups, rules: rules, hosts: hosts, unparsedLines: unparsed)
    }

    static func render(_ document: ConfDocument) -> String {
        var lines: [String] = []
        if !document.general.isEmpty {
            lines.append("[General]")
            for key in document.general.keys.sorted() {
                if let value = document.general[key] { lines.append("\(key) = \(value)") }
            }
        }
        if !document.groups.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append("[Proxy Group]")
            for group in document.groups {
                lines.append("\(group.name) = \(group.kind.confToken), \(group.members.joined(separator: ", "))")
            }
        }
        if !document.rules.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append("[Rule]")
            for rule in document.rules { lines.append(renderRule(rule)) }
        }
        if !document.hosts.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append("[Host]")
            for host in document.hosts.keys.sorted() {
                if let address = document.hosts[host] { lines.append("\(host) = \(address)") }
            }
        }
        if !document.unparsedLines.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append("[\(unparsedSection)]")
            lines.append(contentsOf: document.unparsedLines)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 行级拆解

    /// 空行与整行注释直接不要；其余去掉行尾注释后返回，全被注释吃掉时返回 nil。
    private static func meaningful(_ raw: String) -> String? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("//") else { return nil }
        guard let hash = line.firstIndex(of: "#") else { return line }
        let body = String(line[..<hash]).trimmingCharacters(in: .whitespaces)
        return body.isEmpty ? nil : body
    }

    /// 段名一律小写比对：`[Rule]`、`[RULE]`、`[rule]` 是同一个段。
    private static func sectionName(of line: String) -> String? {
        guard line.hasPrefix("["), line.hasSuffix("]"), line.count >= 3 else { return nil }
        let inner = line.dropFirst().dropLast()
        guard !inner.isEmpty, !inner.contains("["), !inner.contains("]") else { return nil }
        return inner.lowercased()
    }

    private static func keyValue(_ line: String) -> (String, String)? {
        guard let split = line.firstIndex(of: "=") else { return nil }
        let key = String(line[line.startIndex..<split]).trimmingCharacters(in: .whitespaces)
        let value = String(line[line.index(after: split)...]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !value.isEmpty else { return nil }
        return (key, value)
    }

    private static func fields(_ line: String) -> [String] {
        line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// 只认参照软件通用的三种写法；动作后面出现"既不是旗标、又不是 PROXY 的组名"就当没吃透，交回原文。
    private static func trafficRule(from line: String) -> TrafficRule? {
        let parts = fields(line)
        guard parts.count >= 2, let ruleType = matchType(of: parts[0]) else { return nil }
        var rest = Array(parts.dropFirst())
        if ruleType != .final {
            guard parts.count >= 3 else { return nil }
            rest = Array(parts.dropFirst(2))
        }
        guard let ruleAction = action(of: rest[0]) else { return nil }
        var policy: String?
        var forceRemoteDNS = false
        var noResolve = false
        for field in rest.dropFirst() {
            switch field.lowercased() {
            case "no-resolve": noResolve = true
            case "force-remote-dns": forceRemoteDNS = true
            default:
                guard ruleAction == .proxy, policy == nil, !field.isEmpty else { return nil }
                policy = field
            }
        }
        return TrafficRule(matchType: ruleType,
                           pattern: ruleType == .final ? "" : parts[1],
                           action: ruleAction,
                           policy: policy,
                           forceRemoteDNS: forceRemoteDNS,
                           noResolve: noResolve)
    }

    private static func matchType(of token: String) -> RuleMatchType? {
        switch token.uppercased() {
        case "DOMAIN": return .domain
        case "DOMAIN-SUFFIX": return .domainSuffix
        case "DOMAIN-KEYWORD": return .domainKeyword
        case "IP-CIDR": return .ipCIDR
        case "IP-CIDR6": return .ip6CIDR
        case "PORT": return .port
        case "USER-AGENT": return .userAgent
        case "GEOIP": return .geoIP
        case "MATCH", "FINAL": return .final
        default: return nil
        }
    }

    private static func action(of token: String) -> RuleAction? {
        switch token.uppercased() {
        case "DIRECT": return .direct
        case "PROXY": return .proxy
        case "REJECT": return .reject
        default: return nil
        }
    }

    private static func policyGroup(from line: String) -> PolicyGroup? {
        guard let split = line.firstIndex(of: "=") else { return nil }
        let name = String(line[line.startIndex..<split]).trimmingCharacters(in: .whitespaces)
        let parts = fields(String(line[line.index(after: split)...]))
        guard !name.isEmpty, parts.count >= 2, let groupKind = kind(of: parts[0]) else { return nil }
        // url=/interval=/timeout= 这类是探测参数，不是成员；本轮还不做探测，直接不收进成员表。
        let members = parts.dropFirst().filter { !$0.contains("=") }
        guard !members.isEmpty else { return nil }
        return PolicyGroup(name: name, kind: groupKind, members: Array(members))
    }

    private static func kind(of token: String) -> PolicyKind? {
        switch token.lowercased() {
        case "select": return .select
        case "url-test": return .urlTest
        case "fallback": return .fallback
        default: return nil
        }
    }

    // MARK: - 单行导出

    private static func renderRule(_ rule: TrafficRule) -> String {
        // 类型字面量一行都不能省：`MATCH`/`FINAL` 省下来，剩下第一个字段就成了动作，
        // 再读回来会被当成"没有类型的行"退到未吃透那堆里——兜底规则就这么蒸发掉。
        var parts: [String] = [rule.matchType.confToken]
        if rule.matchType != .final { parts.append(rule.pattern) }
        parts.append(rule.action.confToken)
        if let policy = rule.policy { parts.append(policy) }
        if rule.noResolve { parts.append("no-resolve") }
        if rule.forceRemoteDNS { parts.append("force-remote-dns") }
        return parts.joined(separator: ",")
    }
}

extension RuleMatchType {
    /// `.conf` 里的类型写法；`final` 导出用参照软件更常见的 `MATCH`。
    var confToken: String {
        switch self {
        case .domain: return "DOMAIN"
        case .domainSuffix: return "DOMAIN-SUFFIX"
        case .domainKeyword: return "DOMAIN-KEYWORD"
        case .ipCIDR: return "IP-CIDR"
        case .ip6CIDR: return "IP-CIDR6"
        case .port: return "PORT"
        case .userAgent: return "USER-AGENT"
        case .geoIP: return "GEOIP"
        case .final: return "MATCH"
        }
    }
}

extension RuleAction {
    var confToken: String {
        switch self {
        case .direct: return "DIRECT"
        case .proxy: return "PROXY"
        case .reject: return "REJECT"
        }
    }
}

extension PolicyKind {
    var confToken: String {
        switch self {
        case .select: return "select"
        case .urlTest: return "url-test"
        case .fallback: return "fallback"
        }
    }
}
