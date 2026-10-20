import Cocoa
import Core
import InputMethodKit

@testable import azooKeyMac

/// Uses the production initializer and actions with an in-process text client.
@MainActor
@objc(InputMethodTestController)
final class InputMethodTestController: azooKeyMacInputController {
    var activeClient: (any IMKTextInput & NSObjectProtocol)?

    init?(server: IMKServer, client: any IMKTextInput & NSObjectProtocol, segmentsManager: SegmentsManager) {
        activeClient = client
        // IMK rejects an ordinary NSObject as its transport proxy. Its public
        // nil-client initializer works; actions obtain the test client below.
        super.init(server: server, delegate: nil, client: nil, segmentsManager: segmentsManager)
    }

    override func client() -> (any IMKTextInput & NSObjectProtocol)! {
        activeClient
    }
}
