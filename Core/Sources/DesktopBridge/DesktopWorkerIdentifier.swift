/// Opaque transport identities use ASCII so canonical Unicode equality cannot alias fields.
enum DesktopWorkerIdentifier {
    static func isValid(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= DesktopWorkerProtocolLimits.identifierBytes
            && value.utf8.allSatisfy({ (0x21...0x7e).contains($0) })
    }
}
