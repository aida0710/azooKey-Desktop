import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Bounds memory before decoding and drains one oversized frame without losing the next request.
struct DesktopWorkerJSONLReader {
    enum Frame { case json(Data), oversized }
    private let descriptor: Int32
    private let limit: Int
    // A pipe read need not fill the chunk; it returns as soon as bytes arrive.
    private static let chunkBytes = 64 * 1024
    private var unread = Data()
    private var frame = Data()
    private var discarding = false
    private var reachedEnd = false

    init(descriptor: Int32, limit: Int = DesktopWorkerProtocolLimits.jsonBytes) {
        self.descriptor = descriptor
        self.limit = limit
    }

    mutating func next() throws -> Frame? {
        while true {
            if let newline = unread.firstIndex(of: 0x0a) {
                append(unread[..<newline])
                unread.removeSubrange(...newline)
                return finish()
            }
            append(unread)
            unread.removeAll(keepingCapacity: true)
            if reachedEnd {
                return frame.isEmpty && !discarding ? nil : finish()
            }
            var bytes = [UInt8](repeating: 0, count: Self.chunkBytes)
            let count = bytes.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            reachedEnd = count == 0
            unread.append(contentsOf: bytes.prefix(count))
        }
    }

    private mutating func append(_ bytes: Data) {
        guard !discarding else {
            return
        }
        guard bytes.count <= limit - frame.count else {
            frame.removeAll(keepingCapacity: false)
            discarding = true
            return
        }
        frame.append(bytes)
    }

    private mutating func finish() -> Frame {
        let completed: Frame = discarding ? .oversized : .json(frame)
        frame = Data()
        discarding = false
        return completed
    }
}
