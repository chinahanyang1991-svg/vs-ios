import Foundation

enum NodeKind: String, Codable, CaseIterable {
    case vless
    case vmess
    case trojan
    case shadowsocks

    var displayName: String {
        switch self {
        case .vless: return "VLESS"
        case .vmess: return "VMess"
        case .trojan: return "Trojan"
        case .shadowsocks: return "Shadowsocks"
        }
    }

    /// 当前内核（原生路线只生成 IKEv2 描述文件）能不能承载这一类节点。
    /// R23 占位＝复刻现状：这张表态表原本不存在，任何协议进来都当能用，所以恒真。
    var isCarriableByCurrentEngine: Bool {
        switch self {
        case .vless, .vmess, .trojan, .shadowsocks:
            return true
        }
    }
}

struct Node: Identifiable, Codable, Hashable {
    var name: String
    var kind: NodeKind
    var host: String
    var port: Int
    var credential: String?
    var method: String?
    var parameters: [String: String]
    /// 该节点来自哪个订阅地址；手动粘贴为 nil。刷新时按它整批替换。
    var sourceURL: String? = nil

    var id: String { "\(kind.rawValue)|\(host)|\(port)|\(name)" }

    var security: String { parameters["security"] ?? "none" }
    var usesTLS: Bool { security == "tls" || security == "reality" }
    var serverName: String? { parameters["sni"] ?? parameters["peer"] }
    var transport: String { parameters["type"] ?? parameters["net"] ?? "tcp" }
}

struct RejectedLine: Identifiable, Hashable {
    var id: Int { hashValue }
    var hint: String
    var reason: String
}

struct ParseReport: Hashable {
    var nodes: [Node] = []
    var rejected: [RejectedLine] = []
    var notices: [String] = []

    var isEmptyResult: Bool { nodes.isEmpty && rejected.isEmpty }
}
