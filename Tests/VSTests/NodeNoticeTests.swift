import XCTest
@testable import VS

/// R18：节点页的失败横幅必须**可复位**。现状是 `NodeListView` 里一个 `@State storeError`，
/// 只在删除失败那一次赋值（`NodeListView.swift:72`），全文没有任何一处把它清回 nil——
/// 于是"删除未生效"会一直挂在页面底部，后续成功的导入/编辑/删除都盖不掉它。
/// 红轮写死预期：用例级 2 红（第 2、3 条各 1 条断言读被占位改坏的值），断言级 2；
/// 其余 3 条在占位上天生绿，是反向守卫（防把"可复位"实现成"永远不显示"、防只显示最新变成最旧）。
final class NodeNoticeTests: XCTestCase {

    private let deleteFailure = "删除未生效：本地文件写入失败，节点仍然保留"
    private let editFailure = "修改未生效：本地文件写入失败，节点仍然是旧值"

    /// 反向守卫：横幅一开始必须是空的，否则"撤下"无从谈起。
    func testFreshBannerStartsEmpty() {
        let notice = NodeNotice()
        XCTAssertNil(notice.message)
    }

    /// 反向守卫：失败原文必须一字不改地显示，不许被改写成通用文案。
    func testRaiseShowsTheFailureTextVerbatim() {
        let notice = NodeNotice()
        notice.raise(deleteFailure)
        XCTAssertEqual(notice.message, deleteFailure)
    }

    /// 关键判据一：显式撤下之后，页面上不该再有旧提示。
    func testClearTakesTheBannerDown() {
        let notice = NodeNotice()
        notice.raise(deleteFailure)
        notice.clear()
        XCTAssertNil(notice.message)
    }

    /// 关键判据二：新一轮操作开始时，上一轮的失败提示不得继续挂着；
    /// 而这一轮自己再失败时，新提示必须显示出来（防实现成"永远不显示"）。
    func testStaleBannerDoesNotSurviveTheNextOperation() {
        let notice = NodeNotice()
        notice.raise(deleteFailure)
        notice.beginOperation()
        XCTAssertNil(notice.message)
        notice.raise(editFailure)
        XCTAssertEqual(notice.message, editFailure)
    }

    /// 反向守卫：连续两次失败只显示最新一条，不叠加、不留最旧的。
    func testOnlyTheLatestFailureIsShown() {
        let notice = NodeNotice()
        notice.raise(deleteFailure)
        notice.raise(editFailure)
        XCTAssertEqual(notice.message, editFailure)
    }
}
