import AppKit
import SwiftUI

@MainActor
struct UserDictionaryWindowGuard: NSViewRepresentable {
    let canClose: () -> Bool
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(canClose: canClose, onClose: onClose)
    }

    func makeNSView(context: Context) -> WindowView {
        WindowView(coordinator: context.coordinator)
    }

    func updateNSView(_ view: WindowView, context: Context) {
        context.coordinator.canClose = canClose
        context.coordinator.onClose = onClose
        context.coordinator.attach(to: view.window)
    }

    static func dismantleNSView(_ view: WindowView, coordinator: Coordinator) {
        view.coordinator = nil
        coordinator.detach()
    }

    @MainActor
    final class WindowView: NSView {
        weak var coordinator: Coordinator?

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.attach(to: window)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        var canClose: () -> Bool
        var onClose: () -> Void
        private weak var window: NSWindow?
        private weak var previousDelegate: (any NSWindowDelegate)?

        init(canClose: @escaping () -> Bool, onClose: @escaping () -> Void) {
            self.canClose = canClose
            self.onClose = onClose
        }

        func attach(to newWindow: NSWindow?) {
            guard window !== newWindow else {
                return
            }
            detach()
            guard let newWindow else {
                return
            }
            window = newWindow
            previousDelegate = newWindow.delegate
            newWindow.delegate = self
        }

        func detach() {
            // Another owner may have installed a delegate since this guard was attached.
            if window?.delegate === self {
                window?.delegate = previousDelegate
            }
            window = nil
            previousDelegate = nil
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard canClose() else {
                return false
            }
            return previousDelegate?.windowShouldClose?(sender) ?? true
        }

        func windowWillClose(_ notification: Notification) {
            let delegate = previousDelegate
            onClose()
            delegate?.windowWillClose?(notification)
        }
    }
}
