import AppKit
import Darwin
import Foundation

extension HomebrewUpdateController {
    static func makeLive() -> HomebrewUpdateController {
        let bundle = Bundle.main
        let bundlePath = bundle.bundleURL.path
        let currentPID = Int(ProcessInfo.processInfo.processIdentifier)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = support.appendingPathComponent("azooKey Tree/HomebrewUpdates", isDirectory: true)
        return HomebrewUpdateController(
            storage: HomebrewUpdateStorage(root: root),
            environment: Environment(
                helperURL: { bundle.url(forResource: "HomebrewUpdate", withExtension: "command") },
                bundlePath: bundlePath,
                currentPID: currentPID,
                makeRequest: {
                    HomebrewUpdateRequest(
                        jobID: UUID().uuidString,
                        bundlePath: bundlePath,
                        bundleVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                        parentPID: currentPID,
                        language: Locale.preferredLanguages.first?.hasPrefix("ja") == true ? "ja" : "en"
                    )
                },
                launch: openTerminal,
                processIsRunning: { pid in
                    guard let process = Int32(exactly: pid) else {
                        return false
                    }
                    // Sandbox denial is not evidence that the external helper has exited.
                    return kill(process, 0) == 0 || errno == EPERM
                },
                terminate: { NSApplication.shared.terminate(nil) }
            )
        )
    }

    private static func openTerminal(_ helper: URL, completion: @escaping @MainActor (Error?) -> Void) {
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app", isDirectory: true)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([helper], withApplicationAt: terminal, configuration: configuration) { _, error in
            Task { @MainActor in completion(error) }
        }
    }
}
