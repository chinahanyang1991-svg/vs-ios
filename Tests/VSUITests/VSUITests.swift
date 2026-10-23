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
