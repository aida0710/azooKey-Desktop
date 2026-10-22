import Foundation

extension SupportDiagnostics {
    /// Raw values the Windows settings screen reads from its environment.
    /// Core keeps only the values that match the recognized formats below.
    public struct WindowsEnvironment: Codable, Equatable, Sendable {
        public var treeEnabled: Bool
        /// The running Windows version as major.minor.build, such as "10.0.26200".
        public var osVersion: String?
        /// The running system's processor architecture.
        public var machine: String?
        /// The packaged build-info.txt, as `key=value` lines.
        public var buildInfo: String?

        public init(treeEnabled: Bool, osVersion: String?, machine: String?, buildInfo: String?) {
            self.treeEnabled = treeEnabled
            self.osVersion = osVersion
            self.machine = machine
            self.buildInfo = buildInfo
        }
    }

    private static let windowsMachines: Set<String> = ["x64", "x86", "arm64"]

    /// Three dot-separated decimal numbers; anything else is not copied.
    private static func recognizedWindowsVersion(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        let isVersion = components.count == 3 && components.allSatisfy { component in
            !component.isEmpty && component.count <= 6 && component.allSatisfy { $0.isASCII && $0.isNumber }
        }
        return isVersion ? value : nil
    }

    public static func windows(_ environment: WindowsEnvironment) -> Self {
        let build = PackageBuildInfo(parsing: environment.buildInfo ?? "", architectures: PackageBuildInfo.windowsArchitectures)
        let fields = [
            Field(labelKey: "support.version", value: .text(build.version)),
            Field(labelKey: "support.source", value: .text(build.source)),
            Field(labelKey: "support.os", value: .text(recognizedWindowsVersion(environment.osVersion).map { "Windows \($0)" })),
            Field(labelKey: "support.cpu", value: .text(environment.machine.flatMap { windowsMachines.contains($0) ? $0 : nil })),
            Field(labelKey: "support.package-cpu", value: .text(build.architecture)),
            // Windows packages build llama.cpp for the CPU only (build-llama.ps1), as Ubuntu packages do.
            Field(labelKey: "support.backend", value: .text(build.architecture == nil ? nil : "CPU")),
            Field(labelKey: "support.session", value: .text("TSF"))
        ]
        // The text service draws both forms in its own candidate panel; only the setting chooses.
        return .init(fields: fields + rendererFields(renderer: environment.treeEnabled ? .windowsTree : .windowsList,
                                                     fallback: environment.treeEnabled ? nil : .setting))
    }
}
