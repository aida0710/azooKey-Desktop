import Foundation
import XCTest

@testable import azooKeyMac

@MainActor
final class HomebrewUpdateControllerTests: XCTestCase {
    func testStartingLaunchesOnlyTheBundledHelperAndBlocksAnotherStart() {
        let fixture = Fixture()
        let controller = fixture.controller()
        controller.start()
        controller.start()
        XCTAssertEqual(fixture.storage.preparedRequests, [fixture.request])
        XCTAssertEqual(fixture.launchedURLs, [fixture.helperURL])
        XCTAssertTrue(controller.isBusy)
        XCTAssertEqual(controller.messageKey, "support.update.launching")
        XCTAssertEqual(fixture.terminationCount, 0)
    }

    func testOnlyVerifiedNewerUpdateRequestsNormalTerminationOnce() throws {
        let fixture = Fixture()
        let controller = fixture.controller()
        controller.start()
        fixture.storage.status = try fixture.status(phase: "updated", installed: "0.2.0", target: "0.2.0")
        controller.poll()
        controller.poll()
        XCTAssertEqual(fixture.terminationCount, 1)
        XCTAssertTrue(controller.isBusy)
        fixture.storage.status = try fixture.status(phase: "restarted", installed: "0.2.0", target: "0.2.0")
        controller.poll()
        XCTAssertEqual(fixture.terminationCount, 1)
        XCTAssertTrue(controller.canStart)
    }

    func testRestoringAnUpdatedJobNeverTerminatesTheNewIMEEvenWithAReusedParentPID() throws {
        let fixture = Fixture()
        fixture.storage.savedJob = fixture.job
        fixture.storage.started = true
        fixture.storage.status = try fixture.status(phase: "updated", installed: "0.2.0", target: "0.2.0")
        let controller = fixture.controller()
        controller.poll()
        XCTAssertEqual(controller.messageKey, "support.update.updated")
        XCTAssertEqual(fixture.terminationCount, 0)
        XCTAssertTrue(fixture.launchedURLs.isEmpty)
    }

    func testAnotherJobChangedPIDOrBackwardPhaseCannotTriggerTermination() throws {
        let fixture = Fixture()
        let controller = fixture.controller()
        controller.start()
        fixture.storage.status = try fixture.status(phase: "updating")
        controller.poll()
        let invalidDocuments = [
            try fixture.status(phase: "updated", installed: "0.2.0", target: "0.2.0", jobID: UUID().uuidString),
            try fixture.status(phase: "updated", installed: "0.2.0", target: "0.2.0", helperPID: 999),
            try fixture.status(phase: "checking")
        ]
        for document in invalidDocuments {
            fixture.storage.status = document
            controller.poll()
            XCTAssertEqual(controller.messageKey, "support.update.failure.invalidStatus")
            XCTAssertFalse(controller.canStart)
            XCTAssertEqual(fixture.terminationCount, 0)
        }
    }

    func testMalformedUnchangedDowngradedOrMismatchedVersionsCannotTriggerTermination() throws {
        let fixture = Fixture()
        let documents = [
            Data("not JSON".utf8),
            try fixture.status(phase: "updated", installed: "0.1.2", target: "0.1.2"),
            try fixture.status(phase: "updated", installed: "0.1.1", target: "0.1.1"),
            try fixture.status(phase: "updated", installed: "0.2.0", target: "0.3.0"),
            try fixture.status(phase: "updated", installed: "0.2.0-rc.1", target: "0.2.0-rc.1"),
            try fixture.status(phase: "updated", installed: "00.2.0", target: "00.2.0"),
            try fixture.status(phase: "updated", installed: "0.2.0", target: "0.2.0", helperPID: fixture.request.parentPID),
            try fixture.status(phase: "failed", code: "password=do-not-display")
        ]
        for document in documents {
            let controller = fixture.controller()
            controller.start()
            fixture.storage.status = document
            controller.poll()
            XCTAssertEqual(controller.messageKey, "support.update.failure.invalidStatus")
            XCTAssertFalse(controller.canStart)
            XCTAssertEqual(fixture.terminationCount, 0)
            fixture.storage.savedJob = nil
            fixture.storage.status = nil
        }
    }

    func testUpToDateAndHelperFailureRemainDifferentFromAConfirmedUpdate() throws {
        let fixture = Fixture()
        let controller = fixture.controller()
        controller.start()
        fixture.storage.status = try fixture.status(phase: "upToDate", installed: "0.1.2", target: "0.1.2")
        controller.poll()
        XCTAssertEqual(controller.messageKey, "support.update.upToDate")
        XCTAssertTrue(controller.canStart)
        controller.start()
        fixture.storage.status = try fixture.status(phase: "failed", code: "unmanaged")
        controller.poll()
        XCTAssertEqual(controller.messageKey, "support.update.failure.unmanaged")
        XCTAssertTrue(controller.canStart)
        XCTAssertEqual(fixture.terminationCount, 0)
    }

    func testRefreshingMetadataCanFinishUpToDateWithoutRequestingTermination() throws {
        let fixture = Fixture()
        let controller = fixture.controller()
        controller.start()
        for phase in ["checking", "updating"] {
            fixture.storage.status = try fixture.status(phase: phase)
            controller.poll()
            XCTAssertEqual(controller.messageKey, "support.update." + phase)
            XCTAssertFalse(controller.canStart)
        }
        fixture.storage.status = try fixture.status(phase: "upToDate", installed: "0.1.2", target: "0.1.2")
        controller.poll()
        XCTAssertEqual(controller.messageKey, "support.update.upToDate")
        XCTAssertTrue(controller.canStart)
        XCTAssertEqual(fixture.terminationCount, 0)
    }

    func testAStoppedHelperReportsInterruptionAndPreservesThePreviousFailure() throws {
        let fixture = Fixture()
        let controller = fixture.controller()
        controller.start()
        fixture.storage.started = true
        fixture.storage.status = try fixture.status(phase: "updating")
        fixture.helperIsRunning = false
        controller.poll()
        XCTAssertEqual(controller.messageKey, "support.update.failure.interrupted")
        XCTAssertTrue(controller.canStart)
        let restored = fixture.controller()
        XCTAssertEqual(restored.messageKey, controller.messageKey)
        XCTAssertTrue(restored.canStart)
        XCTAssertEqual(fixture.terminationCount, 0)
    }

    func testAStoppedHelperAfterInstallationReportsRestartFailure() throws {
        let fixture = Fixture()
        let controller = fixture.controller()
        controller.start()
        fixture.storage.status = try fixture.status(phase: "updated", installed: "0.2.0", target: "0.2.0")
        fixture.helperIsRunning = false
        controller.poll()
        XCTAssertEqual(controller.messageKey, "support.update.failure.restartFailed")
        XCTAssertEqual(fixture.terminationCount, 0)
    }

    func testLaunchServicesFailureIsPersistedAndDoesNotClaimTheHelperStarted() {
        let fixture = Fixture()
        let controller = fixture.controller()
        controller.start()
        fixture.completions[0](Fixture.Failure.launch)
        XCTAssertEqual(controller.messageKey, "support.update.failure.launchFailed")
        XCTAssertTrue(controller.canStart)
        let restored = fixture.controller()
        XCTAssertEqual(restored.messageKey, controller.messageKey)
        XCTAssertTrue(restored.canStart)
        XCTAssertEqual(fixture.terminationCount, 0)
    }

    func testLateLaunchFailureDoesNotDisplaceAnAlreadyRunningHelper() throws {
        let fixture = Fixture()
        let controller = fixture.controller()
        controller.start()
        fixture.storage.started = true
        fixture.storage.status = try fixture.status(phase: "checking")
        fixture.completions[0](Fixture.Failure.launch)
        XCTAssertEqual(controller.messageKey, "support.update.checking")
        XCTAssertFalse(controller.canStart)
    }

    func testWaitingForTerminalReopensTheSameJobWithoutCreatingAnotherRequest() {
        let fixture = Fixture()
        let controller = fixture.controller()
        controller.start()
        fixture.currentDate = fixture.job.createdAt.addingTimeInterval(HomebrewUpdateController.startupNoticeDelay + 1)
        controller.poll()
        XCTAssertEqual(controller.messageKey, "support.update.waitingForTerminal")
        XCTAssertTrue(controller.canReopenTerminal)
        controller.start()
        controller.reopenTerminal()
        XCTAssertEqual(fixture.storage.preparedRequests.count, 1)
        XCTAssertEqual(fixture.launchedURLs, [fixture.helperURL, fixture.helperURL])
        fixture.completions[1](Fixture.Failure.launch)
        XCTAssertFalse(controller.canStart)
        XCTAssertTrue(controller.canReopenTerminal)
        fixture.completions[0](Fixture.Failure.launch)
        XCTAssertFalse(controller.canStart)
        let restored = fixture.controller()
        XCTAssertFalse(restored.canStart)
        XCTAssertEqual(restored.messageKey, "support.update.waitingForTerminal")
        XCTAssertEqual(fixture.terminationCount, 0)
    }

    func testReopeningRefusesAChangedLatestRequest() {
        let fixture = Fixture()
        let controller = fixture.controller()
        controller.start()
        fixture.currentDate = fixture.job.createdAt.addingTimeInterval(HomebrewUpdateController.startupNoticeDelay + 1)
        controller.poll()
        fixture.storage.savedJob = nil
        controller.reopenTerminal()
        XCTAssertEqual(fixture.launchedURLs.count, 1)
        XCTAssertEqual(controller.messageKey, "support.update.failure.changedInstallation")
        XCTAssertFalse(controller.canStart)
    }

    func testPreparationFailureDoesNotLaunchTerminal() {
        let fixture = Fixture()
        fixture.storage.preparationFails = true
        let controller = fixture.controller()
        controller.start()
        XCTAssertEqual(controller.messageKey, "support.update.failure.preparationFailed")
        XCTAssertTrue(controller.canStart)
        XCTAssertTrue(fixture.launchedURLs.isEmpty)
    }

    func testRestoredUpToDateIsLabeledAsPreviousUntilTheUserStartsAnotherCheck() throws {
        let fixture = Fixture()
        fixture.storage.savedJob = fixture.job
        fixture.storage.status = try fixture.status(phase: "upToDate", installed: "0.1.2", target: "0.1.2")
        let controller = fixture.controller()
        XCTAssertEqual(controller.messageKey, "support.update.upToDate")
        XCTAssertTrue(controller.isPreviousResult)
        XCTAssertTrue(fixture.launchedURLs.isEmpty)
        controller.start()
        XCTAssertFalse(controller.isPreviousResult)
        XCTAssertEqual(controller.messageKey, "support.update.launching")
        XCTAssertEqual(fixture.launchedURLs.count, 1)
    }

    func testNumericVersionComparisonAndStableVersionRestrictions() throws {
        XCTAssertLessThan(try XCTUnwrap(HomebrewUpdateVersion("0.9.0")), try XCTUnwrap(HomebrewUpdateVersion("0.10.0")))
        for invalid in ["1.0", "1.2.3.4", "v1.2.3", "1.2.3-beta", "01.2.3", "１.2.3", "1..3"] {
            XCTAssertNil(HomebrewUpdateVersion(invalid))
        }
    }

    @MainActor
    private final class Fixture {
        enum Failure: Error { case launch }
        let request = HomebrewUpdateRequest(jobID: "FD596154-0064-4992-AFAD-23B82904546D", bundlePath: "/Applications/azooKeyMac.app", bundleVersion: "0.1.2", parentPID: 100, language: "ja")
        let helperURL = URL(fileURLWithPath: "/Applications/azooKeyMac.app/Contents/Resources/HomebrewUpdate.command")
        let storage = FakeStorage()
        var launchedURLs: [URL] = []
        var completions: [@MainActor (Error?) -> Void] = []
        var terminationCount = 0
        var helperIsRunning = true
        var currentDate = Date(timeIntervalSince1970: 100)
        var job: HomebrewUpdateJob {
            HomebrewUpdateJob(request: request, directory: URL(fileURLWithPath: "/private/test/" + request.jobID), createdAt: Date(timeIntervalSince1970: 100))
        }

        func controller() -> HomebrewUpdateController {
            storage.preparedJob = job
            return HomebrewUpdateController(
                storage: storage,
                environment: .init(
                    helperURL: { self.helperURL }, bundlePath: request.bundlePath,
                    currentPID: request.parentPID, makeRequest: { self.request },
                    launch: {
                        self.launchedURLs.append($0)
                        self.completions.append($1)
                    },
                    processIsRunning: { _ in self.helperIsRunning }, terminate: { self.terminationCount += 1 },
                    now: { self.currentDate }
                ),
                automaticallyPoll: false
            )
        }

        func status(phase: String, code: String = "", installed: String = "", target: String = "", jobID: String? = nil, helperPID: Int = 200) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "jobID": jobID ?? request.jobID, "phase": phase, "code": code,
                "installedVersion": installed, "targetVersion": target, "helperPID": helperPID
            ])
        }
    }

    @MainActor
    private final class FakeStorage: HomebrewUpdateStoring {
        enum Failure: Error { case prepare }
        var savedJob: HomebrewUpdateJob?
        var preparedJob: HomebrewUpdateJob?
        var preparedRequests: [HomebrewUpdateRequest] = []
        var status: Data?
        var started = false
        var failure: HomebrewUpdateFailure?
        var preparationFails = false

        func prepare(_ request: HomebrewUpdateRequest) throws -> HomebrewUpdateJob {
            guard !preparationFails, let preparedJob else {
                throw Failure.prepare
            }
            preparedRequests.append(request)
            savedJob = preparedJob
            failure = nil
            return preparedJob
        }
        func restore() throws -> HomebrewUpdateJob? { savedJob }
        func readStatus(for job: HomebrewUpdateJob) throws -> Data? { status }
        func hasStarted(_ job: HomebrewUpdateJob) throws -> Bool { started }
        func readFailure(for job: HomebrewUpdateJob) throws -> HomebrewUpdateFailure? { failure }
        func recordFailure(_ failure: HomebrewUpdateFailure, for job: HomebrewUpdateJob) throws { self.failure = failure }
    }
}
