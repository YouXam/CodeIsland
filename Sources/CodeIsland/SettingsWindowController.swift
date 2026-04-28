import AppKit
import SwiftUI

@MainActor
class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    private var closeObserver: NSObjectProtocol?

    private func clearCloseObserver() {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
    }

    func show() {
        // Switch to regular activation policy so the window can receive focus
        NSApp.setActivationPolicy(.regular)
        // Use the actual bundle app icon so Dock matches the packaged asset catalog icon.
        NSApp.applicationIconImage = Self.bundleAppIcon()

        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenW = screen?.frame.width ?? 1440
        let screenH = screen?.frame.height ?? 900
        let winW = min(660, screenW * 0.5)
        let winH = min(540, screenH * 0.6)
        let contentSize = NSSize(width: winW, height: winH)

        let settingsView = SettingsView()
            .frame(width: contentSize.width, height: contentSize.height)
        let hostingView = NSHostingView(rootView: settingsView)
        hostingView.frame = NSRect(origin: .zero, size: contentSize)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .visible
        window.title = L10n.shared["settings_title"]
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hostingView
        window.setContentSize(contentSize)
        window.contentMinSize = contentSize
        window.contentMaxSize = contentSize
        window.toolbar = nil
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Revert to accessory policy after close without hiding the entire app.
        // Hiding here causes the panel to blink even though only the settings
        // window is being dismissed.
        clearCloseObserver()
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.window = nil
                self?.clearCloseObserver()
                DispatchQueue.main.async {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }

        self.window = window
    }

    static func bundleAppIcon() -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        image.size = NSSize(width: 256, height: 256)
        return image
    }
}
