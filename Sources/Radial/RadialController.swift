import AppKit

final class RadialPanel: NSPanel {
    let radialView = RadialView(frame: .zero)

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        radialView.frame = contentView?.bounds ?? .zero
        radialView.autoresizingMask = [.width, .height]
        contentView = radialView
    }

    override var canBecomeKey: Bool { true }
}

final class RadialController: DragMonitorDelegate {
    private var panel: RadialPanel?
    private var urls: [URL] = []
    private var formats: [FileFormat] = []
    private var mode: WheelMode = .convert
    private var visible = false
    private var pickerMode = false
    private var outsideClickMonitor: Any?

    weak var dragMonitor: DragMonitor?

    func dragMonitor(_ monitor: DragMonitor, didBeginModifiedDrag urls: [URL], at point: NSPoint, mode: WheelMode) {
        dragMonitor = monitor
        pickerMode = false
        present(urls: urls, at: point, mode: mode)
    }

    func dragMonitor(_ monitor: DragMonitor, didChangeModifiers mode: WheelMode?, at point: NSPoint) {
        guard !pickerMode else { return }
        guard let mode else {
            if visible { hide() }
            return
        }
        if !visible {
            present(urls: urls, at: point, mode: mode)
            return
        }
        if mode != self.mode {
            self.mode = mode
            reloadItems()
        }
        panel?.radialView.updateHighlight(forScreenPoint: point)
    }

    func dragMonitor(_ monitor: DragMonitor, didUpdateDraggedURLs urls: [URL]) {
        adopt(urls)
    }

    func dragMonitorDidEndDrag(_ monitor: DragMonitor) {
        guard !pickerMode else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, !self.pickerMode else { return }
            self.hide()
        }
    }

    func dragMonitorDidCancelDrag(_ monitor: DragMonitor) {
        guard !pickerMode else { return }
        hide()
    }

    func presentPicker(for urls: [URL], advanced: Bool = false) {
        pickerMode = true
        let point = NSEvent.mouseLocation
        present(urls: urls, at: point, mode: advanced ? .tools : .convert)
        panel?.radialView.interactive = true
        panel?.makeKeyAndOrderFront(nil)
        panel?.makeFirstResponder(panel?.radialView)
        NSApp.activate(ignoringOtherApps: true)
        installOutsideClickMonitor()
    }

    private func present(urls: [URL], at point: NSPoint, mode: WheelMode) {
        self.urls = urls
        self.mode = mode
        formats = urls.compactMap(FileFormat.detect)
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let panel = self.panel ?? RadialPanel(screen: screen)
        panel.setFrame(screen.frame, display: false)
        self.panel = panel

        let view = panel.radialView
        view.interactive = pickerMode
        view.mode = mode
        let clamped = clampedCenter(point, in: screen.frame, radius: view.discRadius + 48)
        view.center = NSPoint(x: clamped.x - screen.frame.minX, y: clamped.y - screen.frame.minY)
        view.onSelect = { [weak self] item in self?.select(item) }
        view.onCancel = { [weak self] in self?.hide() }
        view.onDragEntered = { [weak self] info in self?.adoptDraggedFiles(from: info) }
        view.onDragSessionEnded = { [weak self] in self?.dragSessionEnded() }
        view.clearHighlight()
        reloadItems()
        panel.orderFrontRegardless()
        visible = true
    }

    private func clampedCenter(_ point: NSPoint, in frame: NSRect, radius: CGFloat) -> NSPoint {
        NSPoint(
            x: min(max(point.x, frame.minX + radius), frame.maxX - radius),
            y: min(max(point.y, frame.minY + radius), frame.maxY - radius)
        )
    }

    private func adoptDraggedFiles(from info: NSDraggingInfo) {
        guard !pickerMode else { return }
        let dragged = DragMonitor.fileURLs(on: info.draggingPasteboard)
        DragDebug.log("drag entered wheel; pasteboard urls=\(dragged.map(\.lastPathComponent)) known=\(urls.map(\.lastPathComponent))")
        adopt(dragged)
    }

    private func adopt(_ dragged: [URL]) {
        guard !pickerMode, visible, !dragged.isEmpty, dragged != urls else { return }
        DiagnosticLog.log("wheel adopted dragged files; count=\(dragged.count)")
        urls = dragged
        formats = dragged.compactMap(FileFormat.detect)
        reloadItems()
    }

    private func dragSessionEnded() {
        guard !pickerMode, visible else { return }
        DragDebug.log("drag session ended while wheel visible; dismissing")
        hide()
        dragMonitor?.markHandled()
    }

    private func reloadItems() {
        guard let view = panel?.radialView else { return }
        view.mode = mode
        let count = urls.count
        if count == 0 {
            view.items = []
            view.subtitle = "Move the files over the wheel"
            view.emptyMessage = mode == .ai ? "AI · Coming later" : (mode == .actions ? "Drop here for file actions" : (mode == .tools ? "Drop here for tools" : "Drop here to convert"))
            return
        }
        view.subtitle = count == 1 ? urls[0].lastPathComponent : "\(count) files"
        view.items = ActionRegistry.items(for: mode, formats: formats, urls: urls)
        view.emptyMessage = mode == .ai ? "AI · Coming later" : (mode == .tools ? "No tools for this selection" : "No conversions available")
    }

    private func select(_ item: RadialItem) {
        guard item.isEnabled else { return }
        let selectedURLs = urls
        DiagnosticLog.log("radial select \(item.detail) for \(selectedURLs.map(\.lastPathComponent))")
        hide()
        dragMonitor?.markHandled()
        DiagnosticLog.log("radial hidden, dispatching action")
        Task { @MainActor in
            switch item.action {
            case .convert(let target):
                JobRunner.shared.convert(selectedURLs, to: target)
            case .tool(let tool):
                DiagnosticLog.log("open tool \(tool.rawValue)")
                ToolWindowManager.shared.open(tool, files: selectedURLs)
            case .fileAction(let action):
                FileActionRunner.perform(action, with: selectedURLs)
            case .ai:
                break
            }
        }
    }

    func highlight(_ index: Int) {
        panel?.radialView.highlight(index)
    }

    func hide() {
        visible = false
        pickerMode = false
        panel?.radialView.clearHighlight()
        panel?.radialView.interactive = false
        panel?.orderOut(nil)
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    private func installOutsideClickMonitor() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hide()
        }
    }
}
