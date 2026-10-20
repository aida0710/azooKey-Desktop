#if os(Linux)
import Core
import Foundation
import Testing

final class DesktopDictionaryBridgeFixture {
    let rootURL: URL
    let settingsURL: URL
    let dataURL: URL
    let executableURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("dictionary-bridge-\(UUID().uuidString)")
        settingsURL = rootURL.appendingPathComponent("config/azookey-tree/settings.json")
        dataURL = rootURL.appendingPathComponent("data")
        executableURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/azookey-desktop-bridge")
        try #require(FileManager.default.isExecutableFile(atPath: executableURL.path))
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func stage(settings: [String: Any]) throws -> URL {
        let stage = settingsURL.deletingLastPathComponent().appendingPathComponent(".settings-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]).write(to: stage)
        return stage
    }

    func requestsForCandidates() throws -> [[String: Any]] {
        try Array("tesuto ").map { character in
            let event = KeyEventCore(
                modifierFlags: [], characters: String(character), charactersIgnoringModifiers: String(character),
                keyCode: character == " " ? 49 : 0
            )
            return ["operation": "key", "event": try JSONSerialization.jsonObject(with: JSONEncoder().encode(event))]
        }
    }

    func run(_ requests: [[String: Any]]) throws -> [[String: Any]] {
        let process = Process()
        process.executableURL = executableURL
        var environment = ProcessInfo.processInfo.environment
        environment["XDG_CONFIG_HOME"] = rootURL.appendingPathComponent("config").path
        environment["XDG_DATA_HOME"] = rootURL.appendingPathComponent("xdg-data").path
        environment["AZOOKEY_DATA_DIR"] = dataURL.path
        environment["AZOOKEY_RESOURCES"] = nil
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Bound a broken child protocol; this is not used to order successful requests.
        let processTimeout: TimeInterval = 30
        let stopUnresponsiveProcess = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + processTimeout, execute: stopUnresponsiveProcess
        )
        defer {
            stopUnresponsiveProcess.cancel()
            if process.isRunning {
                process.terminate()
            }
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
        }
        let lines = try requests.map {
            try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) + Data("\n".utf8)
        }
        try input.fileHandleForWriting.write(contentsOf: lines.reduce(into: Data()) { $0.append($1) })
        try input.fileHandleForWriting.close()
        let responseContent = try output.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        let responses = try responseContent.split(separator: UInt8(ascii: "\n")).map {
            try #require(try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
        try #require(responses.count == requests.count)
        return responses
    }
}
#endif
