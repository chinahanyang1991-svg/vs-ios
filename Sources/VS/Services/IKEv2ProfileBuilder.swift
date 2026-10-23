import Foundation

/// 字段名、类型与必填性取自本机取证文件
/// `tools/probe-docs/cpr.txt`（Apple《Configuration Profile Reference》2019-05-03）：
/// VPN payload 3987 行起，IKEv2 Dictionary Keys 4290 行起，DNS Dictionary Keys 4443 行起。
struct IKEv2TunnelSettings: Codable, Hashable {
    enum AuthMode: String, Codable, CaseIterable, Hashable {
        case eap
        case psk

        var displayName: String {
            switch self {
            case .eap: return "EAP（账号密码）"
            case .psk: return "PSK（共享密钥）"
            }
        }
    }

    enum DeadPeerRate: String, Codable, CaseIterable, Hashable {
        case none, low, medium, high

        var profileValue: String {
            switch self {
            case .none: return "None"
            case .low: return "Low"
            case .medium: return "Medium"
            case .high: return "High"
            }
        }
    }

    var name: String = "VS IKEv2"
    var serverHost: String = ""
    var localIdentifier: String = ""
    var authMode: AuthMode = .eap
    var username: String = ""
    var password: String = ""
    var sharedSecret: String = ""
    var serverCommonName: String = ""
    var dnsInput: String = ""
    var deadPeerRate: DeadPeerRate = .medium
    var embedSecrets: Bool = false

    /// 持久化时只保存非机密字段：密码与共享密钥永不写入磁盘，解码后为空串。
    private enum CodingKeys: String, CodingKey {
        case name, serverHost, localIdentifier, authMode
        case username, serverCommonName, dnsInput, deadPeerRate, embedSecrets
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "VS IKEv2"
        serverHost = try container.decodeIfPresent(String.self, forKey: .serverHost) ?? ""
        localIdentifier = try container.decodeIfPresent(String.self, forKey: .localIdentifier) ?? ""
        authMode = try container.decodeIfPresent(AuthMode.self, forKey: .authMode) ?? .eap
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        serverCommonName = try container.decodeIfPresent(String.self, forKey: .serverCommonName) ?? ""
        dnsInput = try container.decodeIfPresent(String.self, forKey: .dnsInput) ?? ""
        deadPeerRate = try container.decodeIfPresent(DeadPeerRate.self, forKey: .deadPeerRate) ?? .medium
        embedSecrets = try container.decodeIfPresent(Bool.self, forKey: .embedSecrets) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(serverHost, forKey: .serverHost)
        try container.encode(localIdentifier, forKey: .localIdentifier)
        try container.encode(authMode, forKey: .authMode)
        try container.encode(username, forKey: .username)
        try container.encode(serverCommonName, forKey: .serverCommonName)
        try container.encode(dnsInput, forKey: .dnsInput)
        try container.encode(deadPeerRate, forKey: .deadPeerRate)
        try container.encode(embedSecrets, forKey: .embedSecrets)
    }
}

enum IKEv2ProfileError: LocalizedError, Hashable {
    case emptyName
    case invalidHost(String)
    case missingSecret(IKEv2TunnelSettings.AuthMode)
    case pskRequiresEmbedding
    case invalidServerAddress(String)
    case invalidCommonName(String)
    case serializationFailed

    var errorDescription: String? {
        switch self {
        case .emptyName: return "连接名称不能为空"
        case .invalidHost(let h): return "服务器地址无效：\(h)（只接受 FQDN 或 IPv4）"
        case .missingSecret(let mode): return mode == .eap ? "EAP 模式需要填写用户名" : "PSK 模式需要填写共享密钥"
        case .pskRequiresEmbedding: return "PSK 模式必须勾选“把凭据写入描述文件”，iOS 没有别处可填共享密钥"
        case .invalidServerAddress(let a): return "DNS 地址无效：\(a)"
        case .invalidCommonName(let c): return "服务器证书通用名含有非法字符：\(c)"
        case .serializationFailed: return "描述文件生成失败"
        }
    }
}

enum IKEv2ProfileBuilder {
    static let payloadType = "com.apple.vpn.managed"
    static let appIdentifierPrefix = "com.vs.app"

    static func normalizedHost(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func validateHost(_ raw: String) -> String? {
        let host = normalizedHost(raw)
        if host.isEmpty { return nil }
        if host.count > 253 { return nil }
        if host.contains("://") || host.contains("/") || host.contains(":") { return nil }
        if isIPv4(host) { return host }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return nil }
        for label in labels {
            if label.isEmpty || label.count > 63 { return nil }
            if label.hasPrefix("-") || label.hasSuffix("-") { return nil }
            let ok = label.allSatisfy(isAllowedLabelCharacter)
            if !ok { return nil }
        }
        return host
    }

    static func isIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber) else { return false }
            return (0...255).contains(Int(part) ?? -1)
        }
    }

    static func dnsServers(from input: String) -> [String] {
        input
            .split { $0 == "," || $0 == ";" || $0 == " " || $0 == "\n" || $0 == "\t" }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func vpnPayload(_ settings: IKEv2TunnelSettings, uuid: String = UUID().uuidString) throws -> [String: Any] {
        let name = settings.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw IKEv2ProfileError.emptyName }
        guard let host = validateHost(settings.serverHost) else {
            throw IKEv2ProfileError.invalidHost(settings.serverHost.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        var ikev2: [String: Any] = [
            "RemoteAddress": host,
            "RemoteIdentifier": host,
            "LocalIdentifier": settings.localIdentifier.trimmingCharacters(in: .whitespacesAndNewlines),
            "DeadPeerDetectionRate": settings.deadPeerRate.profileValue,
        ]

        switch settings.authMode {
        case .eap:
            let user = settings.username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !user.isEmpty else { throw IKEv2ProfileError.missingSecret(.eap) }
            ikev2["AuthenticationMethod"] = "None"
            ikev2["ExtendedAuthEnabled"] = 1
            ikev2["AuthName"] = user
            if settings.embedSecrets {
                let pass = trimmed(settings.password)
                if !pass.isEmpty { ikev2["AuthPassword"] = pass }
            }
        case .psk:
            let secret = trimmed(settings.sharedSecret)
            guard !secret.isEmpty else { throw IKEv2ProfileError.missingSecret(.psk) }
            guard settings.embedSecrets else { throw IKEv2ProfileError.pskRequiresEmbedding }
            ikev2["AuthenticationMethod"] = "SharedSecret"
            ikev2["SharedSecret"] = secret
        }

        let commonName = trimmed(settings.serverCommonName)
        if !commonName.isEmpty {
            guard commonName.allSatisfy({ !$0.isNewline && !$0.isWhitespace }) else {
                throw IKEv2ProfileError.invalidCommonName(commonName)
            }
            ikev2["ServerCertificateIssuerCommonName"] = commonName
        }

        let servers = dnsServers(from: settings.dnsInput)
        for address in servers where !isIPv4(address) {
            throw IKEv2ProfileError.invalidServerAddress(address)
        }

        var payload: [String: Any] = [
            "PayloadType": payloadType,
            "PayloadVersion": 1,
            "PayloadUUID": uuid,
            "PayloadIdentifier": "\(appIdentifierPrefix).vpn.\(uuid)",
            "PayloadDisplayName": name,
            "PayloadOrganization": "VS",
            "UserDefinedName": name,
            "VPNType": "IKEv2",
            "IKEv2": ikev2,
        ]
        if !servers.isEmpty {
            payload["DNS"] = ["ServerAddresses": servers]
        }
        return payload
    }

    static func profile(_ settings: IKEv2TunnelSettings,
                        vpnUUID: String = UUID().uuidString,
                        profileUUID: String = UUID().uuidString) throws -> [String: Any] {
        let payload = try vpnPayload(settings, uuid: vpnUUID)
        let name = settings.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "PayloadVersion": 1,
            "PayloadType": "Configuration",
            "PayloadUUID": profileUUID,
            "PayloadIdentifier": "\(appIdentifierPrefix).profile.\(profileUUID)",
            "PayloadDisplayName": name,
            "PayloadDescription": "VS 生成的 IKEv2 连接描述文件",
            "PayloadOrganization": "VS",
            "PayloadRemovalDisallowed": false,
            "PayloadContent": [payload],
        ]
    }

    static func mobileconfig(_ settings: IKEv2TunnelSettings) throws -> Data {
        let dictionary = try profile(settings)
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: dictionary, format: .xml, options: 0) else {
            throw IKEv2ProfileError.serializationFailed
        }
        return data
    }

    static func suggestedFileName(_ settings: IKEv2TunnelSettings) -> String {
        let base = settings.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let cleaned = String(base.unicodeScalars.filter { allowed.contains($0) || $0 == "." })
            .replacingOccurrences(of: " ", with: "-")
        let trimmed = cleaned.isEmpty ? "VS-IKEv2" : cleaned
        return "\(trimmed).mobileconfig"
    }

    static func sanitizedSummary(_ settings: IKEv2TunnelSettings) -> String {
        var lines: [String] = []
        lines.append("服务器：\(normalizedHost(settings.serverHost))")
        lines.append("认证：\(settings.authMode.displayName)")
        if settings.authMode == .eap {
            lines.append("用户名：\(trimmed(settings.username))")
            lines.append("密码：\(settings.embedSecrets && !trimmed(settings.password).isEmpty ? "已写入描述文件" : "连接时手动输入")")
        } else {
            lines.append("共享密钥：已写入描述文件")
        }
        let servers = dnsServers(from: settings.dnsInput)
        if !servers.isEmpty { lines.append("DNS：\(servers.joined(separator: "、"))") }
        let cn = trimmed(settings.serverCommonName)
        if !cn.isEmpty { lines.append("证书颁发者 CN：\(cn)") }
        return lines.joined(separator: "\n")
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isAllowedLabelCharacter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
            return false
        }
        switch scalar.value {
        case 0x61...0x7A, 0x30...0x39, 0x2D: return true
        default: return false
        }
    }
}
