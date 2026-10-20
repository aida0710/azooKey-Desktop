@testable import Core
import Foundation
import Testing

@Suite("複数の辞書設定の保存")
struct UserDictionaryPersistenceTests {
    @Test("全設定を先に記録し順番に保存してから変換器へ反映する")
    func combinedPersistenceCapturesEverythingBeforeWriting() async throws {
        let fixture = try DictionaryTransactionFixture()
        let probe = DictionaryPersistenceProbe()
        let persistence = UserDictionaryPersistence.combining([
            await probe.persistence(name: "config"),
            await probe.persistence(name: "json")
        ])
        try await fixture.save(persistence: persistence, activate: { await probe.activate() })
        #expect(await probe.events == [
            "capture-config", "capture-json", "write-config", "write-json", "activate"
        ])
        #expect(await probe.values == ["config": "new", "json": "new"])
    }

    @Test("途中の保存と複数の復元が失敗しても全設定を逆順で復元する")
    func failedCombinedWriteAttemptsEveryRestoreAndReportsAllFailures() async throws {
        let fixture = try DictionaryTransactionFixture()
        let previousFiles = try fixture.files()
        let probe = DictionaryPersistenceProbe()
        let persistence = UserDictionaryPersistence.combining([
            await probe.persistence(name: "config", failRestore: true),
            await probe.persistence(name: "json", failWrite: true),
            await probe.persistence(name: "other", failRestore: true)
        ])
        do {
            try await fixture.save(persistence: persistence)
            Issue.record("A combined persistence failure was reported as success")
        } catch let error as UserDictionarySaveError {
            #expect(error.underlying as? DictionaryTestFailure == .persistence)
            let rollback = try #require(error.rollbackFailures.first)
            #expect(rollback.phase == .settings)
            let failures = try #require(rollback.underlying as? UserDictionaryPersistence.RestorationErrors)
            #expect(failures.errors.count == 2)
        }
        #expect(await probe.events == [
            "capture-config", "capture-json", "capture-other",
            "write-config", "write-json", "restore-other", "restore-json", "restore-config"
        ])
        #expect(await probe.values == ["config": "old", "json": "old", "other": "old"])
        #expect(try fixture.files() == previousFiles)
    }
}

private actor DictionaryPersistenceProbe {
    private(set) var events: [String] = []
    private(set) var values: [String: String] = [:]

    func persistence(name: String, failWrite: Bool = false, failRestore: Bool = false) -> UserDictionaryPersistence {
        self.values[name] = "old"
        return UserDictionaryPersistence {
            let previous = await self.capture(name: name)
            return .init(
                write: { try await self.write(name: name, fail: failWrite) },
                restore: { try await self.restore(name: name, value: previous, fail: failRestore) }
            )
        }
    }

    func activate() {
        self.events.append("activate")
    }

    private func capture(name: String) -> String? {
        self.events.append("capture-\(name)")
        return self.values[name]
    }

    private func write(name: String, fail: Bool) throws {
        self.events.append("write-\(name)")
        self.values[name] = "new"
        if fail {
            throw DictionaryTestFailure.persistence
        }
    }

    private func restore(name: String, value: String?, fail: Bool) throws {
        self.events.append("restore-\(name)")
        self.values[name] = value
        if fail {
            throw DictionaryTestFailure.settingsRollback
        }
    }
}
