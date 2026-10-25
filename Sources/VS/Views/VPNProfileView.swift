import SwiftUI

struct VPNProfileView: View {
    @Environment(ConfigStore.self) private var store
    @State private var settings = IKEv2TunnelSettings()
    @State private var exportedURL: URL?
    @State private var errorMessage: String?
    @State private var statusNote: String?
    @State private var profiles: [URL] = []
    @State private var profilesError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("服务器") {
                    TextField("连接名称", text: $settings.name)
                    TextField("服务器地址（域名或 IPv4）", text: $settings.serverHost)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    TextField("本地标识（可留空）", text: $settings.localIdentifier)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                }

                Section("认证") {
                    Picker("方式", selection: $settings.authMode) {
                        ForEach(IKEv2TunnelSettings.AuthMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    if settings.authMode == .eap {
                        TextField("用户名", text: $settings.username)
                            .textInputAutocapitalization(.never)
                        SecureField("密码（不勾选则连接时手动输入）", text: $settings.password)
                    } else {
                        SecureField("共享密钥", text: $settings.sharedSecret)
                    }
                    TextField("服务器证书颁发者 CN（可留空）", text: $settings.serverCommonName)
                        .textInputAutocapitalization(.never)
                }

                Section("网络") {
                    TextField("DNS 服务器，逗号分隔（可留空）", text: $settings.dnsInput)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                    Picker("心跳检测", selection: $settings.deadPeerRate) {
                        Text("关闭").tag(IKEv2TunnelSettings.DeadPeerRate.none)
                        Text("低").tag(IKEv2TunnelSettings.DeadPeerRate.low)
                        Text("中").tag(IKEv2TunnelSettings.DeadPeerRate.medium)
                        Text("高").tag(IKEv2TunnelSettings.DeadPeerRate.high)
                    }
                }

                Section {
                    Toggle("把凭据写入描述文件", isOn: $settings.embedSecrets)
                    Text(settings.embedSecrets
                         ? "导出的 .mobileconfig 含明文密码，安装完请删掉文件副本。"
                         : "描述文件不含密码，第一次连接时 iOS 会弹窗要求输入。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("安全")
                }

                Section("生成结果") {
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    // 「生成成了」和「没能存到本机」是两件事，一屏里都要说，不能只说其中一半。
                    if let statusNote {
                        Text(statusNote)
                            .font(.callout)
                            .foregroundStyle(statusNote.contains("未能保存") ? Color.orange : Color.secondary)
                    }
                    if !settings.serverHost.isEmpty {
                        Text(IKEv2ProfileBuilder.sanitizedSummary(settings))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if let exportedURL {
                        ShareLink(item: exportedURL,
                                  preview: SharePreview(exportedURL.lastPathComponent))
                            .buttonStyle(.borderedProminent)
                            .accessibilityLabel("分享描述文件")
                    } else {
                        Button("生成描述文件") { generate() }
                            .buttonStyle(.borderedProminent)
                    }
                }

                Section("安装步骤") {
                    steps
                }

                Section("已导出的描述文件") {
                    if let profilesError {
                        Text(profilesError).font(.caption).foregroundStyle(.orange)
                        Button("重新读取") { reloadProfiles() }
                    } else if profiles.isEmpty {
                        Text("未发现已导出的描述文件").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(profiles, id: \.self) { url in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(url.lastPathComponent).font(.callout.monospaced())
                                Text(sizeText(url)).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("删除", role: .destructive) { deleteProfile(url) }
                                .font(.caption)
                                .accessibilityLabel("删除描述文件 \(url.lastPathComponent)")
                        }
                    }
                    if !profiles.isEmpty {
                        Text("含明文密码的文件用完请删掉。")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("VPN 描述文件")
            .background(GlassBackground())
            .onAppear {
                syncFromStore()
                reloadProfiles()
            }
            .onDisappear {
                do { try store.updateVPNSettings(settings) }
                catch { errorMessage = ConfigStore.vpnPersistenceHint(savedOnDisk: store.vpnSettingsSavedOnDisk) }
            }
            .onChange(of: settings) { _, _ in
                exportedURL = nil
                statusNote = nil
            }
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("点“生成描述文件”，再用分享面板选“存储到文件”。", systemImage: "1.circle")
            Label("iPhone 上打开该 .mobileconfig，右上角允许下载配置描述文件。", systemImage: "2.circle")
            Label("设置 → 通用 → VPN 与设备管理 → 安装，然后在“设置 → VPN”里连接。", systemImage: "3.circle")
            Label("描述文件本身不需要开发者账号：走的是 iOS 自带的 IKEv2 通道，VS 不劫持系统网络。"
                  + "但 VS 这个 App 怎么免费装进手机仍未验证，那是另一件事。", systemImage: "checkmark.seal")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func syncFromStore() {
        var restored = store.vpnSettings
        restored.password = settings.password
        restored.sharedSecret = settings.sharedSecret
        settings = restored
    }

    private func generate() {
        errorMessage = nil
        statusNote = nil
        do {
            exportedURL = try store.exportProfile(settings)
            statusNote = store.lastStatus
            reloadProfiles()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteProfile(_ url: URL) {
        errorMessage = nil
        statusNote = nil
        do {
            try store.deleteExportedProfile(url)
            if exportedURL == url { exportedURL = nil }
            reloadProfiles()
        } catch {
            errorMessage = "删除失败：\(error.localizedDescription)"
        }
    }

    private func reloadProfiles() {
        do {
            profiles = try store.exportedProfiles()
            profilesError = nil
        } catch {
            profiles = []
            profilesError = "无法读取描述文件列表，不能确认是否有残留：\(error.localizedDescription)"
        }
    }

    private func sizeText(_ url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}
