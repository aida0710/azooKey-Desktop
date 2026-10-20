import Core

/// Shared development-transport bounds; ordinary input does not use this protocol.
enum DesktopWorkerProtocolLimits {
    static let jsonBytes = CompositionSnapshotLimits.jsonByteCount
    static let identifierBytes = 512
    static let contextBytes = 16 * 1024
    static let contexts = 64
    // Match the existing bridge router's surrounding-text window.
    static let surroundingCharacters = 100
}
