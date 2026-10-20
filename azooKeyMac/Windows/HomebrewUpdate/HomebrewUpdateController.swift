import Combine
import Foundation

@MainActor
final class HomebrewUpdateController: ObservableObject {
    typealias Launcher = (URL, @escaping @MainActor (Error?) -> Void) -> Void

    struct Environment {
        let helperURL: () -> URL?
        let bundlePath: String
        let currentPID: Int
        let makeRequest: () -> HomebrewUpdateRequest
        let launch: Launcher
        let processIsRunning: (Int) -> Bool
        let terminate: () -> Void
        var now: () -> Date = Date.init
    }

    static let shared = HomebrewUpdateController.makeLive()
    // File IPC has no callback from Terminal; poll without treating elapsed time as success.
    static let pollingInterval: TimeInterval = 1
    static let startupNoticeDelay: TimeInterval = 30

    @Published private(set) var messageKey: String?
    @Published private(set) var isBusy = false
    @Published private(set) var isWaitingForTerminal = false
    @Published private(set) var isPreviousResult = false
    var canStart: Bool { !isBusy }
    var canReopenTerminal: Bool { isBusy && isWaitingForTerminal && previousStatus == nil && activeJob != nil }

    private let storage: any HomebrewUpdateStoring
    private let helperURL: () -> URL?
    private let makeRequest: () -> HomebrewUpdateRequest
    private let launch: Launcher
    private let processIsRunning: (Int) -> Bool
    private let terminate: () -> Void
    private let now: () -> Date
    private let bundlePath: String
    private let currentPID: Int
    private let automaticallyPoll: Bool
    private var activeJob: HomebrewUpdateJob?
    private var previousStatus: HomebrewUpdateStatus?
    private var ownsTermination = false
    private var terminationRequested = false
    private var hasReopenedTerminal = false
    private var timer: Timer?

    init(
        storage: any HomebrewUpdateStoring,
        environment: Environment,
        automaticallyPoll: Bool = true
    ) {
        self.storage = storage
        self.helperURL = environment.helperURL
        self.bundlePath = environment.bundlePath
        self.currentPID = environment.currentPID
        self.makeRequest = environment.makeRequest
        self.launch = environment.launch
        self.processIsRunning = environment.processIsRunning
        self.terminate = environment.terminate
        self.now = environment.now
        self.automaticallyPoll = automaticallyPoll
        restorePreviousJob()
    }

    func start() {
        guard canStart else {
            return
        }
        isPreviousResult = false
        let request = makeRequest()
        guard request.isValid, request.bundlePath == bundlePath, request.parentPID == currentPID else {
            messageKey = HomebrewUpdateFailure.unsupported.messageKey
            return
        }
        guard let executable = helperURL() else {
            messageKey = HomebrewUpdateFailure.preparationFailed.messageKey
            return
        }
        let job: HomebrewUpdateJob
        do {
            job = try storage.prepare(request)
        } catch {
            messageKey = HomebrewUpdateFailure.preparationFailed.messageKey
            return
        }
        activeJob = job
        previousStatus = nil
        ownsTermination = true
        terminationRequested = false
        hasReopenedTerminal = false
        isBusy = true
        isWaitingForTerminal = false
        messageKey = "support.update.launching"
        beginMonitoring()
        launchHelper(executable, job: job, canReleaseReservation: true)
    }

    func reopenTerminal() {
        guard canReopenTerminal, let job = activeJob else {
            return
        }
        do {
            guard try storage.restore()?.request == job.request, let executable = helperURL() else {
                fail(.changedInstallation, job: job, keepMonitoring: true)
                return
            }
            hasReopenedTerminal = true
            launchHelper(executable, job: job, canReleaseReservation: false)
        } catch {
            fail(.invalidStatus, job: job, keepMonitoring: true)
        }
    }

    private func launchHelper(_ executable: URL, job: HomebrewUpdateJob, canReleaseReservation: Bool) {
        launch(executable) { [weak self] error in
            guard let self, self.activeJob?.request.jobID == job.request.jobID else {
                return
            }
            if error != nil {
                self.handleLaunchFailure(job, canReleaseReservation: canReleaseReservation)
            } else {
                self.poll()
            }
        }
    }

    func poll() {
        guard let job = activeJob, isBusy else {
            return
        }
        do {
            guard let document = try storage.readStatus(for: job) else {
                handleMissingStatus(job)
                return
            }
            let status = try JSONDecoder().decode(HomebrewUpdateStatus.self, from: document)
            guard status.isValid(for: job.request, previous: previousStatus) else {
                rejectStatus(job)
                return
            }
            previousStatus = status
            isWaitingForTerminal = false
            if !status.phase.isFinished && !processIsRunning(status.helperPID) {
                let failure: HomebrewUpdateFailure = [.updated, .restarting].contains(status.phase) ? .restartFailed : .interrupted
                fail(failure, job: job, keepMonitoring: false)
                return
            }
            messageKey = status.messageKey
            isBusy = !status.phase.isFinished
            if !isBusy {
                stopMonitoring()
            }
            // A restored job belongs to the old process. Never terminate the new IME again.
            if status.phase == .updated, ownsTermination, job.request.parentPID == currentPID, !terminationRequested {
                terminationRequested = true
                terminate()
            }
        } catch {
            rejectStatus(job)
        }
    }

    private func restorePreviousJob() {
        do {
            guard let job = try storage.restore() else {
                return
            }
            isPreviousResult = true
            guard job.request.bundlePath == bundlePath else {
                messageKey = HomebrewUpdateFailure.changedInstallation.messageKey
                isBusy = true
                return
            }
            activeJob = job
            ownsTermination = false
            if let failure = try storage.readFailure(for: job), failure == .launchFailed, try !storage.hasStarted(job) {
                messageKey = failure.messageKey
                return
            }
            isBusy = true
            messageKey = "support.update.checking"
            poll()
            if isBusy {
                beginMonitoring()
            }
        } catch {
            // Unknown persisted state must not permit a second concurrent updater.
            isPreviousResult = true
            messageKey = HomebrewUpdateFailure.invalidStatus.messageKey
            isBusy = true
        }
    }

    private func handleLaunchFailure(_ job: HomebrewUpdateJob, canReleaseReservation: Bool) {
        // A helper that already wrote a status remains authoritative even if Launch Services failed late.
        if (try? storage.readStatus(for: job)) != nil {
            poll()
            return
        }
        let mayHaveStarted = hasReopenedTerminal || !canReleaseReservation || ((try? storage.hasStarted(job)) ?? true)
        isWaitingForTerminal = mayHaveStarted
        fail(.launchFailed, job: job, keepMonitoring: mayHaveStarted)
    }

    private func handleMissingStatus(_ job: HomebrewUpdateJob) {
        if let previousStatus, !processIsRunning(previousStatus.helperPID) {
            fail(.interrupted, job: job, keepMonitoring: false)
        } else if now().timeIntervalSince(job.createdAt) >= Self.startupNoticeDelay {
            // A delayed Terminal launch can still start. Keep the reservation until its PID/result is known.
            isWaitingForTerminal = true
            messageKey = "support.update.waitingForTerminal"
        }
    }

    private func rejectStatus(_ job: HomebrewUpdateJob) {
        let helperMayBeRunning = previousStatus.map { processIsRunning($0.helperPID) } ?? true
        isWaitingForTerminal = previousStatus == nil
        fail(.invalidStatus, job: job, keepMonitoring: helperMayBeRunning)
    }

    private func fail(_ failure: HomebrewUpdateFailure, job: HomebrewUpdateJob, keepMonitoring: Bool) {
        if !keepMonitoring, messageKey != failure.messageKey {
            try? storage.recordFailure(failure, for: job)
        }
        messageKey = failure.messageKey
        isBusy = keepMonitoring
        if !keepMonitoring {
            stopMonitoring()
        }
    }

    private func beginMonitoring() {
        guard automaticallyPoll, timer == nil else {
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
    }

    private func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }
}
