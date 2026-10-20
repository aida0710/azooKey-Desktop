import Core
import Foundation

extension DesktopCandidateWorker {
    static func run(output: FileHandle, environment: [String: String]) throws {
        let dataPath = environment["AZOOKEY_DATA_DIR"] ??
            (environment["XDG_DATA_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share").path) + "/azookey-tree"
        let resources = environment["AZOOKEY_RESOURCES"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let useZenzai = resources.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("ggml-model-Q5_K_M.gguf").path) } ?? false
        let worker = try Self(directory: URL(fileURLWithPath: dataPath, isDirectory: true), resources: resources, useZenzai: useZenzai)
        defer { worker.shutdown() }
        while let line = readLine() {
            let response: DesktopCandidateWorkerResponse
            do {
                guard line.utf8.count <= CompositionSnapshotLimits.jsonByteCount else { throw DesktopCandidateFailure.invalidRequest }
                let request = try JSONDecoder().decode(DesktopCandidateWorkerRequest.self, from: Data(line.utf8))
                do {
                    response = try worker.process(request)
                } catch {
                    response = worker.rejected(error, authority: request.authority)
                }
            } catch {
                response = worker.rejected(error)
            }
            var encoded = try JSONEncoder().encode(response)
            encoded.append(0x0a)
            try output.write(contentsOf: encoded)
        }
    }
}
