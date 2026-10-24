import AppKit
import Carbon
import ApplicationServices
import Metal

@main
enum SendKeysCommand {
    static func main() {
        let command = CommandLine.arguments.dropFirst().first ?? "permissions"
        if command == "permissions" {
            let permissions: [String: Any] = [
                "accessibilityTrusted": AXIsProcessTrusted(),
                "postEventAccess": CGPreflightPostEventAccess(),
                "screenCaptureAccess": CGPreflightScreenCaptureAccess(),
                "metalDevices": MTLCopyAllDevices().map { $0.name },
                "frontmostBundleID": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            ]
            printJSON(permissions)
            exit(0)
        }

        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.TextEdit" else {
            fputs("TextEdit is not frontmost; no events were posted.\n", stderr)
            exit(1)
        }
        guard CGPreflightPostEventAccess() else {
            fputs("CGEvent posting denied: the runner needs Accessibility/PostEvent permission. No permission prompt was opened.\n", stderr)
            exit(3)
        }

        let keyCodes: [CGKeyCode]
        var modifiers: CGEventFlags = []
        switch command {
        case "nihongo": keyCodes = [kVK_ANSI_N, kVK_ANSI_I, kVK_ANSI_H, kVK_ANSI_O, kVK_ANSI_N, kVK_ANSI_G, kVK_ANSI_O].map(CGKeyCode.init)
        case "escape": keyCodes = [CGKeyCode(kVK_Escape)]
        case "down": keyCodes = [CGKeyCode(kVK_DownArrow)]
        case "up": keyCodes = [CGKeyCode(kVK_UpArrow)]
        case "pageup": keyCodes = [CGKeyCode(kVK_PageUp)]
        case "pagedown": keyCodes = [CGKeyCode(kVK_PageDown)]
        case "shift-left":
            keyCodes = [CGKeyCode(kVK_LeftArrow)]
            modifiers = .maskShift
        case "shift-right":
            keyCodes = [CGKeyCode(kVK_RightArrow)]
            modifiers = .maskShift
        case "space": keyCodes = [CGKeyCode(kVK_Space)]
        case "return": keyCodes = [CGKeyCode(kVK_Return)]
        case "save":
            keyCodes = [CGKeyCode(kVK_ANSI_S)]
            modifiers = .maskCommand
        default:
            let letters = "abcdefghijklmnopqrstuvwxyz123456789"
            let codes = [kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F,
                         kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L,
                         kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R,
                         kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X,
                         kVK_ANSI_Y, kVK_ANSI_Z, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
                         kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
            let mapping = Dictionary(uniqueKeysWithValues: zip(letters, codes.map(CGKeyCode.init)))
            guard !command.isEmpty, command.allSatisfy({ mapping[$0] != nil }) else {
                fputs("Expected a named key or lowercase ASCII letters and candidate digits.\n", stderr)
                exit(2)
            }
            keyCodes = command.compactMap { mapping[$0] }
        }

        // Deliberately pace physical key down/up events. Unicode insertion would bypass
        // the input method and could make a broken IME look healthy.
        let keyHoldInterval: TimeInterval = 0.04
        let interKeyInterval: TimeInterval = 0.15
        let source = CGEventSource(stateID: .hidSystemState)
        for keyCode in keyCodes {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
                fputs("Unable to create a keyboard event.\n", stderr)
                exit(1)
            }
            down.flags = modifiers
            up.flags = modifiers
            down.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: keyHoldInterval)
            up.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: interKeyInterval)
        }
        print("Posted \(keyCodes.count) physical keys: \(command)")
    }
}
