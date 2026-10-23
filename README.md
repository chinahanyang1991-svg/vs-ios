# VS（iOS 端节点管理，研究版 0.1.0）

自用 iOS 18 原生 App。零费用约束下的当前形态：只包含可用免费账号签名的能力，不含任何需要 Apple 付费开发者账号权限的 Network Extension。

## 已实现

- 订阅与节点链接导入：`ss://`、`vless://`、`trojan://`、`vmess://`，支持整段 base64 订阅正文；Clash/YAML 会被识别并明确告知暂不解析。
- 本地存储：App Group `group.com.vs.app` 内 JSON，原子写入，带完整文件保护；容器不可用时退回 Application Support。
- 节点可达性测速：`NWConnection` TCP 连接计时，报告连接耗时或失败原因（不谎报为隧道可用）。
- 界面：SwiftUI + 玻璃材质卡片，节点列表 / 订阅 / 关于三页。

## 尚未实现（如实列）

- 隧道本身。iOS 自定义隧道扩展需要 `com.apple.developer.networking.networkextension`，Apple 只发给付费会员；零费用路线是改由系统原生 IKEv2 承载（`.mobileconfig`，无需签名与账号），该部分待服务端条件确定后实现。
- 内核桥接（sing-box）、分流规则编辑、DNS 控制、连接观测。

## 构建与验证

本机只有 Windows，编译与单测由 GitHub Actions 的免费 `macos-15` 标准执行器完成：

```
brew install xcodegen
xcodegen generate
xcodebuild -project VS.xcodeproj -scheme VS -sdk iphoneos CODE_SIGNING_ALLOWED=NO build
```

产物为未签名 IPA，需先用本人 Apple 账号签名后才.install（研究结论见上层目录 `probe-tunnel/`）。
仓库公开，节点地址与账号只存在于设备本地，不进入代码库。
