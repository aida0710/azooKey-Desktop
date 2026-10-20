import Core
import Foundation
import XCTest

@testable import azooKeyMac

final class SupportDiagnosticsTests: XCTestCase {
    func testReportContainsSystemVersionWithoutProfileOrUnknownPreferences() {
        let profile = Config.ZenzaiProfile()
        let originalProfile = profile.value
        let privateKey = "azookey.support-test.private"
        let originalPrivateValue = UserDefaults.standard.object(forKey: privateKey)
        defer {
            profile.value = originalProfile
            UserDefaults.standard.set(originalPrivateValue, forKey: privateKey)
        }
        profile.value = "PRIVATE_PROFILE"
        UserDefaults.standard.set("PRIVATE_DOCUMENT_DICTIONARY_HISTORY_API_KEY", forKey: privateKey)

        let report = SupportDiagnostics.current()
        XCTAssertTrue(report.contains(ProcessInfo.processInfo.operatingSystemVersionString))
        XCTAssertFalse(report.contains("PRIVATE_"))
        XCTAssertFalse(report.contains(FileManager.default.homeDirectoryForCurrentUser.path))
    }

    func testListChoiceExplainsWhyTheTreeIsNotSelected() {
        let configuration = Config.TreeCandidates()
        let original = configuration.value
        defer { configuration.value = original }
        configuration.value = false
        let report = SupportDiagnostics.current()
        XCTAssertTrue(report.contains(Localization.text("support.renderer.mac-list")))
        XCTAssertTrue(report.contains(Localization.text("support.fallback.setting")))
    }
}
