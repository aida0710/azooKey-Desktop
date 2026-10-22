@testable import Core
import Testing

private func japanese(_ key: String) -> String {
    Localization.text(key, language: .japanese)
}

private func linuxEnvironment(
    treeEnabled: Bool = true, rendererRegistered: Bool? = false, sessionType: String? = "wayland",
    osReleaseID: String? = "ubuntu", osReleaseVersionID: String? = "24.04", machine: String? = "x86_64",
    buildInfo: String? = nil
) -> SupportDiagnostics.LinuxEnvironment {
    .init(treeEnabled: treeEnabled, rendererRegistered: rendererRegistered, sessionType: sessionType,
          osReleaseID: osReleaseID, osReleaseVersionID: osReleaseVersionID, machine: machine, buildInfo: buildInfo)
}

@Test func buildInfoKeepsOnlyRecognizedFieldsAndValues() {
    let linux = SupportDiagnostics.PackageBuildInfo.linuxArchitectures
    let valid = SupportDiagnostics.PackageBuildInfo(parsing: "version=0.1.2\narchitecture=amd64\nsource=0123456789abcdef\napiKey=PRIVATE_KEY\n",
                                                    architectures: linux)
    #expect(valid.version == "0.1.2")
    #expect(valid.architecture == "amd64")
    #expect(valid.source == "0123456789abcdef")
    let invalid = SupportDiagnostics.PackageBuildInfo(parsing: "version=PRIVATE_TEXT\narchitecture=PRIVATE_CPU\nsource=PRIVATE_DOCUMENT\nsource=ABCDEF0\n",
                                                      architectures: linux)
    #expect(invalid == .init(parsing: "", architectures: linux))
}

@Test func linuxReportExcludesUnrecognizedEnvironmentText() {
    let report = SupportDiagnostics.linux(linuxEnvironment(
        rendererRegistered: false, sessionType: "Wayland", osReleaseVersionID: "24.04", machine: "aarch64",
        buildInfo: "version=0.1.2\narchitecture=arm64\nsource=0123456789abcdef\ndictionary=PRIVATE_DICTIONARY\n"
    )).report(language: .japanese)
    #expect(!report.contains("PRIVATE_"))
    for value in ["0.1.2", "ubuntu 24.04", "aarch64", "arm64", "0123456789abcdef", "wayland"] {
        #expect(report.contains(value))
    }
    #expect(report.contains("\(japanese("support.renderer")): \(japanese("support.renderer.ibus-list"))"))
    #expect(report.contains("\(japanese("support.fallback")): \(japanese("support.fallback.extension"))"))
}

@Test func unknownLinuxEnvironmentDoesNotClaimAWorkingRenderer() {
    let report = SupportDiagnostics.linux(linuxEnvironment(
        rendererRegistered: nil, sessionType: "PRIVATE_SESSION", osReleaseID: "PRIVATE OS", osReleaseVersionID: nil,
        machine: "PRIVATE MACHINE", buildInfo: "version=PRIVATE_VERSION"
    )).report(language: .japanese)
    #expect(!report.contains("PRIVATE"))
    #expect(report.contains("\(japanese("support.os")): \(japanese("support.unknown"))"))
    #expect(report.contains("\(japanese("support.backend")): \(japanese("support.unknown"))"))
    #expect(report.contains(japanese("support.fallback.unavailable")))
}

struct LinuxRendererCase: Sendable, CustomTestStringConvertible {
    let treeEnabled: Bool
    let session: String?
    let rendererRegistered: Bool?
    let renderer: SupportDiagnostics.Renderer?
    let fallback: SupportDiagnostics.Fallback?

    var testDescription: String { "tree=\(treeEnabled) session=\(session ?? "nil") registered=\(String(describing: rendererRegistered))" }
}

@Test(arguments: [
    LinuxRendererCase(treeEnabled: false, session: "wayland", rendererRegistered: nil, renderer: .ibusList, fallback: .setting),
    LinuxRendererCase(treeEnabled: false, session: "x11", rendererRegistered: true, renderer: .ibusList, fallback: .setting),
    LinuxRendererCase(treeEnabled: false, session: "wayland", rendererRegistered: true, renderer: .ibusList, fallback: .setting),
    LinuxRendererCase(treeEnabled: true, session: "x11", rendererRegistered: false, renderer: .gtkTree, fallback: nil),
    LinuxRendererCase(treeEnabled: true, session: "x11", rendererRegistered: true, renderer: .shellTree, fallback: nil),
    LinuxRendererCase(treeEnabled: true, session: "wayland", rendererRegistered: true, renderer: .shellTree, fallback: nil),
    LinuxRendererCase(treeEnabled: true, session: "wayland", rendererRegistered: false, renderer: .ibusList, fallback: .gnomeExtension),
    LinuxRendererCase(treeEnabled: true, session: "x11", rendererRegistered: nil, renderer: nil, fallback: .unavailable),
    LinuxRendererCase(treeEnabled: true, session: "wayland", rendererRegistered: nil, renderer: nil, fallback: .unavailable),
    LinuxRendererCase(treeEnabled: true, session: "tty", rendererRegistered: true, renderer: nil, fallback: .unavailable),
    LinuxRendererCase(treeEnabled: true, session: nil, rendererRegistered: true, renderer: nil, fallback: .unavailable)
])
func linuxRendererDistinguishesSettingExtensionAndMissingEngine(_ rendererCase: LinuxRendererCase) {
    let decision = SupportDiagnostics.linuxRenderer(treeEnabled: rendererCase.treeEnabled, session: rendererCase.session,
                                                    rendererRegistered: rendererCase.rendererRegistered)
    #expect(decision.0 == rendererCase.renderer)
    #expect(decision.1 == rendererCase.fallback)
}

@Test func macOSReportExplainsWhyTheListIsShown() {
    let report = SupportDiagnostics.macOS(.init(version: nil, source: "abc1234", operatingSystem: "Version 26.0",
                                                cpu: "arm64", backend: nil, treeEnabled: false)).report(language: .english)
    let lines = report.split(separator: "\n").map(String.init)
    #expect(lines.first == "azooKey Tree")
    #expect(lines.contains("\(Localization.text("support.version", language: .english)): \(Localization.text("support.unknown", language: .english))"))
    #expect(lines.contains("\(Localization.text("support.session", language: .english)): AppKit"))
    #expect(lines.contains("\(Localization.text("support.renderer", language: .english)): \(Localization.text("support.renderer.mac-list", language: .english))"))
    #expect(lines.contains("\(Localization.text("support.fallback", language: .english)): \(Localization.text("support.fallback.setting", language: .english))"))
    #expect(!report.contains(Localization.text("support.package-cpu", language: .english)))
}

@Test func windowsReportKeepsOnlyRecognizedValues() {
    let report = SupportDiagnostics.windows(.init(
        treeEnabled: true, osVersion: "10.0.26200", machine: "x64",
        buildInfo: "version=0.2.0\narchitecture=x64\nsource=0123456789abcdef\napiKey=PRIVATE_KEY\n"
    )).report(language: .japanese)
    #expect(!report.contains("PRIVATE_"))
    for value in ["0.2.0", "Windows 10.0.26200", "x64", "0123456789abcdef", "TSF"] {
        #expect(report.contains(value))
    }
    #expect(report.contains("\(japanese("support.renderer")): \(japanese("support.renderer.windows-tree"))"))
    #expect(report.contains("\(japanese("support.fallback")): \(japanese("support.none"))"))
    #expect(report.contains("\(japanese("support.backend")): CPU"))
}

@Test func windowsReportDropsUnrecognizedVersionAndCPU() {
    let report = SupportDiagnostics.windows(.init(
        treeEnabled: false, osVersion: "Windows 11 Pro PRIVATE", machine: "PRIVATE_CPU",
        buildInfo: "architecture=amd64\n"
    )).report(language: .english)
    #expect(!report.contains("PRIVATE"))
    #expect(!report.contains("amd64"))
    let unknown = Localization.text("support.unknown", language: .english)
    #expect(report.contains("\(Localization.text("support.os", language: .english)): \(unknown)"))
    #expect(report.contains("\(Localization.text("support.cpu", language: .english)): \(unknown)"))
    #expect(report.contains("\(Localization.text("support.renderer", language: .english)): \(Localization.text("support.renderer.windows-list", language: .english))"))
    #expect(report.contains("\(Localization.text("support.fallback", language: .english)): \(Localization.text("support.fallback.setting", language: .english))"))
}
