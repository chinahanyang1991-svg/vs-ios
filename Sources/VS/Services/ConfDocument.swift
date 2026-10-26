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
    /// W3 红轮占位：复刻现状——软件读不进 `.conf`，任何输入都解析不出内容。
    static func parse(_ text: String) -> ConfDocument {
        _ = text
        return ConfDocument()
    }

    static func render(_ document: ConfDocument) -> String {
        _ = document
        return ""
    }
}
