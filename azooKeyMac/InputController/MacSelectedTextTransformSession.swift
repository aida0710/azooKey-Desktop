import Core
import Foundation
import InputMethodKit

/// Waits for an IMK activation before applying a confirmed transformation to
/// the captured selection.
@MainActor
final class MacSelectedTextTransformSession {
    struct Application {
        let restoreFocus: () -> Bool
        let isActive: () -> Bool
    }

    private struct Pending {
        let id = UUID()
        let target: SelectedTextReplacement
        let transformation: AISelectedTextTransformation
        let application: Application
        let completion: (Bool) -> Void
    }

    static let shared = MacSelectedTextTransformSession()
    // A missing activation fails closed; this deadline never initiates a write.
    private static let focusRestorationTimeoutNanoseconds: UInt64 = 5_000_000_000
    private var activeClient: IMKTextInput?
    private(set) var focusRevision = 0
    private var pending: Pending?
    private var deadline: Task<Void, Never>?

    func isActive(client: IMKTextInput) -> Bool {
        activeClient.map { ObjectIdentifier($0) == ObjectIdentifier(client) } == true
    }

    func activate(client: IMKTextInput) {
        activeClient = client
        focusRevision += 1
        scheduleApplication()
    }

    func deactivate(client: IMKTextInput) {
        guard isActive(client: client) else {
            return
        }
        activeClient = nil
        focusRevision += 1
    }

    func cancel(target: SelectedTextReplacement) {
        target.cancel()
        guard pending?.target === target else {
            return
        }
        pending = nil
        deadline?.cancel()
        deadline = nil
    }

    func apply(target: SelectedTextReplacement, transformation: AISelectedTextTransformation, application: Application,
               completion: @escaping (Bool) -> Void) {
        if let previous = pending { cancel(target: previous.target) }
        let request = Pending(target: target, transformation: transformation, application: application, completion: completion)
        pending = request
        deadline = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.focusRestorationTimeoutNanoseconds)
            } catch { return }
            self?.reject(requestID: request.id)
        }
        guard application.restoreFocus() else {
            reject(requestID: request.id)
            return
        }
        if application.isActive(), activeClient.map({ ObjectIdentifier($0) }) == target.clientIdentity {
            scheduleApplication()
        }
    }

    private func scheduleApplication() {
        guard let request = pending else {
            return
        }
        let revision = focusRevision
        // Leave activateServer before making synchronous calls into the editor.
        Task { @MainActor [weak self] in
            self?.complete(requestID: request.id, focusRevision: revision)
        }
    }

    private func complete(requestID: UUID, focusRevision: Int) {
        guard let request = pending, request.id == requestID else {
            return
        }
        guard self.focusRevision == focusRevision, let activeClient else {
            reject(requestID: requestID)
            return
        }
        pending = nil
        deadline?.cancel()
        deadline = nil
        let client = MacSelectedTextClient(client: activeClient, focus: self, applicationIsActive: request.application.isActive)
        guard let replacement = Self.confirmedReplacement(request.transformation, client: client) else {
            request.target.cancel()
            request.completion(false)
            return
        }
        do {
            try request.target.apply(replacement, to: client)
            request.completion(true)
        } catch {
            request.completion(false)
        }
    }

    /// Core decides from fresh reads of the focused client whether the
    /// confirmed result may replace the original selection.
    private static func confirmedReplacement(_ confirmed: AISelectedTextTransformation, client: MacSelectedTextClient) -> String? {
        var transformation = confirmed
        let field = client.aiTextField()
        guard transformation.checkReturn(to: field) else {
            return nil
        }
        return transformation.takeReplacement(for: field, witness: client.aiSelectionWitness())
    }

    private func reject(requestID: UUID) {
        guard let request = pending, request.id == requestID else {
            return
        }
        cancel(target: request.target)
        request.completion(false)
    }
}
