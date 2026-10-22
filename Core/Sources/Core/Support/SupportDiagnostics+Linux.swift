import Foundation

extension SupportDiagnostics {
    /// Raw values the Linux adapter reads from its environment. Core keeps
    /// only the values that match the recognized formats below.
    public struct LinuxEnvironment: Codable, Equatable, Sendable {
        public var treeEnabled: Bool
        /// The engine's RendererStatus reply; `nil` when the engine did not answer.
        public var rendererRegistered: Bool?
        /// `XDG_SESSION_TYPE`.
        public var sessionType: String?
        /// `ID` and `VERSION_ID` from os-release.
        public var osReleaseID: String?
        public var osReleaseVersionID: String?
        /// `uname -m` of the running system.
        public var machine: String?
        /// The packaged build-info.txt, as `key=value` lines.
        public var buildInfo: String?

        public init(treeEnabled: Bool, rendererRegistered: Bool?, sessionType: String?, osReleaseID: String?,
                    osReleaseVersionID: String?, machine: String?, buildInfo: String?) {
            self.treeEnabled = treeEnabled
            self.rendererRegistered = rendererRegistered
            self.sessionType = sessionType
            self.osReleaseID = osReleaseID
            self.osReleaseVersionID = osReleaseVersionID
            self.machine = machine
            self.buildInfo = buildInfo
        }
    }

    /// The fields build-info.txt may provide; any other line is ignored.
    public struct LinuxBuildInfo: Equatable, Sendable {
        public var version: String?
        public var architecture: String?
        public var source: String?

        public init(parsing text: String) {
            for line in text.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else {
                    continue
                }
                let value = String(parts[1])
                switch parts[0] {
                case "version" where Self.isVersion(value):
                    version = value
                case "architecture" where ["amd64", "arm64"].contains(value):
                    architecture = value
                case "source" where (7...40).contains(value.count) && value.allSatisfy({ Self.lowercaseHexDigits.contains($0) }):
                    source = value
                default:
                    continue
                }
            }
        }

        private static let decimalDigits = Set("0123456789")
        private static let lowercaseHexDigits = Set("0123456789abcdef")

        private static func isVersion(_ value: String) -> Bool {
            let components = value.split(separator: ".", omittingEmptySubsequences: false)
            return components.count == 3 && components.allSatisfy { !$0.isEmpty && $0.allSatisfy(decimalDigits.contains) }
        }
    }

    private static let recognizedSessions: Set<String> = ["x11", "wayland"]

    /// An os-release or uname token; free text such as PRETTY_NAME is never copied.
    private static func recognizedToken(_ value: String?) -> String? {
        guard let value, !value.isEmpty,
              value.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_.-".unicodeScalars.contains($0)) }) else {
            return nil
        }
        return value
    }

    /// Engine.render prefers a registered GNOME renderer on either display server.
    public static func linuxRenderer(treeEnabled: Bool, session: String?, rendererRegistered: Bool?) -> (Renderer?, Fallback?) {
        guard treeEnabled else {
            return (.ibusList, .setting)
        }
        guard let rendererRegistered, let session, recognizedSessions.contains(session) else {
            return (nil, .unavailable)
        }
        if rendererRegistered {
            return (.shellTree, nil)
        }
        return session == "x11" ? (.gtkTree, nil) : (.ibusList, .gnomeExtension)
    }

    public static func linux(_ environment: LinuxEnvironment) -> Self {
        let build = LinuxBuildInfo(parsing: environment.buildInfo ?? "")
        let session = environment.sessionType?.lowercased()
        let recognizedSession = session.flatMap { recognizedSessions.contains($0) ? $0 : nil }
        let operatingSystem = [environment.osReleaseID, environment.osReleaseVersionID]
            .compactMap(recognizedToken).joined(separator: " ")
        let (renderer, fallback) = linuxRenderer(treeEnabled: environment.treeEnabled, session: recognizedSession,
                                                 rendererRegistered: environment.rendererRegistered)
        let fields = [
            Field(labelKey: "support.version", value: .text(build.version)),
            Field(labelKey: "support.source", value: .text(build.source)),
            Field(labelKey: "support.os", value: .text(operatingSystem.isEmpty ? nil : operatingSystem)),
            Field(labelKey: "support.cpu", value: .text(recognizedToken(environment.machine))),
            Field(labelKey: "support.package-cpu", value: .text(build.architecture)),
            // Ubuntu packages are built only with the CPU inference backend.
            Field(labelKey: "support.backend", value: .text(build.version == nil ? nil : "CPU")),
            Field(labelKey: "support.session", value: .text(recognizedSession))
        ]
        return .init(fields: fields + rendererFields(renderer: renderer, fallback: fallback))
    }
}
