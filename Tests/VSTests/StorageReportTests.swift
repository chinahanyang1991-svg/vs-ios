import XCTest
@testable import VS

// 关于页的「数据存储」要替用户回答两件事：文件在哪个目录、里面到底是不是加密的。
// 这两句一错就是拿界面糊人，所以口径必须由能红的判据钉住。
final class StorageReportTests: XCTestCase {
    private let fileURL = URL(fileURLWithPath: "/private/var/containers/Shared/AppGroup/group.com.vs.app/vs-config.json")
    private let containerPath = "/private/var/containers/Shared/AppGroup/group.com.vs.app"

    func testReportNamesTheActualFileAndContainer() throws {
        let report = ConfigStore.storageReport(storeURL: fileURL, cipher: testConfigCipher, keyFailure: nil)
        XCTAssertEqual(report.fileName, "vs-config.json", "配置文件名要照实说")
        XCTAssertEqual(report.containerPath, containerPath,
                       "容器路径只能取自 storeURL，不许写死一句漂亮话糊过去")
    }

    func testReportSaysEnvelopeOnlyWhenAKeyExists() throws {
        let report = ConfigStore.storageReport(storeURL: fileURL, cipher: testConfigCipher, keyFailure: nil)
        XCTAssertTrue(report.cipherLabel.contains("AES-GCM"), "有密钥时要说清算法：\(report.cipherLabel)")
        XCTAssertTrue(report.cipherLabel.contains("本机钥匙串"), "要交代密钥在哪：\(report.cipherLabel)")
    }

    func testReportWithoutKeyBlamesTheKeyAndNeverClaimsEncryption() throws {
        let report = ConfigStore.storageReport(storeURL: fileURL, cipher: nil, keyFailure: "钥匙串返回 -34018")
        XCTAssertFalse(report.cipherLabel.contains("AES-GCM"), "拿不到密钥就不能自称加密：\(report.cipherLabel)")
        XCTAssertTrue(report.cipherLabel.contains("-34018"), "状态码要原样进界面，别把它吞成一句「不可用」：\(report.cipherLabel)")
        XCTAssertTrue(report.cipherLabel.contains("未写入"), "要讲清一个字节都没落盘：\(report.cipherLabel)")
    }
}
