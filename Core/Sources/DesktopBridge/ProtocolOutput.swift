import Foundation
#if canImport(Glibc)
import Glibc
#elseif os(Windows)
import ucrt
#else
import Darwin
#endif

/// The bridge answers on a private copy of stdout and silences the original
/// streams, because converter diagnostics can contain typed text.
enum ProtocolOutput {
    #if os(Windows)
    private static let standardInput: Int32 = 0
    private static let standardOutput: Int32 = 1
    private static let standardError: Int32 = 2
    private static let nullDevice = "NUL"
    #else
    private static let standardOutput = STDOUT_FILENO
    private static let standardError = STDERR_FILENO
    private static let nullDevice = "/dev/null"
    #endif

    static func detachFromStandardStreams() -> FileHandle? {
        #if os(Windows)
        // Text mode would turn LF into CRLF and stop reading at Ctrl+Z.
        _ = _setmode(standardInput, _O_BINARY)
        let responseFD = _dup(standardOutput)
        guard responseFD >= 0 else {
            return nil
        }
        _ = _setmode(responseFD, _O_BINARY)
        var nullFD: Int32 = -1
        guard _sopen_s(&nullFD, nullDevice, _O_WRONLY, _SH_DENYNO, _S_IWRITE) == 0, nullFD >= 0 else {
            return nil
        }
        _ = _dup2(nullFD, standardOutput)
        _ = _dup2(nullFD, standardError)
        _ = _close(nullFD)
        #else
        let responseFD = dup(standardOutput)
        guard responseFD >= 0 else {
            return nil
        }
        let nullFD = open(nullDevice, O_WRONLY)
        guard nullFD >= 0 else {
            return nil
        }
        dup2(nullFD, standardOutput)
        dup2(nullFD, standardError)
        close(nullFD)
        #endif
        return FileHandle(fileDescriptor: responseFD, closeOnDealloc: true)
    }

    static func defaultDataDirectory(environment: [String: String]) -> String {
        #if os(Windows)
        let base = environment["LOCALAPPDATA"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AppData/Local").path
        return URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent("azooKey Tree", isDirectory: true).path
        #else
        let base = environment["XDG_DATA_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share").path
        return base + "/azookey-tree"
        #endif
    }
}
