import Foundation
import Testing

@testable import Core

/// A converter stand-in that records every settings value it is given.
@MainActor
private final class RecordingConverter {
    var running: DesktopSettings
    var applied: [DesktopSettings] = []
    var rejects: (DesktopSettings) -> Bool = { _ in false }

    init(running: DesktopSettings) {
        self.running = running
    }

    func apply(_ settings: DesktopSettings) throws {
        applied.append(settings)
        if rejects(settings) {
            throw SyntheticFailure()
        }
        running = settings
    }
}

@MainActor
@Suite("変換器への設定の反映と巻き戻し")
struct DesktopSettingsActivationTests {
    let fixture: DesktopSettingsFixture
    let store: DesktopSettingsFileStore
    private let converter = RecordingConverter(running: DesktopSettingsFixture.known)
    let activation: DesktopSettingsActivation

    init() throws {
        fixture = try DesktopSettingsFixture()
        store = DesktopSettingsFileStore(fileURL: fixture.fileURL)
        let converter = converter
        activation = DesktopSettingsActivation { converter.running }
    }

    private func reload() async -> DesktopSettingsLoad {
        await activation.reload(from: store) { try converter.apply($0) }
    }

    @Test("変わったファイルを一度だけ反映し控えを残す")
    func changedFileIsAppliedOnceAndRemembered() async throws {
        var changed = DesktopSettingsFixture.known
        changed.live = true
        try fixture.write(changed)
        let first = await reload()
        #expect(first.problem == nil)
        #expect(first.values.live)
        #expect(converter.applied.count == 1)
        #expect(try DesktopSettingsDocument.settings(from: Data(contentsOf: fixture.lastGoodURL), over: .defaults) == changed)
        _ = await reload()
        #expect(converter.applied.count == 1)
    }

    @Test("ファイルが無いときと壊れているときは反映せず今の値を返す")
    func missingOrBrokenFileIsNotApplied() async throws {
        #expect(await reload().values == DesktopSettingsFixture.known)
        try fixture.write("{")
        let broken = await reload()
        #expect(broken.problem != nil)
        #expect(broken.values == DesktopSettingsFixture.known)
        #expect(converter.applied.isEmpty)
    }

    @Test("変換器が拒否した版は問題として残し直した版はすぐ反映する")
    func rejectedVersionStaysAProblemUntilRepaired() async throws {
        converter.rejects = { !$0.customTable.isEmpty }
        try fixture.write(#"{"customTable":"synthetic invalid table"}"#)
        #expect(await reload().problem == .init(.engineRejected))
        #expect(await reload().problem == .init(.engineRejected))
        #expect(converter.applied.count == 1)
        try fixture.write(#"{"live":true}"#)
        let repaired = await reload()
        #expect(repaired.problem == nil)
        #expect(repaired.values.live)
    }

    @Test("ファイルを置き換えられなければ変換器を元の値に戻す")
    func failedInstallRestoresThePreviousSettings() async throws {
        var updated = DesktopSettingsFixture.known
        updated.live = true
        let failing = DesktopSettingsFileStore(fileURL: fixture.fileURL, operations: .init(
            writeStagedFile: SystemSettingsFiles.writeStagedFile(_:in:), replaceFile: { _, _ in throw SyntheticFailure() }
        ))
        let problem = await asyncSettingsProblem {
            _ = try await failing.save(updated, expectedStamp: nil) { staged in
                try await activation.publish(updated, stagedFileURL: staged, into: failing) { try converter.apply($0) }
            }
        }
        #expect(problem == .init(.writeFailed))
        #expect(converter.applied.map(\.live) == [true, false])
        #expect(converter.running == DesktopSettingsFixture.known)
        #expect(!FileManager.default.fileExists(atPath: fixture.fileURL.path))
    }

    @Test("置き換えにも元への復元にも失敗したら次の保存は復元から始める")
    func failedPublicationAndFailedRestoreRequireARestoreBeforeAnotherSave() async throws {
        try fixture.write(DesktopSettingsFixture.known)
        let original = try fixture.contents()
        var updated = DesktopSettingsFixture.known
        updated.live = true
        var installs = 0
        let failingInstall = DesktopSettingsFileStore(fileURL: fixture.fileURL, operations: .init(
            writeStagedFile: SystemSettingsFiles.writeStagedFile(_:in:),
            replaceFile: { source, destination in
                // The first replacement installs the settings; the last good copy is the second.
                if destination.lastPathComponent == "settings.json" {
                    throw SyntheticFailure()
                }
                try SystemSettingsFiles.replaceFile(source, to: destination)
            }
        ))
        converter.rejects = { !$0.live }
        let publish = { (store: DesktopSettingsFileStore) in
            try await store.save(updated, expectedStamp: nil) { staged in
                installs += 1
                try await activation.publish(updated, stagedFileURL: staged, into: store) { try converter.apply($0) }
            }
        }
        #expect(await asyncSettingsProblem { _ = try await publish(failingInstall) } == .init(.backendRecoveryFailed))
        #expect(converter.applied.map(\.live) == [true, false])
        #expect(converter.running.live)
        #expect(await asyncSettingsProblem { _ = try await publish(failingInstall) } == .init(.backendRecoveryFailed))
        #expect(converter.applied.map(\.live) == [true, false, false], "Only the pending restore may run on retry")
        #expect(try fixture.contents() == original)
        converter.rejects = { _ in false }
        let saved = try await publish(store)
        #expect(converter.applied.map(\.live) == [true, false, false, false, true])
        #expect(saved.values.live)
        #expect(try fixture.savedSettings().live)
        #expect(installs == 3)
    }

    @Test("このプロセスが保存した版は再読み込みで二度反映しない")
    func savedVersionIsNotAppliedAgainOnReload() async throws {
        var updated = DesktopSettingsFixture.known
        updated.live = true
        let saved = try await store.save(updated, expectedStamp: nil) { staged in
            try await activation.publish(updated, stagedFileURL: staged, into: store) { try converter.apply($0) }
        }
        activation.recordSaved(saved)
        _ = await reload()
        #expect(converter.applied.count == 1)
    }
}
