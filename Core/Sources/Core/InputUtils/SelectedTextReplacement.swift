import Foundation

/// The document operations needed to replace a captured selection.
@MainActor
public protocol SelectedTextClient: AnyObject {
    var identity: ObjectIdentifier { get }
    var isActive: Bool { get }
    var documentLength: Int { get }
    var selectedRange: NSRange { get }
    func readText(in range: NSRange) -> (text: String, actualRange: NSRange)?
    func replaceText(in range: NSRange, with text: String)
}

/// Applies a result once, only to the original client and unchanged selection.
@MainActor
public final class SelectedTextReplacement {
    public enum Failure: Error { case targetChanged }

    public let range: NSRange
    public let text: String
    public var clientIdentity: ObjectIdentifier { originalClient.identity }
    private enum State { case ready, applying, finished }
    // Keep the original client alive so its identity cannot be reused.
    private let originalClient: any SelectedTextClient
    private var state = State.ready

    public init(client: any SelectedTextClient) throws {
        let range = client.selectedRange
        guard Self.isValid(range, documentLength: client.documentLength),
              let selected = client.readText(in: range), selected.actualRange == range,
              selected.text.utf16.count == range.length else {
            throw Failure.targetChanged
        }
        self.range = range
        self.text = selected.text
        self.originalClient = client
    }

    public func cancel() { state = .finished }

    public func matchesDocument(in client: any SelectedTextClient) -> Bool {
        guard state == .ready else {
            return false
        }
        let matches = documentMatches(in: client)
        return matches && state == .ready && client.identity == originalClient.identity && client.selectedRange == range
    }

    private func documentMatches(in client: any SelectedTextClient) -> Bool {
        guard client.identity == originalClient.identity, client.selectedRange == range,
              Self.isValid(range, documentLength: client.documentLength),
              let selected = client.readText(in: range), selected.actualRange == range else {
            return false
        }
        return selected.text.utf8.elementsEqual(text.utf8)
    }

    public func apply(_ replacement: String, to client: any SelectedTextClient) throws {
        guard state == .ready else { throw Failure.targetChanged }
        // Consume before insertion so reentrant callbacks cannot apply twice.
        state = .applying
        defer { state = .finished }
        let matches = client.isActive && documentMatches(in: client)
        guard matches, state == .applying, client.isActive, client.identity == originalClient.identity,
              client.selectedRange == range else {
            throw Failure.targetChanged
        }
        client.replaceText(in: range, with: replacement)
    }

    static func isValid(_ range: NSRange, documentLength: Int) -> Bool {
        range.location != NSNotFound && range.location >= 0 && range.length > 0 &&
            range.location <= documentLength && range.length <= documentLength - range.location
    }
}
