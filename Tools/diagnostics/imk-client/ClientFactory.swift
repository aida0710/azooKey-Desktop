// Appended to the unchanged FakeTextInput declaration from the actual tests.
@objc(IMKDiagnosticClientFactory)
public final class IMKDiagnosticClientFactory: NSObject {
    @objc public static func make() -> NSObject {
        FakeTextInput()
    }
}

@MainActor
@objc(IMKNilClientOverrideController)
public final class IMKNilClientOverrideController: IMKInputController {
    private let fixtureClient = FakeTextInput()

    @objc public init?(server: IMKServer) {
        super.init(server: server, delegate: nil, client: nil)
    }

    override public func client() -> (any IMKTextInput & NSObjectProtocol)! {
        fixtureClient
    }
}
