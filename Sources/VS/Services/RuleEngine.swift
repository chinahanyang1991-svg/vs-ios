import Foundation

struct RuleEngine {
    var rules: [TrafficRule]

    init(rules: [TrafficRule] = []) {
        self.rules = rules
    }

    /// 需要 GeoIP 库才能判定的规则条数。库没随包发布，这些规则不参与匹配，也不拿假数据冒充命中。
    var geoIPRuleCount: Int {
        rules.filter { $0.matchType == .geoIP }.count
    }

    /// 首条命中即停；一条都不命中返回 nil，由调用方走默认路线。
    func decide(_ request: FlowRequest) -> RuleDecision? {
        for (index, rule) in rules.enumerated() {
            if matches(rule, request) {
                return RuleDecision(ruleIndex: index, action: rule.action, policy: rule.policy,
                                    forceRemoteDNS: rule.forceRemoteDNS, noResolve: rule.noResolve)
            }
        }
        return nil
    }

    private func matches(_ rule: TrafficRule, _ request: FlowRequest) -> Bool {
        let pattern = rule.pattern.trimmingCharacters(in: .whitespaces)
        switch rule.matchType {
        case .final:
            return true
        case .geoIP:
            return false
        case .domain:
            guard let host = normalizedHost(request) else { return false }
            return host == pattern.lowercased()
        case .domainSuffix:
            guard let host = normalizedHost(request) else { return false }
            let suffix = pattern.lowercased()
            guard !suffix.isEmpty else { return false }
            return host == suffix || host.hasSuffix("." + suffix)
        case .domainKeyword:
            guard let host = normalizedHost(request) else { return false }
            let keyword = pattern.lowercased()
            return !keyword.isEmpty && host.contains(keyword)
        case .port:
            guard let port = Int(pattern) else { return false }
            return request.port == port
        case .userAgent:
            guard let agent = request.userAgent, !pattern.isEmpty else { return false }
            return glob(pattern, matches: agent)
        case .ipCIDR:
            return cidr(pattern, matches: request.ip, family: .v4)
        case .ip6CIDR:
            return cidr(pattern, matches: request.ip, family: .v6)
        }
    }

    private func normalizedHost(_ request: FlowRequest) -> String? {
        guard let host = request.host else { return nil }
        var text = host
        if text.hasSuffix(".") { text.removeLast() }
        return text.isEmpty ? nil : text.lowercased()
    }

    // MARK: - USER-AGENT

    /// 整串锚定的通配：`*` 顶任意长度（含零）。大小写敏感，界面写规则时按这个口径来。
    private func glob(_ pattern: String, matches text: String) -> Bool {
        guard pattern.contains("*") else { return pattern == text }
        let pieces = pattern.components(separatedBy: "*")
        var cursor = text.startIndex
        if let first = pieces.first, !first.isEmpty {
            guard let found = text.range(of: first, range: cursor..<text.endIndex),
                  found.lowerBound == cursor else { return false }
            cursor = found.upperBound
        }
        for piece in pieces.dropFirst().dropLast() where !piece.isEmpty {
            guard let found = text.range(of: piece, range: cursor..<text.endIndex) else { return false }
            cursor = found.upperBound
        }
        if pattern.hasSuffix("*") { return true }
        guard let last = pieces.last, !last.isEmpty else { return true }
        guard text.hasSuffix(last) else { return false }
        return text.distance(from: cursor, to: text.endIndex) >= last.count
    }

    // MARK: - CIDR

    private enum Family {
        case v4
        case v6

        var maxBits: Int {
            switch self {
            case .v4: return 32
            case .v6: return 128
            }
        }
    }

    private func cidr(_ pattern: String, matches address: String?, family: Family) -> Bool {
        guard let address = address, !address.isEmpty else { return false }
        let network: String
        let bits: Int
        if let slash = pattern.lastIndex(of: "/") {
            network = String(pattern[..<slash])
            let bitsText = String(pattern[pattern.index(after: slash)...])
            guard let parsed = Int(bitsText), (0...family.maxBits).contains(parsed) else { return false }
            bits = parsed
        } else {
            network = pattern
            bits = family.maxBits
        }
        guard let networkBytes = addressBytes(network, family: family),
              let probeBytes = addressBytes(address, family: family) else { return false }
        return sharesPrefix(networkBytes, probeBytes, bits: bits)
    }

    private func sharesPrefix(_ a: [UInt8], _ b: [UInt8], bits: Int) -> Bool {
        guard a.count == b.count, bits <= a.count * 8 else { return false }
        for byte in 0..<(bits / 8) {
            if a[byte] != b[byte] { return false }
        }
        let rest = bits % 8
        guard rest > 0 else { return true }
        // 掩码必须由 UInt8 自己移位：先升成 Int 再收回 UInt8 会整数溢出，崩在这条判据上。
        let mask: UInt8 = 0xFF << UInt8(8 - rest)
        return a[bits / 8] & mask == b[bits / 8] & mask
    }

    private func addressBytes(_ text: String, family: Family) -> [UInt8]? {
        switch family {
        case .v4: return ipv4Bytes(text)
        case .v6: return ipv6Bytes(text)
        }
    }

    private func ipv4Bytes(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 4, part.allSatisfy({ $0.isNumber }),
                  let value = Int(part), (0...255).contains(value) else { return nil }
            bytes.append(UInt8(value))
        }
        return bytes
    }

    private func ipv6Bytes(_ text: String) -> [UInt8]? {
        guard !text.isEmpty, text.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." }) else { return nil }
        let halves: ([Substring], [Substring]?)
        if let gap = text.range(of: "::") {
            guard text.range(of: "::", range: text.index(after: gap.lowerBound)..<text.endIndex) == nil else { return nil }
            let right = text[gap.upperBound...]
            guard let left = groups(text[..<gap.lowerBound]), let rest = groups(right) else { return nil }
            halves = (left, rest)
        } else {
            guard let all = groups(text) else { return nil }
            halves = (all, nil)
        }
        var head: [UInt8] = []
        for group in halves.0 {
            guard let bytes = ipv6GroupBytes(group) else { return nil }
            head.append(contentsOf: bytes)
        }
        guard let tailGroups = halves.1 else {
            return head.count == 16 ? head : nil
        }
        var tail: [UInt8] = []
        for group in tailGroups {
            guard let bytes = ipv6GroupBytes(group) else { return nil }
            tail.append(contentsOf: bytes)
        }
        let gapBytes = 16 - head.count - tail.count
        guard gapBytes >= 0 else { return nil }
        return head + [UInt8](repeating: 0, count: gapBytes) + tail
    }

    /// `::` 两侧各自是若干组；组内为空（如 "1::2:" 这类畸形）判不可解析。
    /// 参数写 StringProtocol：调用处一半传 String、一半传 String 的切片，钉成 Substring 会把 String 那侧卡住。
    private func groups(_ slice: some StringProtocol) -> [Substring]? {
        if slice.isEmpty { return [] }
        let parts = slice.split(separator: ":", omittingEmptySubsequences: false)
        for part in parts where part.isEmpty { return nil }
        return parts
    }

    private func ipv6GroupBytes(_ group: Substring) -> [UInt8]? {
        if group.contains(".") {
            return ipv4Bytes(String(group))
        }
        guard !group.isEmpty, group.count <= 4, group.allSatisfy({ $0.isHexDigit }),
              let value = UInt16(group, radix: 16) else { return nil }
        return [UInt8(value >> 8), UInt8(value & 0xFF)]
    }
}
