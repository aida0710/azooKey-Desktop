import Cocoa
import Core
import Foundation
import SwiftUI

extension Notification.Name {
    static let navigateHistoryUp = Notification.Name("navigateHistoryUp")
    static let navigateHistoryDown = Notification.Name("navigateHistoryDown")
    static let textFieldFocusChanged = Notification.Name("textFieldFocusChanged")
    static let requestTextFieldFocus = Notification.Name("requestTextFieldFocus")
}

final class PromptInputWindow: NSWindow {
    private var completion: ((String?) -> Void)?
    private var previewCallback: PromptInputView.PreviewSender?
    private var applyCallback: ((AISelectedTextTransformation) -> Void)?
    private var isTextFieldCurrentlyFocused: Bool = false
    private var request: PromptInputRequest?
    private var requestIdentifier = UUID()
    private var previousApp: NSRunningApplication?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        self.title = Localization.text("ai.title")
        self.level = .floating
        self.isReleasedWhenClosed = false
        self.backgroundColor = NSColor.clear
        self.hasShadow = true
        self.acceptsMouseMovedEvents = true

        // Use native material backing
        self.isOpaque = false
        self.alphaValue = 1.0

        setupUI()

        // Listen for text field focus changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textFieldFocusChanged(_:)),
            name: .textFieldFocusChanged,
            object: nil
        )
    }

    @objc private func textFieldFocusChanged(_ notification: Notification) {
        if let isFocused = notification.object as? Bool {
            isTextFieldCurrentlyFocused = isFocused
        }
    }

    private func setupUI() {
        guard let request else {
            return
        }
        let requestIdentifier = self.requestIdentifier
        let contentView = PromptInputView(
            request: request,
            onPreview: { [weak self] arguments, callback in
                guard let self, self.isCurrentRequest(requestIdentifier) else {
                    callback(.failure(.targetChanged))
                    return
                }
                self.previewCallback?(arguments, callback)
            },
            onApply: { [weak self] confirmed, prompt in
                self?.finish(prompt: prompt, confirmed: confirmed, requestIdentifier: requestIdentifier)
            },
            onCancel: { [weak self] in
                self?.finish(prompt: nil, requestIdentifier: requestIdentifier)
            },
            onPreviewModeChanged: { [weak self] isPreviewMode in
                guard let self, self.isCurrentRequest(requestIdentifier) else {
                    return
                }
                self.resizeWindowToContent(isPreviewMode: isPreviewMode)
            }
        )

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.layer?.cornerRadius = 16
        hostingView.layer?.masksToBounds = true
        self.contentView = hostingView
    }

    func showPromptInput(
        at cursorLocation: NSPoint,
        request: PromptInputRequest,
        onPreview: @escaping PromptInputView.PreviewSender,
        onApply: @escaping (AISelectedTextTransformation) -> Void,
        completion: @escaping (String?) -> Void
    ) {
        self.previewCallback = onPreview
        self.applyCallback = onApply
        self.completion = completion
        self.request = request
        self.requestIdentifier = UUID()
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        if let frontmostApp, frontmostApp.processIdentifier != NSRunningApplication.current.processIdentifier {
            self.previousApp = frontmostApp
        } else {
            self.previousApp = nil
        }

        // Reset the window display state
        resetWindowState()

        // Initial resize to base size
        resizeWindowToContent(isPreviewMode: false)

        // Position window near cursor
        var windowFrame = self.frame
        windowFrame.origin = adjustWindowPosition(for: cursorLocation, windowSize: windowFrame.size)
        self.setFrame(windowFrame, display: true)

        self.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Set focus to text field with multiple attempts
        focusTextField()
    }

    private func resizeWindowToContent(isPreviewMode: Bool) {
        let headerHeight: CGFloat = 36  // Compact header
        let textFieldHeight: CGFloat = 36  // Compact text field
        let historyHeight: CGFloat = isPreviewMode ? 0 : 200  // More space for 10 items when not in preview mode
        let buttonHeight: CGFloat = 36  // Compact button row
        let containerPadding: CGFloat = 16  // Reduced padding
        let scopeHeight: CGFloat = 150  // Destination, scrollable target and history explanation.

        let previewHeight: CGFloat = isPreviewMode ? 90 : 0  // Compact preview

        let totalHeight = headerHeight + textFieldHeight + historyHeight + buttonHeight + previewHeight + containerPadding + scopeHeight

        var currentFrame = self.frame
        let newSize = NSSize(width: 460, height: totalHeight)

        // Adjust origin to keep the window in the same relative position
        currentFrame.origin.y += (currentFrame.size.height - newSize.height)
        currentFrame.size = newSize

        self.setFrame(currentFrame, display: true, animate: true)
    }

    private func resetWindowState() {
        // Reset the SwiftUI view state by creating a new content view
        setupUI()
    }

    private func focusTextField() {
        // Make window key and active
        NSApp.activate(ignoringOtherApps: true)
        self.makeKeyAndOrderFront(nil)

        // Single delayed focus request
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(name: .requestTextFieldFocus, object: nil)
        }
    }

    private func adjustWindowPosition(for cursorLocation: NSPoint, windowSize: NSSize) -> NSPoint {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(cursorLocation, $0.frame, false) }) ?? NSScreen.main else {
            return cursorLocation
        }

        let origin = WindowPositioning.promptWindowOrigin(
            cursorLocation: WindowPositioning.Point(cursorLocation),
            windowSize: WindowPositioning.Size(windowSize),
            screenRect: WindowPositioning.Rect(screen.visibleFrame)
        )
        return origin.cgPoint
    }

    override func close() {
        finish(prompt: nil)
    }

    private func isCurrentRequest(_ identifier: UUID) -> Bool {
        request != nil && requestIdentifier == identifier
    }

    private func finish(prompt: String?, confirmed: AISelectedTextTransformation? = nil, requestIdentifier: UUID? = nil) {
        guard requestIdentifier.map(isCurrentRequest) ?? true else {
            return
        }
        let completion = self.completion
        let apply = self.applyCallback
        let previousApp = self.previousApp
        // Clear callbacks before closing so reentrant close notifications finish once.
        self.completion = nil
        self.previewCallback = nil
        self.applyCallback = nil
        self.previousApp = nil
        self.request = nil
        super.close()
        self.contentView = nil
        completion?(prompt)
        if let confirmed {
            apply?(confirmed)
        } else if let previousApp {
            previousApp.activate(options: [])
        }
    }

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        // Handle navigation keys at window level
        if event.keyCode == 53 { // Escape key
            // Send escape event to SwiftUI view and close window
            close()
        } else if event.keyCode == 126 { // Up arrow key
            // Only handle up arrow if not in text field (CustomTextField handles it directly)
            if !isTextFieldCurrentlyFocused {
                NotificationCenter.default.post(name: .navigateHistoryUp, object: nil)
            } else {
                super.keyDown(with: event)
            }
        } else if event.keyCode == 125 { // Down arrow key
            // Only handle down arrow if not in text field (CustomTextField handles it directly)
            if !isTextFieldCurrentlyFocused {
                NotificationCenter.default.post(name: .navigateHistoryDown, object: nil)
            } else {
                super.keyDown(with: event)
            }
        } else {
            super.keyDown(with: event)
        }
    }
}
