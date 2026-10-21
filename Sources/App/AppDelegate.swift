import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let dragMonitor = DragMonitor()
    private let radial = RadialController()
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DiagnosticLog.start()
        NSApp.setActivationPolicy(.accessory)
        AppSettings.shared.applyAppearance()
        installStatusItem()
        if ScreenshotDriver.isEnabled {
            ScreenshotDriver.run(radial: radial)
            return
        }
        dragMonitor.delegate = radial
        dragMonitor.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, open urls: [URL]) {
        radial.presentPicker(for: urls)
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "circle.hexagongrid.circle", accessibilityDescription: "ZeroClick")
            button.toolTip = "ZeroClick: hold Shift while dragging a file"
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Convert Files…", action: #selector(convertFiles), keyEquivalent: "o").target = self
        menu.addItem(withTitle: "Open Tool for Files…", action: #selector(openTool), keyEquivalent: "t").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Operation History…", action: #selector(openHistory), keyEquivalent: "h").target = self
        menu.addItem(withTitle: "About ZeroClick", action: #selector(about), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show Logs", action: #selector(showLogs), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit ZeroClick", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func convertFiles() {
        pickFiles { [weak self] urls in self?.radial.presentPicker(for: urls, advanced: false) }
    }

    @objc private func openTool() {
        pickFiles { [weak self] urls in self?.radial.presentPicker(for: urls, advanced: true) }
    }

    private func pickFiles(_ completion: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.showsHiddenFiles = true
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            let manager = FileManager.default
            if let unreadable = panel.urls.first(where: { !manager.isReadableFile(atPath: $0.path) }) {
                let alert = NSAlert()
                alert.messageText = "ZeroClick can't read \(unreadable.lastPathComponent)"
                alert.informativeText = "This file needs administrator access. Copy it to a folder you own in Finder (macOS may offer Touch ID), then open that copy in ZeroClick. ZeroClick never changes the protected original."
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return
            }
            if AppSettings.shared.outputLocation == .besideOriginal,
               panel.urls.contains(where: { !manager.isWritableFile(atPath: $0.deletingLastPathComponent().path) }) {
                let alert = NSAlert()
                alert.messageText = "The original folder is protected"
                alert.informativeText = "ZeroClick can read the selected file but cannot save a new copy beside it. Use Downloads for this and future outputs, or cancel and choose another output location in Settings. The original stays unchanged."
                alert.addButton(withTitle: "Use Downloads as default")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                AppSettings.shared.outputLocation = .downloads
            }
            completion(panel.urls)
        }
    }

    @MainActor
    static func makeSettingsWindow() -> NSWindow {
        let model = SettingsTabModel()
        let view = SettingsView(model: model).environmentObject(AppSettings.shared)
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = []
        let window = SettingsWindow(contentViewController: controller)
        window.title = "ZeroClick Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.toolbarDelegate = SettingsToolbarDelegate(model: model)
        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = window.toolbarDelegate
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [SettingsToolbarDelegate.tabsItem]
        window.toolbar = toolbar
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: SettingsView.width, height: SettingsView.height))
        window.center()
        return window
    }

    @MainActor
    @objc private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = Self.makeSettingsWindow()
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func showLogs() {
        DiagnosticLog.flush()
        NSWorkspace.shared.activateFileViewerSelecting([DiagnosticLog.logFile])
    }

    @MainActor
    @objc private func openHistory() {
        if historyWindow == nil {
            let controller = NSHostingController(rootView: HistoryView(runner: JobRunner.shared))
            let window = NSWindow(contentViewController: controller)
            window.title = "ZeroClick History"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 560, height: 400))
            window.center()
            historyWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        historyWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "ZeroClick",
            .applicationVersion: "0.1.0",
            .credits: NSAttributedString(string: "The zero-click offline file converter.\nEverything happens locally on your Mac."),
        ])
    }
}
