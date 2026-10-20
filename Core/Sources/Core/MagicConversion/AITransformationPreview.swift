import Foundation

/// Only the latest completed request may replace selected document text.
public struct AITransformationPreview: Sendable {
    public struct Request: Equatable, Sendable {
        fileprivate let id = UUID()
    }

    private var pendingRequest: Request?
    private var completedText: String?

    public init() {}

    public var isLoading: Bool { pendingRequest != nil }
    public var applicableText: String? { isLoading ? nil : completedText }

    public mutating func begin() -> Request {
        let request = Request()
        pendingRequest = request
        completedText = nil
        return request
    }

    /// Nil and empty responses clear the pending state without becoming applicable.
    @discardableResult
    public mutating func complete(_ text: String?, for request: Request) -> Bool {
        guard pendingRequest == request else {
            return false
        }
        pendingRequest = nil
        completedText = text.flatMap { $0.isEmpty ? nil : $0 }
        return true
    }

    public mutating func invalidate() {
        pendingRequest = nil
        completedText = nil
    }
}
