import SwiftUI
import UIKit

struct NodeListView: View {
    @Environment(ConfigStore.self) private var store
    @State private var probe = ProbeCoordinator()
    @State private var showImport = false
    @State private var editingNode: Node?
    @State private var notice = NodeNotice()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("节点")
                .background(GlassBackground())
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            notice.beginOperation()
                            showImport = true
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button(probe.isRunning ? "测速中" : "测速") {
                            notice.beginOperation()
                            Task { await probe.run(nodes: store.nodes) }
                        }
                        .disabled(store.nodes.isEmpty || probe.isRunning)
                    }
                }
                .sheet(isPresented: $showImport) {
                    ImportView()
                }
                .safeAreaInset(edge: .bottom) {
                    if let noticeText = notice.message {
                        Text(noticeText)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.thinMaterial)
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.nodes.isEmpty {
            ContentUnavailableView {
                Label("还没有节点", systemImage: "tray")
            } description: {
                Text("导入订阅链接，或直接粘贴 ss、vless、vmess、trojan 节点链接。")
            } actions: {
                Button("粘贴链接") { showImport = true }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            List {
                ForEach(store.nodes) { node in
                    NodeRow(node: node, outcome: probe.outcomes[node.id])
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .swipeActions {
                            Button("编辑") { editingNode = node }
                                .tint(.blue)
                            Button("删除", role: .destructive) {
                                notice.beginOperation()
                                do {
                                    try store.removeNode(node)
                                    probe.forgetOutcome(for: node.id)
                                } catch {
                                    notice.raise("删除未生效：本地文件写入失败，节点仍然保留")
                                }
                            }
                        }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable {
                notice.beginOperation()
                await probe.run(nodes: store.nodes)
            }
            .sheet(item: $editingNode) { node in
                NodeEditorView(node: node) { oldID in
                    probe.forgetOutcome(for: oldID)
                }
            }
        }
    }
}

struct NodeRow: View {
    let node: Node
    let outcome: ProbeOutcome?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(node.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(outcome?.display ?? "未测")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(color)
            }
            HStack(spacing: 6) {
                badge(node.kind.displayName)
                badge(node.usesTLS ? "TLS" : "明文")
                badge(node.transport.uppercased())
                if node.method != nil { badge(node.method ?? "") }
            }
            Text("\(node.host):\(node.port)")
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
        }
        .glassCard()
    }

    private var color: Color {
        switch outcome {
        case .tcpConnected: return .green
        case .failed, .timedOut: return .orange
        case nil: return .secondary
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.white.opacity(0.12), in: Capsule())
    }
}

struct NodeEditorView: View {
    @Environment(ConfigStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let onUpdated: (String) -> Void

    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var credential: String
    @State private var errorText: String?

    private let node: Node

    init(node: Node, onUpdated: @escaping (String) -> Void) {
        self.node = node
        self.onUpdated = onUpdated
        _name = State(initialValue: node.name)
        _host = State(initialValue: node.host)
        _port = State(initialValue: String(node.port))
        _credential = State(initialValue: node.credential ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("可编辑") {
                    TextField("名称", text: $name)
                    TextField("服务器地址", text: $host)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("端口", text: $port)
                        .keyboardType(.numbersAndPunctuation)
                    TextField(node.kind == .shadowsocks ? "密码" : "UUID 或密码", text: $credential)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote.monospaced())
                }
                Section("本轮不支持修改") {
                    LabeledContent("协议", value: node.kind.displayName)
                    if let method = node.method {
                        LabeledContent("加密方式", value: method)
                    }
                    LabeledContent("传输方式", value: node.transport.uppercased())
                    LabeledContent("TLS", value: node.security)
                    if let serverName = node.serverName {
                        LabeledContent("SNI", value: serverName)
                    }
                    if node.sourceURL != nil {
                        Text("该节点来自订阅，下次刷新会以服务端版本覆盖这里保存的修改。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                if let errorText {
                    Text(errorText).font(.caption).foregroundStyle(.orange)
                }
            }
            .navigationTitle("编辑节点")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
        }
    }

    private func save() {
        let trimmedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsedPort = Int(trimmedPort) else {
            errorText = "编辑未生效：端口要填数字，当前是“\(trimmedPort)”"
            return
        }
        var updated = node
        updated.name = name
        updated.host = host
        updated.port = parsedPort
        updated.credential = credential.isEmpty ? nil : credential
        do {
            try store.updateNode(id: node.id, to: updated)
            onUpdated(node.id)
            dismiss()
        } catch {
            errorText = (error as NSError).localizedDescription
        }
    }
}

struct ImportView: View {
    @Environment(ConfigStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var title = "手动粘贴"
    @State private var text = ""
    @State private var report: ParseReport?
    @State private var importError: String?
    @State private var pasteNotice: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("这批节点的备注名", text: $title)
                }
                Section("节点链接或订阅正文") {
                    TextEditor(text: $text)
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote.monospaced())
                        .frame(minHeight: 160)
                    Button("粘贴剪贴板内容") {
                        switch PasteInbox.outcome(current: text, clipboard: UIPasteboard.general.string) {
                        case .appended(let merged):
                            text = merged
                            pasteNotice = nil
                        case .empty:
                            pasteNotice = "剪贴板：没有可粘贴的内容"
                        case .unavailable:
                            pasteNotice = "剪贴板：系统没有交出内容，可能被权限拦截"
                        }
                    }
                    if let pasteNotice {
                        Text(pasteNotice).font(.caption).foregroundStyle(.orange)
                    }
                }
                Section("解析结果") {
                    if let importError {
                        Text(importError).font(.caption).foregroundStyle(.orange)
                    }
                    if let report {
                        LabeledContent("可用节点", value: "\(report.nodes.count)")
                        LabeledContent("被拒绝", value: "\(report.rejected.count)")
                        ForEach(report.rejected) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.hint).font(.caption.monospaced())
                                Text(item.reason).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        ForEach(report.notices, id: \.self) { notice in
                            Text(notice).font(.caption).foregroundStyle(.orange)
                        }
                    } else {
                        Text("尚未解析").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("导入")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") {
                        do {
                            report = try store.importNodes(from: text, title: title.isEmpty ? "未命名" : title)
                            importError = nil
                        } catch {
                            report = nil
                            importError = "导入未生效：本地文件写入失败，节点没有保存"
                        }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
