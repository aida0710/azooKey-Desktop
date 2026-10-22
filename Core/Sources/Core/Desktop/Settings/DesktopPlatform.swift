/// The desktop operating systems whose settings screens are built from Core's definitions.
public enum DesktopPlatform: String, Codable, CaseIterable, Sendable {
    case macOS
    case linux
    case windows

    public static var current: DesktopPlatform {
        #if os(macOS)
        .macOS
        #elseif os(Windows)
        .windows
        #else
        .linux
        #endif
    }
}
