import Cocoa
import Core

/// An explicit allowlist: never serialize preferences, document clients or history.
enum SupportDiagnostics {
    static func current(bundle: Bundle = .main) -> String {
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = Localization.text("support.unknown")
        #endif
        let unknown = Localization.text("support.unknown")
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let backend = bundle.object(forInfoDictionaryKey: "AzooKeyInferenceBackend") as? String
        let tree = Config.TreeCandidates().value
        let fields = [
            ("support.version", version ?? PackageMetadata.gitTag ?? unknown),
            ("support.source", PackageMetadata.gitCommit ?? unknown),
            ("support.os", ProcessInfo.processInfo.operatingSystemVersionString),
            ("support.cpu", architecture),
            ("support.backend", backend ?? unknown),
            ("support.session", "AppKit"),
            ("support.renderer", Localization.text(tree ? "support.renderer.mac-tree" : "support.renderer.mac-list")),
            ("support.fallback", Localization.text(tree ? "support.none" : "support.fallback.setting"))
        ]
        return (["azooKey Tree"] + fields.map { "\(Localization.text($0.0)): \($0.1)" }).joined(separator: "\n")
    }
}
