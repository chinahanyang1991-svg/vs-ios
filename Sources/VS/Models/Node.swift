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
}

struct Node: Identifiable, Codable, Hashable {
    var name: String
    var kind: NodeKind
    var host: String
    var port: Int
    var credential: String?
    var method: String?
    var parameters: [String: String]
    var rawURL: String

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
