import Foundation

extension DesktopReadingWorker {
    static func run(output: FileHandle) throws {
        var worker = Self()
        var input = DesktopWorkerJSONLReader(descriptor: FileHandle.standardInput.fileDescriptor)
        while let frame = try input.next() {
            let response: DesktopReadingWorkerResponse
            do {
                guard case .json(let bytes) = frame else { throw DesktopReadingProtocolFailure.requestLimit }
                let request = try JSONDecoder().decode(DesktopReadingWorkerRequest.self, from: bytes)
                response = try worker.process(request)
            } catch {
                response = worker.rejected(error)
            }
            var encoded = try JSONEncoder().encode(response)
            encoded.append(0x0a)
            try output.write(contentsOf: encoded)
        }
    }
}
