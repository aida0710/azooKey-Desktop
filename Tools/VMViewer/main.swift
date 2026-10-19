import AppKit
import Virtualization

/// A task-local viewer for a stopped Lima disk. No host folders or clipboard
/// are shared. It uses the system Virtualization framework, without a package install.
@MainActor
final class VMViewer: NSObject, NSApplicationDelegate, NSWindowDelegate, VZVirtualMachineDelegate {
    private var machine: VZVirtualMachine?
    private var window: NSWindow?
    private var stopping = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            guard let directory = Bundle.main.object(forInfoDictionaryKey: "VMDirectory") as? String,
                  let platform = Bundle.main.object(forInfoDictionaryKey: "VMPlatform") as? String else {
                throw failure("VM metadata is missing. Build with Tools/build-vm-viewer.sh.")
            }
            let root = URL(fileURLWithPath: directory, isDirectory: true)
            for name in ["ha.pid", "viewer.pid"] {
                if let value = try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8),
                   let pid = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)), kill(pid, 0) == 0 {
                    throw failure("VM is already running. Shut it down before opening this viewer.")
                }
            }
            let configuration = VZVirtualMachineConfiguration()
            configuration.cpuCount = 4
            configuration.memorySize = 8 * 1024 * 1024 * 1024
            if platform == "macos" {
                let mac = VZMacPlatformConfiguration()
                guard let model = VZMacHardwareModel(dataRepresentation: try Data(contentsOf: root.appendingPathComponent("vz-hwmodel"))),
                      let identifier = VZMacMachineIdentifier(dataRepresentation: try Data(contentsOf: root.appendingPathComponent("vz-identifier"))) else {
                    throw failure("Invalid Lima macOS hardware identity.")
                }
                mac.hardwareModel = model
                mac.machineIdentifier = identifier
                mac.auxiliaryStorage = VZMacAuxiliaryStorage(url: root.appendingPathComponent("vz-aux"))
                configuration.platform = mac
                configuration.bootLoader = VZMacOSBootLoader()
                let graphics = VZMacGraphicsDeviceConfiguration()
                graphics.displays = [.init(widthInPixels: 1440, heightInPixels: 900, pixelsPerInch: 100)]
                configuration.graphicsDevices = [graphics]
            } else {
                let generic = VZGenericPlatformConfiguration()
                guard let identifier = VZGenericMachineIdentifier(dataRepresentation: try Data(contentsOf: root.appendingPathComponent("vz-identifier"))) else {
                    throw failure("Invalid Lima Linux hardware identity.")
                }
                generic.machineIdentifier = identifier
                configuration.platform = generic
                let boot = VZEFIBootLoader()
                boot.variableStore = VZEFIVariableStore(url: root.appendingPathComponent("vz-efi"))
                configuration.bootLoader = boot
                let graphics = VZVirtioGraphicsDeviceConfiguration()
                graphics.scanouts = [.init(widthInPixels: 1440, heightInPixels: 900)]
                configuration.graphicsDevices = [graphics]
                configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
                // Lima cloud guests use hvc0 as their system console. Omitting
                // it can prevent services configured to use the console from starting.
                let log = root.appendingPathComponent("viewer-serial.log")
                FileManager.default.createFile(atPath: log.path, contents: nil)
                let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
                serial.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil,
                                                                     fileHandleForWriting: try FileHandle(forWritingTo: log))
                configuration.serialPorts = [serial]
                configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
            }
            // Match Lima's explicit ARM corruption workaround. Automatic cache
            // mode is unsafe for these sparse disk images (Lima 2.2 vm_darwin.go).
            let disk = try VZDiskImageStorageDeviceAttachment(url: root.appendingPathComponent("disk"),
                readOnly: false, cachingMode: .cached, synchronizationMode: .fsync)
            configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]
            let cloudInit = root.appendingPathComponent("cidata.iso")
            if platform == "ubuntu", FileManager.default.fileExists(atPath: cloudInit.path) {
                configuration.storageDevices.append(VZVirtioBlockDeviceConfiguration(
                    attachment: try VZDiskImageStorageDeviceAttachment(url: cloudInit, readOnly: true)))
            }
            let network = VZVirtioNetworkDeviceConfiguration()
            let macAddress = Bundle.main.object(forInfoDictionaryKey: "VMMACAddress") as? String ?? "02:aa:00:00:00:01"
            network.macAddress = VZMACAddress(string: macAddress)!
            network.attachment = VZNATNetworkDeviceAttachment()
            configuration.networkDevices = [network]
            configuration.keyboards = [VZUSBKeyboardConfiguration()]
            configuration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
            configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
            try configuration.validate()
            let vm = VZVirtualMachine(configuration: configuration)
            machine = vm
            vm.delegate = self
            let view = VZVirtualMachineView(frame: NSRect(x: 0, y: 0, width: 1152, height: 720))
            view.virtualMachine = vm
            view.capturesSystemKeys = true
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "azooKey test VM — \(platform)"
            window.contentView = view
            window.delegate = self
            window.center()
            window.makeKeyAndOrderFront(nil)
            self.window = window
            NSApplication.shared.activate(ignoringOtherApps: true)
            let pidFile = root.appendingPathComponent("viewer.pid")
            try "\(getpid())".write(to: pidFile, atomically: true, encoding: .utf8)
            vm.start { [weak self] result in
                if case .failure(let error) = result { self?.show(error) }
            }
        } catch { show(error) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        requestShutdown()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if machine?.state == .stopped || machine == nil { return .terminateNow }
        requestShutdown()
        return .terminateCancel
    }

    private func requestShutdown() {
        guard !stopping else { return }
        do {
            try machine?.requestStop()
            stopping = true
            window?.title += " — shutting down"
        } catch { show(error) }
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) { NSApplication.shared.terminate(nil) }
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) { show(error) }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "azooKey.TestVM", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func show(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
        if machine?.state != .running { exit(1) }
    }
}

@main
enum Main {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = VMViewer()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        let menu = NSMenu()
        let root = NSMenuItem()
        let submenu = NSMenu()
        submenu.addItem(withTitle: "Shut down VM", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        root.submenu = submenu
        menu.addItem(root)
        application.mainMenu = menu
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
