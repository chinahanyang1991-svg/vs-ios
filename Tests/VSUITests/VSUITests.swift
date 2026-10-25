import UIKit
import XCTest

final class VSUITests: XCTestCase {
    @MainActor
    func testImportAndClearNodes() throws {
        let app = launchApp()
        app.tabBars.buttons["订阅"].tap()
        let clear = app.buttons["清空全部节点与记录"]
        if clear.isEnabled { clear.tap() }
        app.tabBars.buttons["节点"].tap()
        XCTAssertTrue(app.staticTexts["还没有节点"].waitForExistence(timeout: 5))
        let link = "vless://demo@public.example:443?path=/a@127.0.0.1:22#UI-Test"
        UIPasteboard.general.string = link
        app.buttons["粘贴链接"].tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let paste = app.buttons["粘贴剪贴板内容"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "导入页要有真正可用的剪贴板入口")
        paste.tap()
        // 读系统剪贴板会触发 iOS 18 的“允许粘贴”授权，它属于 SpringBoard，
        // 不先点掉的话 App 永不空闲，后面的取值查询只会超时。
        let allowPaste = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Paste"]
        if allowPaste.waitForExistence(timeout: 5) { allowPaste.tap() }
        XCTAssertEqual(editor.value as? String, link, "剪贴板内容必须原样进入输入框")
        attachScreenshot(app, name: "节点原始输入")
        app.navigationBars["导入"].buttons["导入"].tap()
        XCTAssertEqual(editor.value as? String, link)
        app.navigationBars["导入"].buttons["关闭"].tap()
        XCTAssertTrue(app.staticTexts["public.example:443"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["127.0.0.1:22"].exists)
        attachScreenshot(app, name: "节点导入")
        app.tabBars.buttons["订阅"].tap()
        app.buttons["清空全部节点与记录"].tap()
        app.tabBars.buttons["节点"].tap()
        XCTAssertTrue(app.staticTexts["还没有节点"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        // 冷启动落在第一个 tab「概览」，而这里要验的是节点列表有没有落盘，必须显式切过去。
        let nodesTabAfterRelaunch = app.tabBars.buttons["节点"]
        XCTAssertTrue(nodesTabAfterRelaunch.waitForExistence(timeout: 10))
        nodesTabAfterRelaunch.tap()
        XCTAssertTrue(app.staticTexts["还没有节点"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testPasteOnEmptyClipboardGivesVisibleNotice() throws {
        let app = launchApp()
        UIPasteboard.general.string = ""
        app.tabBars.buttons["节点"].tap()
        app.buttons["粘贴链接"].tap()
        let paste = app.buttons["粘贴剪贴板内容"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()
        dismissPastePermissionIfNeeded()
        // 系统没有内容可给时可能返回 nil 也可能返回空串，两种都必须落到同一条可见提示上；
        // 按钮文案“粘贴剪贴板内容”本身也含“剪贴板”，所以按提示前缀匹配。
        let notice = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "剪贴板：")).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "读不到剪贴板内容时必须给出可见反馈，不能静默无反应")
        attachScreenshot(app, name: "空剪贴板反馈")
        app.terminate()
    }

    @MainActor
    func testEditNodeNameFromListAndSurvivesRelaunch() throws {
        let app = launchApp()
        app.tabBars.buttons["订阅"].tap()
        let clear = app.buttons["清空全部节点与记录"]
        if clear.isEnabled { clear.tap() }
        app.tabBars.buttons["节点"].tap()
        UIPasteboard.general.string = "vless://demo@public.example:443?path=/a#UI-Test"
        app.buttons["粘贴链接"].tap()
        let paste = app.buttons["粘贴剪贴板内容"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()
        dismissPastePermissionIfNeeded()
        app.navigationBars["导入"].buttons["导入"].tap()
        app.navigationBars["导入"].buttons["关闭"].tap()
        let cell = app.cells.firstMatch
        XCTAssertTrue(app.staticTexts["UI-Test"].waitForExistence(timeout: 5), "导入后列表里要有这条节点")
        XCTAssertTrue(cell.exists)

        cell.swipeLeft()
        let edit = app.buttons["编辑"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "左滑必须露出“编辑”，否则名字打错只能删了重贴")
        edit.tap()
        let nameField = app.textFields["名称"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "点“编辑”必须打开面板并带出当前名称")
        XCTAssertEqual(nameField.value as? String, "UI-Test", "面板初始值必须是这个节点的当前名字")
        replace(nameField, with: "UI-Edited")
        attachScreenshot(app, name: "编辑面板")
        app.buttons["保存"].tap()

        XCTAssertTrue(app.staticTexts["UI-Edited"].waitForExistence(timeout: 5), "保存后列表要立刻反映新名字")
        XCTAssertFalse(app.staticTexts["UI-Test"].exists, "旧名字不能还留在列表里")
        XCTAssertTrue(app.staticTexts["public.example:443"].exists, "只改名不该动主机与端口")
        attachScreenshot(app, name: "改名后的列表")

        app.terminate()
        app.launch()
        // 同上：改名落盘要看节点列表，冷启动现在停在「概览」。
        let nodesTab = app.tabBars.buttons["节点"]
        XCTAssertTrue(nodesTab.waitForExistence(timeout: 10))
        nodesTab.tap()
        XCTAssertTrue(app.staticTexts["UI-Edited"].waitForExistence(timeout: 5),
                      "改名必须落盘，重启后不能回到旧名字")
        app.terminate()
    }

    @MainActor
    func testProfileValidationExportAndDelete() throws {
        let app = launchApp()
        app.tabBars.buttons["VPN"].tap()
        let host = app.textFields["服务器地址（域名或 IPv4）"]
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        replace(app.textFields["连接名称"], with: ".UI-Test")
        replace(host, with: "invalid")
        replace(app.textFields["用户名"], with: "demo")
        let generate = app.buttons["生成描述文件"]
        reveal(generate, in: app)
        generate.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "服务器地址无效")).firstMatch.waitForExistence(timeout: 5))
        for _ in 0..<5 where !host.isHittable { app.swipeDown() }
        replace(host, with: "vpn.example.com")
        reveal(generate, in: app)
        generate.tap()
        let share = app.buttons["分享描述文件"]
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        let delete = app.buttons["删除描述文件 .UI-Test.mobileconfig"]
        reveal(delete, in: app)
        XCTAssertTrue(delete.exists)
        attachScreenshot(app, name: "描述文件生成")
        delete.tap()
        XCTAssertFalse(delete.exists)
        XCTAssertFalse(share.exists)
        XCTAssertTrue(generate.exists)
        attachScreenshot(app, name: "描述文件清除")
    }

    @MainActor
    func testAboutPageReportsSigningStatusHonestly() throws {
        // 云端 UI 测试跑的是模拟器包，里面没有 embedded.mobileprovision：
        // 界面必须承认“读不到”，不能拿一个编出来的天数糊弄用户。
        let app = launchApp()
        app.tabBars.buttons["关于"].tap()
        XCTAssertTrue(app.staticTexts["安装签名"].waitForExistence(timeout: 5), "关于页要有“安装签名”分区")
        let notice = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "没有可读取的签名描述文件")).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 5), "读不到描述文件时要直说读不到")
        XCTAssertFalse(app.staticTexts["剩余有效天数"].exists, "没有描述文件就不能显示剩余天数")
        XCTAssertFalse(app.staticTexts["到期时间"].exists, "没有描述文件就不能显示到期时间")
        attachScreenshot(app, name: "关于-签名状态")
    }

    @MainActor
    func testHomeTabStatesWhatIsKnownAndUnknown() throws {
        // 概览页只许复述 App 自己已有的数据：清空之后必须承认“还没有节点/从未刷新”，
        // 并且写清系统 VPN 连接状态是它读不到的，不能摆出一副已连上的样子。
        let app = launchApp()
        app.tabBars.buttons["订阅"].tap()
        let clear = app.buttons["清空全部节点与记录"]
        if clear.isEnabled { clear.tap() }
        app.tabBars.buttons["概览"].tap()
        XCTAssertTrue(app.staticTexts["当前配置"].waitForExistence(timeout: 5), "概览页要有“当前配置”分区")
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "还没有节点")).firstMatch.waitForExistence(timeout: 5))
        // 失败瞬间的层级读数显示这一行合成一条 '最近刷新, 从未刷新'，精确匹配取不到值。
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "从未刷新")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "读不到描述文件")).firstMatch.waitForExistence(timeout: 5),
            "模拟器包没有描述文件，概览页要直说读不到而不是编一个天数")
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "本 App 读不到")).firstMatch.waitForExistence(timeout: 5))
        attachScreenshot(app, name: "概览-空状态")
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["节点"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func dismissPastePermissionIfNeeded() {
        // 读系统剪贴板会触发 iOS 18 的“允许粘贴”授权，它属于 SpringBoard，
        // 不先点掉的话 App 永不空闲，后面的取值查询只会超时。
        let allowPaste = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Paste"]
        if allowPaste.waitForExistence(timeout: 5) { allowPaste.tap() }
    }

    @MainActor
    private func replace(_ field: XCUIElement, with text: String) {
        field.tap()
        let previous = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count) + text)
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
