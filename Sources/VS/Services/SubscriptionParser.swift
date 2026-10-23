import Foundation

struct ParseError: Error {
    var message: String

    init(_ message: String) {
        self.message = message
    }
}

enum SubscriptionParser {
    static let maxNodeCount: Int = 2000

    static func parse(_ input: String) -> ParseReport {
        var report = ParseReport()
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            report.notices.append("输入为空")
            return report
        }

        if looksLikeClashYAML(trimmed) {
            report.notices.append("这是 Clash/YAML 配置文件。当前只解析节点链接集合（ss、vless、vmess、trojan），内核路线确定后再支持。")
            return report
        }

        let body = decodeIfWholeSubscriptionIsBase64(trimmed) ?? trimmed
        var truncated = false
        for raw in body.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if report.nodes.count >= maxNodeCount {
                truncated = true
                break
            }
            do {
                report.nodes.append(try parseNode(from: line))
            } catch let error as ParseError {
                report.rejected.append(RejectedLine(hint: safeHint(of: line), reason: error.message))
            } catch {
                report.rejected.append(RejectedLine(hint: safeHint(of: line), reason: "无法解析"))
            }
        }
        if truncated {
            report.notices.append("节点数已达上限 \(maxNodeCount)，后面的条目没有解析")
        }
        return report
    }

    // MARK: - 单条链接

    static func parseNode(from line: String) throws -> Node {
        guard let schemeEnd = line.range(of: "://") else {
            throw ParseError("缺少协议前缀，形如 vless:// 或 ss://")
        }
        let scheme = String(line[..<schemeEnd.lowerBound]).lowercased()
        let rest = String(line[schemeEnd.upperBound...])

        switch scheme {
        case "vless", "trojan":
            return try parseUserinfo(kind: scheme == "vless" ? .vless : .trojan, rest: rest)
        case "ss", "shadowsocks":
            return try parseShadowsocks(rest: rest)
        case "vmess":
            return try parseVMess(rest: rest)
        default:
            throw ParseError("不支持的协议")
        }
    }

    private static func parseUserinfo(kind: NodeKind, rest: String) throws -> Node {
        let (body, remark) = splitFragment(rest)
        var authority = body
        var queryText = ""
        if let cut = body.firstIndex(where: { $0 == "?" || $0 == "/" }) {
            authority = String(body[..<cut])
            let tail = String(body[cut...])
            queryText = tail.hasPrefix("/") ? String(tail.dropFirst()) : tail
        }
        if queryText.hasPrefix("?") { queryText.removeFirst() }

        guard let atIndex = authority.lastIndex(of: "@") else {
            throw ParseError("缺少 @ 分隔的认证信息")
        }
        let credentialPart = String(authority[..<atIndex])
        let hostPortText = String(authority[authority.index(after: atIndex)...])
        let (host, port) = try parseHostPort(hostPortText)
        guard let credential = credentialPart.removingPercentEncodingIfPresent(), !credential.isEmpty else {
            throw ParseError("认证信息为空")
        }
        let parameters = parseQuery(queryText)
        let name = remark.isEmpty ? "\(host):\(port)" : remark

        return Node(name: name, kind: kind, host: host, port: port,
                    credential: credential, method: nil, parameters: parameters)
    }

    private static func parseShadowsocks(rest: String) throws -> Node {
        let (body, remark) = splitFragment(rest)

        if let atIndex = body.firstIndex(of: "@") {
            guard let infoText = String(body[..<atIndex]).base64URLDecodedToString() else {
                throw ParseError("Shadowsocks 的 method:password 段不是合法 base64")
            }
            let hostPortText = String(body[body.index(after: atIndex)...])
            var hostText = hostPortText
            var queryText = ""
            if let cut = hostPortText.firstIndex(where: { $0 == "/" || $0 == "?" }) {
                hostText = String(hostPortText[..<cut])
                let tail = String(hostPortText[cut...])
                queryText = tail.hasPrefix("/") ? String(tail.dropFirst()) : tail
            }
            if queryText.hasPrefix("?") { queryText.removeFirst() }

            let (host, port) = try parseHostPort(hostText)
            let (method, password) = try splitMethodColonPassword(infoText)
            let name = remark.isEmpty ? "\(host):\(port)" : remark
            return Node(name: name, kind: .shadowsocks, host: host, port: port,
                        credential: password, method: method, parameters: parseQuery(queryText))
        }

        guard let decoded = body.base64URLDecodedToString() else {
            throw ParseError("Shadowsocks 链接首段不是合法 base64")
        }
        if let atIndex = decoded.lastIndex(of: "@") {
            let (method, password) = try splitMethodColonPassword(String(decoded[..<atIndex]))
            let (host, port) = try parseHostPort(String(decoded[decoded.index(after: atIndex)...]))
            let name = remark.isEmpty ? "\(host):\(port)" : remark
            return Node(name: name, kind: .shadowsocks, host: host, port: port,
                        credential: password, method: method, parameters: [:])
        }

        let components = decoded.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count >= 4 else {
            throw ParseError("无法从旧式 Shadowsocks 链接取出口与地址")
        }
        let (host, port) = try parseHostPort(components.suffix(2).joined(separator: ":"))
        let (method, password) = try splitMethodColonPassword(components.dropLast(2).joined(separator: ":"))
        let name = remark.isEmpty ? "\(host):\(port)" : remark
        return Node(name: name, kind: .shadowsocks, host: host, port: port,
                    credential: password, method: method, parameters: [:])
    }

    private static func parseVMess(rest: String) throws -> Node {
        let (body, remark) = splitFragment(rest)
        guard let jsonText = body.base64URLDecodedToString(),
              let data = jsonText.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ParseError("VMess 链接的 base64 不是合法 JSON")
        }
        guard let host = (object["add"] as? String)?.trimmingCharacters(in: .whitespaces), !host.isEmpty else {
            throw ParseError("VMess 缺少 add 地址")
        }
        let portText = (object["port"] as? String) ?? String((object["port"] as? Int) ?? 0)
        guard let port = Int(portText), (1...65535).contains(port) else {
            throw ParseError("VMess 端口无效")
        }
        guard let uuid = (object["id"] as? String)?.trimmingCharacters(in: .whitespaces), !uuid.isEmpty else {
            throw ParseError("VMess 缺少 id")
        }

        var parameters: [String: String] = [:]
        if let net = object["net"] as? String { parameters["type"] = net }
        if let path = object["path"] as? String, !path.isEmpty { parameters["path"] = path }
        if let headerHost = object["host"] as? String, !headerHost.isEmpty { parameters["host"] = headerHost }
        if let tls = object["tls"] as? String, tls == "tls" { parameters["security"] = "tls" }
        if let sni = object["sni"] as? String, !sni.isEmpty { parameters["sni"] = sni }
        if let alpn = object["alpn"] as? String, !alpn.isEmpty { parameters["alpn"] = alpn }
        if let aid = object["aid"] as? String, aid != "0" { parameters["aid"] = aid }
        if let flow = object["flow"] as? String, !flow.isEmpty { parameters["flow"] = flow }

        let name = remark.isEmpty ? ((object["ps"] as? String) ?? "\(host):\(port)") : remark
        return Node(name: name, kind: .vmess, host: host, port: port,
                    credential: uuid, method: nil, parameters: parameters)
    }

    // MARK: - 工具

    private static func splitFragment(_ text: String) -> (body: String, remark: String) {
        guard let hash = text.lastIndex(of: "#") else { return (text, "") }
        let body = String(text[..<hash])
        let remark = String(text[text.index(after: hash)...]).removingPercentEncoding ?? String(text[text.index(after: hash)...])
        return (body, remark.trimmingCharacters(in: .whitespaces))
    }

    private static func parseHostPort(_ text: String) throws -> (String, Int) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let forbidden = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "/?#@\\"))
        guard trimmed.rangeOfCharacter(from: forbidden) == nil else {
            throw ParseError("地址包含无效字符")
        }
        if trimmed.hasPrefix("[") {
            guard let close = trimmed.lastIndex(of: "]") else { throw ParseError("IPv6 地址缺少右括号") }
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            guard !host.isEmpty, host.rangeOfCharacter(from: CharacterSet(charactersIn: "[]")) == nil else {
                throw ParseError("IPv6 地址无效")
            }
            let tail = trimmed[trimmed.index(after: close)...]
            let portText = tail.hasPrefix(":") ? String(tail.dropFirst()) : ""
            guard let port = Int(portText), (1...65535).contains(port) else {
                throw ParseError("IPv6 地址后缺少端口")
            }
            return (host, port)
        }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty,
              parts[0].rangeOfCharacter(from: CharacterSet(charactersIn: "[]")) == nil,
              let port = Int(parts[1]), (1...65535).contains(port) else {
            throw ParseError("地址与端口格式应为 host:port")
        }
        return (String(parts[0]), port)
    }

    private static func splitMethodColonPassword(_ text: String) throws -> (String, String) {
        guard let colon = text.firstIndex(of: ":") else { throw ParseError("缺少加密方式与密码") }
        let method = String(text[..<colon])
        let password = String(text[text.index(after: colon)...])
        guard !method.isEmpty, !password.isEmpty else { throw ParseError("加密方式或密码为空") }
        return (method, password)
    }

    private static func parseQuery(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in text.split(separator: "&") {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let key = String(pair[..<eq])
            let rawValue = String(pair[pair.index(after: eq)...])
            guard !key.isEmpty else { continue }
            result[key] = rawValue.removingPercentEncoding ?? rawValue
        }
        return result
    }

    private static func looksLikeClashYAML(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("proxies:") || lowered.contains("proxy-groups:") || lowered.contains("rule-providers:")
    }

    private static func decodeIfWholeSubscriptionIsBase64(_ text: String) -> String? {
        let compact = text.filter { !$0.isWhitespace && !$0.isNewline && $0 != "\u{200b}" }
        guard compact.count >= 16 else { return nil }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_+/=")
        guard compact.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        guard let decoded = compact.base64URLDecodedToString(), decoded.contains("://") else { return nil }
        return decoded
    }

    /// 无法确定安全主机时不展示输入，避免截断提示仍泄漏凭据。
    private static func safeHint(of line: String) -> String {
        guard let schemeEnd = line.range(of: "://") else {
            return "未知协议://…"
        }
        let scheme = String(line[..<schemeEnd.lowerBound]).lowercased()
        guard ["vless", "trojan", "ss", "shadowsocks", "vmess"].contains(scheme) else {
            return "未知协议://…"
        }
        let placeholder = scheme + "://…"
        guard scheme != "vmess" else { return placeholder }
        let authority = line[schemeEnd.upperBound...].prefix { $0 != "?" && $0 != "/" && $0 != "#" }
        guard let at = authority.lastIndex(of: "@") else { return placeholder }
        let hostPort = authority[authority.index(after: at)...]
        let host: String
        let allowed: CharacterSet
        if hostPort.hasPrefix("[") {
            guard let close = hostPort.firstIndex(of: "]") else { return placeholder }
            let suffix = hostPort[hostPort.index(after: close)...]
            guard suffix.isEmpty || suffix.hasPrefix(":") else { return placeholder }
            host = String(hostPort[hostPort.index(after: hostPort.startIndex)..<close])
            guard host.contains(":") else { return placeholder }
            allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF:.")
        } else {
            let parts = hostPort.split(separator: ":", omittingEmptySubsequences: false)
            guard let first = parts.first, parts.count <= 2 else { return placeholder }
            host = String(first)
            allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._")
        }
        guard !host.isEmpty, host.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return placeholder
        }
        return scheme + "://" + String(host.prefix(6)) + "…"
    }
}

extension String {
    func base64URLDecodedToString() -> String? {
        var text = replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = text.count % 4
        if remainder > 0 { text += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: text) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func removingPercentEncodingIfPresent() -> String? {
        return removingPercentEncoding ?? self
    }
}
