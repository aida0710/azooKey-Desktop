import Foundation
import Core
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

struct BridgeRequest: Decodable {
    var operation: String
    var event: KeyEventCore?
    var index: Int?
    var node: Int?
    var generation: Int?
    var submit: Bool?
    var leftContext: String?
    var rightContext: String?
}

@main
struct BridgeMain {
    @MainActor
    static func main() throws {
        // Keep converter debug output (which can contain typed text) out of both
        // the protocol and logs. The private pipe is the only output channel.
        let responseFD = dup(STDOUT_FILENO)
        guard responseFD >= 0 else { return }
        let output = FileHandle(fileDescriptor: responseFD, closeOnDealloc: true)
        let nullFD = open("/dev/null", O_WRONLY)
        guard nullFD >= 0 else { return }
        dup2(nullFD, STDOUT_FILENO)
        dup2(nullFD, STDERR_FILENO)
        close(nullFD)
        let environment = ProcessInfo.processInfo.environment
        let dataPath = environment["AZOOKEY_DATA_DIR"] ??
            (environment["XDG_DATA_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share").path) + "/azookey-tree"
        let resources = environment["AZOOKEY_RESOURCES"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let zenzai = resources.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("ggml-model-Q5_K_M.gguf").path) } ?? false
        let session = try DesktopSession(dataDirectory: URL(fileURLWithPath: dataPath), resourcesDirectory: resources, useZenzai: zenzai)
        defer { session.close() }
        while let line = readLine() {
            var response: DesktopSnapshot
            do {
                let request = try JSONDecoder().decode(BridgeRequest.self, from: Data(line.utf8))
                session.leftContext = String((request.leftContext ?? "").suffix(100))
                session.rightContext = String((request.rightContext ?? "").prefix(100))
                switch request.operation {
                case "key":
                    guard let event = request.event else { throw ProtocolError.invalidRequest }
                    response = session.key(event)
                case "select":
                    guard let index = request.index, let generation = request.generation else { throw ProtocolError.invalidRequest }
                    response = session.select(candidateIndex: index, submit: request.submit ?? false, expectedGeneration: generation)
                case "node":
                    guard let node = request.node, let generation = request.generation else { throw ProtocolError.invalidRequest }
                    response = session.selectNode(node, submit: request.submit ?? false, expectedGeneration: generation)
                case "reset": response = session.reset(commit: request.submit ?? false)
                case "snapshot": response = session.snapshot()
                default: throw ProtocolError.invalidRequest
                }
            } catch {
                response = DesktopSnapshot()
                response.consumed = false
                response.error = "invalid_request"
            }
            var data = try JSONEncoder().encode(response)
            data.append(0x0a)
            try output.write(contentsOf: data)
        }
    }
    enum ProtocolError: Error { case invalidRequest }
}
