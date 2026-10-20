@testable import Core
import Foundation
import Testing
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

@Suite("辞書保存の排他")
struct UserDictionarySaveConcurrencyTests {
    // Bound a broken continuation or lock without deciding execution order by sleeping.
    @Test("反映待ち中も別プロセスを排他し次のTaskは保存済み設定を読む", .timeLimit(.minutes(1)))
    func savesRemainSerializedThroughActivation() async throws {
        let fixture = try DictionaryTransactionFixture()
        let activation = DictionaryActivationGate()
        let first = Task {
            try await fixture.save(activate: { await activation.pause() })
        }
        defer {
            first.cancel()
            Task { await activation.release() }
        }
        await activation.waitUntilStarted()
        let locked = try await UserDictionaryFileWorker.perform {
            try dictionaryIsLockedInAnotherProcess(directoryURL: fixture.directoryURL)
        }
        #expect(locked)
        let secondItems = [Config.UserDictionaryEntry(word: "続けて保存する辞書語", reading: "てすと")]
        let nextPersistence = UserDictionaryPersistence {
            #expect(try fixture.savedItems().map(\.id) == fixture.newItems.map(\.id))
            return try await fixture.persistence(items: secondItems).capture()
        }
        let second = Task {
            try await UserDictionarySaveTransaction.save(
                request: .init(
                    items: secondItems, systemItems: [], directoryURL: fixture.directoryURL,
                    charIDFileURL: fixture.characterURL
                ),
                persistence: nextPersistence, activate: {},
                operations: UserDictionaryFileOperations()
            )
        }
        await activation.release()
        _ = try await first.value
        _ = try await second.value
        #expect(try fixture.savedItems().map(\.id) == secondItems.map(\.id))
        #expect(CompiledUserDictionaryStore.hasCompiledDictionary(at: fixture.directoryURL))
    }
}

private actor DictionaryActivationGate {
    private var hasStarted = false
    private var isReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func pause() async {
        self.hasStarted = true
        self.startWaiters.forEach { $0.resume() }
        self.startWaiters.removeAll()
        if !self.isReleased {
            await withCheckedContinuation { self.releaseWaiter = $0 }
        }
    }

    func waitUntilStarted() async {
        if !self.hasStarted {
            await withCheckedContinuation { self.startWaiters.append($0) }
        }
    }

    func release() {
        self.isReleased = true
        self.releaseWaiter?.resume()
        self.releaseWaiter = nil
    }
}

private func dictionaryIsLockedInAnotherProcess(directoryURL: URL) throws -> Bool {
    let canonicalURL = directoryURL.standardizedFileURL.resolvingSymlinksInPath()
    let path = canonicalURL.deletingLastPathComponent()
        .appendingPathComponent(".\(canonicalURL.lastPathComponent).lock").path
    return try path.withCString { path in
        let child = fork()
        guard child >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if child == 0 {
            // After fork use only async-signal-safe C calls, not Foundation or Swift task machinery.
            let descriptor = open(path, O_RDWR)
            if descriptor < 0 {
                _exit(2)
            }
            let blocked = flock(descriptor, LOCK_EX | LOCK_NB) != 0
                && (errno == EWOULDBLOCK || errno == EAGAIN)
            close(descriptor)
            _exit(blocked ? 0 : 1)
        }
        var status: Int32 = 0
        while waitpid(child, &status, 0) < 0 {
            if errno != EINTR {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        return status == 0
    }
}
