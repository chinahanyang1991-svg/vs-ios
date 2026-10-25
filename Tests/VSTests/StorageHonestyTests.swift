import XCTest
@testable import VS

/// 三件事各自要有一句诚实的话：写不下去不等于生成不出来、读不动不等于没有文件、
/// 没写进描述文件就不能说写进去了。这一族钉的都是"状态与盘上实况不许各说一套"。
final class StorageHonestyTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func cipher(_ fill: UInt8) throws -> ConfigCipher {
        try ConfigCipher(key: Data(repeating: fill, count: 32))
    }

    private func makeSettings() -> IKEv2TunnelSettings {
        var settings = IKEv2TunnelSettings()
        settings.name = "Honesty Export"
        settings.serverHost = "vpn.example.com"
        settings.authMode = .eap
        settings.username = "user@example.com"
        return settings
    }

    /// 把配置文件的路径堵成一个目录：任何往它写盘的动作都会失败，
    /// 这正是「本机密钥拿不到 ⇒ write() 直接拒绝」在测试里能复现的形状。
    private func blockedStoreURL() throws -> URL {
        let blocked = directory.appendingPathComponent("vs-config.json")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
        return blocked
    }

    func testExportProducesProfileEvenWhenTheStoreCannotBeSaved() throws {
        let store = ConfigStore(storeURL: try blockedStoreURL(), cipher: try cipher(11))
        let settings = makeSettings()
        XCTAssertThrowsError(try store.updateVPNSettings(settings),
                             "前提：这条 store 确实写不下去")

        var exportedURL: URL?
        var exportError: String?
        do {
            exportedURL = try store.exportProfile(settings)
        } catch {
            exportError = String(describing: error)
        }
        guard let url = exportedURL else {
            XCTFail("描述文件被「保存到本地配置」这一步挡死了：\(exportError ?? "无错误")")
            return
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "导出的文件要真在盘上")
    }

    func testExportSeparatesGeneratedFromSavedInOneSentence() throws {
        let store = ConfigStore(storeURL: try blockedStoreURL(), cipher: try cipher(11))
        var exportedURL: URL?
        var exportError: String?
        do {
            exportedURL = try store.exportProfile(makeSettings())
        } catch {
            exportError = String(describing: error)
        }
        guard exportedURL != nil else {
            XCTFail("导出要先成功才谈得上文案：\(exportError ?? "无错误")")
            return
        }
        XCTAssertTrue(store.lastStatus.contains("已生成描述文件"),
                      "生成成功了，状态里要说生成成功：\(store.lastStatus)")
        XCTAssertTrue(store.lastStatus.contains("未能保存"),
                      "但保存到本地确实失败了，同一句话里不能漏掉：\(store.lastStatus)")
        XCTAssertEqual(store.vpnSettings.serverHost, "vpn.example.com",
                       "写不下去也不代表内存里的设置该退回旧值")
    }

    func testDirectoryInPlaceOfConfigIsReportedAsAReadFailure() throws {
        let store = ConfigStore(storeURL: try blockedStoreURL(), cipher: try cipher(11))
        XCTAssertNotNil(store.loadFailure,
                        "读不动不等于「没有文件」，必须留下一个能问到的状态")
        XCTAssertTrue(store.lastStatus.contains("读取失败"),
                      "界面上要说的是读取失败，而不是装作从没导入过：\(store.lastStatus)")
    }

    func testAbsentConfigFileIsNotReportedAsAFailure() throws {
        let absent = directory.appendingPathComponent("not-there-yet.json")
        let store = ConfigStore(storeURL: absent, cipher: try cipher(22))
        XCTAssertNil(store.loadFailure, "首次启动没有配置文件，不该被说成读不到")
    }

    func testRecoveryEntryCanClearAnUnreadableDirectory() throws {
        let blocked = try blockedStoreURL()
        let store = ConfigStore(storeURL: blocked, cipher: try cipher(11))
        var discardError: String?
        do {
            try store.discardUnreadableStore()
        } catch {
            discardError = String(describing: error)
        }
        XCTAssertNil(discardError,
                     "读不动时那条「清除并重新开始」的退路必须可用：\(discardError ?? "nil")")
        XCTAssertFalse(FileManager.default.fileExists(atPath: blocked.path),
                       "退路要真的把堵住的路径拿走")
    }

    // MARK: - R15：导出没落盘时，「内存里的值」和「盘上的值」是两件事

    func testFailedExportMarksVPNSettingsAsUnsavedOnDisk() throws {
        let store = ConfigStore(storeURL: try blockedStoreURL(), cipher: try cipher(11))
        do {
            _ = try store.exportProfile(makeSettings())
        } catch {
            XCTFail("前提：导出这条路不该被保存失败挡死：\(error)")
        }
        XCTAssertEqual(store.vpnSettings.serverHost, "vpn.example.com",
                       "内存里要留着用户刚填的值，别让人重填一遍")
        XCTAssertFalse(store.vpnSettingsSavedOnDisk,
                       "盘上还是旧值，就得有一个能问到的状态给界面用")
    }

    func testLaterSuccessfulSaveClearsTheUnsavedMark() throws {
        let blocked = try blockedStoreURL()
        let store = ConfigStore(storeURL: blocked, cipher: try cipher(11))
        _ = try store.exportProfile(makeSettings())
        XCTAssertFalse(store.vpnSettingsSavedOnDisk, "第一步：导出成功了，但确实没落盘")
        try FileManager.default.removeItem(at: blocked)
        try store.updateVPNSettings(makeSettings())
        XCTAssertTrue(store.vpnSettingsSavedOnDisk,
                      "路径腾开之后一次成功的保存要把状态收回来，界面不许继续报「没保存」")
    }

    func testHealthyStoreKeepsTheSavedOnDiskMarkTrue() throws {
        let store = ConfigStore(storeURL: directory.appendingPathComponent("vs-config.json"),
                                cipher: try cipher(33))
        XCTAssertTrue(store.vpnSettingsSavedOnDisk,
                      "从没失败过的存储不该报「未保存」——这条是反向守卫")
        try store.updateVPNSettings(makeSettings())
        XCTAssertTrue(store.vpnSettingsSavedOnDisk, "成功保存之后仍然要说得出「已保存」")
    }

    func testPersistenceHintSeparatesSessionOnlyFromTrueRollback() {
        let saved = ConfigStore.vpnPersistenceHint(savedOnDisk: true)
        let sessionOnly = ConfigStore.vpnPersistenceHint(savedOnDisk: false)
        XCTAssertNotEqual(saved, sessionOnly, "两种情况的后果不一样，一句话不许通用")
        XCTAssertTrue(saved.contains("下次进入会回到旧值"),
                      "真回退的那种才配用旧文案：\(saved)")
        XCTAssertTrue(sessionOnly.contains("本机文件里还是旧值"),
                      "没落盘时要说清磁盘上是旧值：\(sessionOnly)")
        XCTAssertTrue(sessionOnly.contains("退出 App"),
                      "…并点明这只撑到本次会话：\(sessionOnly)")
    }
}
