import Cocoa
import Core

/// Reads the macOS values for Core's allowlisted support report.
enum SupportDiagnostics {
    static func current(bundle: Bundle = .main) -> String {
        #if arch(arm64)
        let architecture: String? = "arm64"
        #elseif arch(x86_64)
        let architecture: String? = "x86_64"
        #else
        let architecture: String? = nil
        #endif
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return Core.SupportDiagnostics.macOS(
            version: version ?? PackageMetadata.gitTag,
            source: PackageMetadata.gitCommit,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            cpu: architecture,
            backend: bundle.object(forInfoDictionaryKey: "AzooKeyInferenceBackend") as? String,
            treeEnabled: Config.TreeCandidates().value
        ).report()
    }
}
