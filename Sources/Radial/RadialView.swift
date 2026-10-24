import AppKit
import SwiftUI

enum RadialAction: Hashable {
    case convert(FileFormat)
    case tool(ToolID)
    case fileAction(FileAction)
    case ai(AIAction)
    case quickPlaceholder(QuickSlot)
}

enum AIAction: String, CaseIterable, Hashable {
    case summarize, deadlines, checklist, flashcards, ocr, transcribe

    var title: String {
        switch self {
        case .summarize: return "Summarize"
        case .deadlines: return "Extract deadlines"
        case .checklist: return "Create checklist"
        case .flashcards: return "Make flashcards"
        case .ocr: return "OCR and explain"
        case .transcribe: return "Transcribe audio"
        }
    }

    var symbol: String {
        switch self {
        case .summarize: return "text.alignleft"
        case .deadlines: return "calendar.badge.clock"
        case .checklist: return "checklist"
        case .flashcards: return "rectangle.on.rectangle.angled"
        case .ocr: return "text.viewfinder"
        case .transcribe: return "waveform"
        }
    }
}

struct RadialItem: Identifiable, Hashable {
    let action: RadialAction
    let label: String
    let detail: String
    let symbol: String
    let iconBadge: String?
    let disabledReason: String?
    let quickSlot: QuickSlot?

    var id: String { "\(quickSlot?.rawValue ?? "main"):\(action.historyKey ?? String(describing: action))" }
    var isEnabled: Bool { disabledReason == nil }

    func usesIconOnly(in geometry: RadialGeometry, at index: Int) -> Bool {
        let minimumFont = NSFont.systemFont(ofSize: 7, weight: .bold)
        let requiredWidth = (label as NSString).size(withAttributes: [.font: minimumFont]).width + 6
        return requiredWidth > geometry.labelWidth(for: index)
    }

    init(format: FileFormat, disabledReason: String? = nil) {
        action = .convert(format)
        label = format.displayName
        detail = "Convert to \(format.displayName)"
        symbol = format.category.symbol
        iconBadge = format.displayName
        self.disabledReason = disabledReason
        quickSlot = nil
    }

    init(tool: ToolID, disabledReason: String? = nil) {
        action = .tool(tool)
        label = tool.radialLabel
        detail = tool.title
        symbol = tool.symbol
        iconBadge = nil
        self.disabledReason = disabledReason
        quickSlot = nil
    }

    init(ai: AIAction) {
        action = .ai(ai)
        label = ai.title.uppercased()
        detail = "\(ai.title) · Coming later"
        symbol = ai.symbol
        iconBadge = nil
        disabledReason = "Coming later"
        quickSlot = nil
    }

    init(fileAction: FileAction, disabledReason: String? = nil) {
        action = .fileAction(fileAction)
        label = fileAction.title.uppercased()
        detail = fileAction.title
        symbol = fileAction.symbol
        iconBadge = nil
        self.disabledReason = disabledReason
        quickSlot = nil
    }

    init(quickSlot: QuickSlot, item: RadialItem?) {
        self.quickSlot = quickSlot
        if let item {
            action = item.action
            label = item.label
            detail = "\(quickSlot.title): \(item.detail)"
            symbol = item.symbol
            iconBadge = item.iconBadge
            disabledReason = item.disabledReason
        } else {
            action = .quickPlaceholder(quickSlot)
            label = quickSlot == .last ? "LAST" : (quickSlot == .mostUsedOne ? "TOP 1" : "TOP 2")
            detail = "\(quickSlot.title) · No successful action yet"
            symbol = quickSlot.placeholderSymbol
            iconBadge = nil
            disabledReason = "No history yet"
        }
    }
}

struct RadialGeometry {
    var innerRadius: CGFloat = 64
    var outerRadius: CGFloat = 150
    var gap: CGFloat = 4
    var count: Int
    var quickCount: Int = 0

    private var mainCount: Int { max(0, count - quickCount) }

    func slice(for index: Int) -> CGFloat {
        guard quickCount > 0 else { return 2 * .pi / CGFloat(max(count, 1)) }
        return index < mainCount ? (3 * .pi / 2) / CGFloat(max(mainCount, 1)) : (.pi / 2) / CGFloat(quickCount)
    }

    func corner(for index: Int) -> CGFloat {
        let slice = slice(for: index)
        let wanted: CGFloat = count > 8 ? 10 : 14
        let limit = (innerRadius * sin(slice * 0.34) - gap / 2) / (1 - sin(slice * 0.34))
        return max(4, min(wanted, limit))
    }

    var labelRadius: CGFloat { innerRadius + (outerRadius - innerRadius) * 0.56 }

    func labelWidth(for index: Int) -> CGFloat {
        let chord = 2 * labelRadius * sin(slice(for: index) / 2)
        return max(24, chord - 6)
    }

    func angles(for index: Int) -> (start: CGFloat, end: CGFloat) {
        if quickCount > 0 {
            if index < mainCount {
                let slice = slice(for: index)
                let end = 3 * CGFloat.pi / 4 - slice * CGFloat(index)
                return (end - slice, end)
            }
            let slice = slice(for: index)
            let end = 3 * CGFloat.pi / 4 + slice * CGFloat(index - mainCount + 1)
            return (end - slice, end)
        }
        let slice = slice(for: index)
        let end = CGFloat.pi / 2 - slice * CGFloat(index) + slice / 2
        return (end - slice, end)
    }

    func midpoint(for index: Int, in rect: CGRect) -> CGPoint {
        let (start, end) = angles(for: index)
        let mid = (start + end) / 2
        return CGPoint(x: rect.midX + cos(mid) * labelRadius, y: rect.midY - sin(mid) * labelRadius)
    }

    func index(at offset: CGPoint) -> Int? {
        guard count > 0 else { return nil }
        let distance = sqrt(offset.x * offset.x + offset.y * offset.y)
        guard distance >= innerRadius, distance <= outerRadius + 24 else { return nil }
        let angle = atan2(offset.y, offset.x)
        for index in 0..<count {
            let (start, end) = angles(for: index)
            var relative = angle - start
            while relative < 0 { relative += 2 * .pi }
            while relative >= 2 * .pi { relative -= 2 * .pi }
            if relative <= end - start { return index }
        }
        return nil
    }
}

struct WedgeShape: Shape {
    var geometry: RadialGeometry
    var index: Int

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let (a0, a1) = geometry.angles(for: index)
        let r0 = geometry.innerRadius
        let r1 = geometry.outerRadius
        let k = geometry.corner(for: index)
        let half = geometry.gap / 2
        let phiOuter = asin((k + half) / (r1 - k))
        let phiInner = asin((k + half) / (r0 + k))

        func point(_ radius: CGFloat, _ angle: CGFloat) -> CGPoint {
            CGPoint(x: c.x + cos(angle) * radius, y: c.y - sin(angle) * radius)
        }
        func normal(_ angle: CGFloat, inward: Bool) -> CGVector {
            inward ? CGVector(dx: sin(angle), dy: -cos(angle)) : CGVector(dx: -sin(angle), dy: cos(angle))
        }
        func offset(_ p: CGPoint, _ v: CGVector, _ distance: CGFloat) -> CGPoint {
            CGPoint(x: p.x + v.dx * distance, y: p.y - v.dy * distance)
        }
        func arc(_ path: inout Path, center: CGPoint, radius: CGFloat, from: CGPoint, to: CGPoint) {
            let s = atan2(from.y - center.y, from.x - center.x)
            let e = atan2(to.y - center.y, to.x - center.x)
            path.addArc(center: center, radius: radius, startAngle: .radians(s), endAngle: .radians(e), clockwise: true)
        }

        let outerEndCenter = point(r1 - k, a1 - phiOuter)
        let outerEndTangent = offset(outerEndCenter, normal(a1, inward: true), -k)
        let innerEndCenter = point(r0 + k, a1 - phiInner)
        let innerEndTangent = offset(innerEndCenter, normal(a1, inward: true), -k)
        let innerStartCenter = point(r0 + k, a0 + phiInner)
        let innerStartTangent = offset(innerStartCenter, normal(a0, inward: false), -k)
        let outerStartCenter = point(r1 - k, a0 + phiOuter)
        let outerStartTangent = offset(outerStartCenter, normal(a0, inward: false), -k)

        var path = Path()
        path.move(to: point(r1, a0 + phiOuter))
        path.addArc(center: c, radius: r1, startAngle: .radians(-(a0 + phiOuter)), endAngle: .radians(-(a1 - phiOuter)), clockwise: true)
        arc(&path, center: outerEndCenter, radius: k, from: point(r1, a1 - phiOuter), to: outerEndTangent)
        path.addLine(to: innerEndTangent)
        arc(&path, center: innerEndCenter, radius: k, from: innerEndTangent, to: point(r0, a1 - phiInner))
        path.addArc(center: c, radius: r0, startAngle: .radians(-(a1 - phiInner)), endAngle: .radians(-(a0 + phiInner)), clockwise: false)
        arc(&path, center: innerStartCenter, radius: k, from: point(r0, a0 + phiInner), to: innerStartTangent)
        path.addLine(to: outerStartTangent)
        arc(&path, center: outerStartCenter, radius: k, from: outerStartTangent, to: point(r1, a0 + phiOuter))
        path.closeSubpath()
        return path
    }
}

struct RadialWheelView: View {
    var items: [RadialItem]
    var highlighted: Int?
    var title: String
    var emptyMessage: String
    var emptyDetail: String
    var geometry: RadialGeometry

    var iconOnly: Bool {
        items.indices.contains { items[$0].usesIconOnly(in: geometry, at: $0) }
    }

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            ZStack {
                if items.isEmpty {
                    empty
                } else {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        wedge(item, index: index)
                    }
                    pill
                }
            }
        }
        .frame(width: geometry.outerRadius * 2 + 40, height: geometry.outerRadius * 2 + 40)
    }

    private func wedge(_ item: RadialItem, index: Int) -> some View {
        let shape = WedgeShape(geometry: geometry, index: index)
        let selected = highlighted == index
        return GeometryReader { proxy in
            let rect = CGRect(origin: .zero, size: proxy.size)
            let mid = geometry.midpoint(for: index, in: rect)
            ZStack {
                label(item, index: index, selected: selected)
                    .frame(width: geometry.labelWidth(for: index))
                    .position(mid)
            }
            .frame(width: rect.width, height: rect.height)
            .glassEffect(.regular, in: shape)
            .overlay(shape.fill(item.quickSlot == nil ? .clear : Theme.accent.opacity(0.12)))
            .overlay(shape.stroke(item.quickSlot == nil ? .clear : Color.primary.opacity(0.83),
                                  lineWidth: item.quickSlot == nil ? 0 : 2.4))
            // Draw the fill outside the glass effect: the system animates glass
            // tint after the pointer has already selected the wedge.
            .overlay(shape.fill(selected ? (item.isEnabled ? Theme.accent.opacity(0.48) : Color.secondary.opacity(0.28)) : .clear))
            .overlay {
                if selected {
                    label(item, index: index, selected: true)
                        .frame(width: geometry.labelWidth(for: index))
                        .position(mid)
                }
            }
            .overlay(shape.stroke(selected ? (item.isEnabled ? Theme.accent : Color.secondary) : .clear, lineWidth: 3))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.detail)
        .accessibilityValue(item.disabledReason ?? "Available")
    }

    private func label(_ item: RadialItem, index: Int, selected: Bool) -> some View {
        let dense = items.count > 8
        let iconOnly = self.iconOnly
        return VStack(spacing: dense ? 3 : 5) {
            if let quickSlot = item.quickSlot, !iconOnly {
                Text(quickSlot == .last ? "LAST" : (quickSlot == .mostUsedOne ? "TOP 1" : "TOP 2"))
                    .font(.system(size: 7, weight: .heavy, design: .rounded))
                    .lineLimit(1)
            }
            ZStack(alignment: .topTrailing) {
                if let badge = item.iconBadge {
                    Text(badge)
                        .font(.system(size: badge.count > 4 ? 9 : 12, weight: .black, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                } else {
                    Image(systemName: item.symbol)
                        .font(.system(size: dense ? 16 : 20, weight: .medium))
                        .symbolRenderingMode(.monochrome)
                }
                if iconOnly, let quickSlot = item.quickSlot, item.action != .quickPlaceholder(quickSlot) {
                    Text(quickSlot.marker)
                        .font(.system(size: 8, weight: .black, design: .rounded))
                        .padding(2)
                        .background(Theme.accent, in: Circle())
                        .offset(x: 8, y: -7)
                }
            }
            if !iconOnly {
                Text(item.label)
                .font(.system(size: dense ? 10 : 11.5, weight: .bold, design: .rounded))
                .kerning(dense ? 0.3 : 0.6)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .allowsTightening(true)
            }
            if !item.isEnabled && !iconOnly {
                Text(item.disabledReason?.uppercased() ?? "UNAVAILABLE")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
        }
        .foregroundStyle(item.isEnabled ? (selected ? Color.white : Color.primary) : Color.secondary)
        .opacity(item.isEnabled ? 1 : 0.55)
        .help(item.disabledReason.map { "\(item.detail) · \($0)" } ?? item.detail)
        .contentTransition(.identity)
    }

    private var pill: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .allowsTightening(true)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .frame(maxWidth: geometry.innerRadius * 2 - 8)
            .glassEffect(.regular, in: Capsule())
    }

    private var empty: some View {
        VStack(spacing: 3) {
            Text(emptyMessage)
                .font(.system(size: 14, weight: .semibold))
            if !emptyDetail.isEmpty {
                Text(emptyDetail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .frame(maxWidth: geometry.outerRadius * 2)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class RadialView: NSView {
    var items: [RadialItem] = [] { didSet { refresh(); needsLayout = true } }
    var emptyMessage = "No conversions available" { didSet { refresh() } }
    var subtitle = "" { didSet { refresh() } }
    var center: NSPoint = .zero { didSet { needsLayout = true } }
    var onSelect: ((RadialItem) -> Void)?
    var onCancel: (() -> Void)?
    var onDragEntered: ((NSDraggingInfo) -> Void)?
    var onDragSessionEnded: (() -> Void)?
    var interactive = false
    var mode: WheelMode = .convert { didSet { refresh() } }

    private(set) var highlighted: Int? {
        didSet {
            guard oldValue != highlighted else { return }
            if highlighted != nil {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .drawCompleted)
            }
            refresh()
        }
    }
    private var trackingArea: NSTrackingArea?
    private let host: PassthroughHostingView<RadialWheelView>

    var discRadius: CGFloat { CGFloat(AppSettings.shared.wheelRadius) + 20 }

    private var geometry: RadialGeometry {
        RadialGeometry(innerRadius: CGFloat(AppSettings.shared.wheelRadius) * (82.0 / 210.0),
                       outerRadius: CGFloat(AppSettings.shared.wheelRadius),
                       count: items.count,
                       quickCount: items.suffix(3).filter { $0.quickSlot != nil }.count)
    }

    override init(frame frameRect: NSRect) {
        host = PassthroughHostingView(rootView: RadialWheelView(items: [], highlighted: nil, title: "", emptyMessage: "", emptyDetail: "", geometry: RadialGeometry(count: 0)))
        super.init(frame: frameRect)
        let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        registerForDraggedTypes([.fileURL, NSPasteboard.PasteboardType("com.apple.finder.node")] + promiseTypes)
        wantsLayer = true
        host.sizingOptions = []
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError("Not supported") }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        host.frame = NSRect(x: center.x - discRadius, y: center.y - discRadius, width: discRadius * 2, height: discRadius * 2)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    private func refresh() {
        let title: String
        if let highlighted, highlighted < items.count {
            title = items[highlighted].label
        } else {
            title = items.count == 1 && items[0].isEnabled ? items[0].label : mode.centerTitle
        }
        host.rootView = RadialWheelView(
            items: items,
            highlighted: highlighted,
            title: title,
            emptyMessage: emptyMessage,
            emptyDetail: subtitle,
            geometry: geometry
        )
    }

    func index(at point: NSPoint) -> Int? {
        geometry.index(at: CGPoint(x: point.x - center.x, y: point.y - center.y))
    }

    func updateHighlight(forWindowPoint point: NSPoint) {
        highlighted = index(at: convert(point, from: nil))
    }

    func updateHighlight(forScreenPoint point: NSPoint) {
        guard let window else { return }
        let local = NSPoint(x: point.x - window.frame.minX, y: point.y - window.frame.minY)
        updateHighlight(forWindowPoint: local)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragEntered?(sender)
        updateHighlight(forWindowPoint: sender.draggingLocation)
        return highlighted.flatMap { items.indices.contains($0) && items[$0].isEnabled ? .copy : nil } ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        // The panel can appear underneath an already-active Finder drag, so
        // draggingEntered may never fire for this view.
        onDragEntered?(sender)
        updateHighlight(forWindowPoint: sender.draggingLocation)
        return highlighted.flatMap { items.indices.contains($0) && items[$0].isEnabled ? .copy : nil } ?? []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        DragDebug.log("prepareForDragOperation highlighted=\(String(describing: highlighted)) mask=\(sender.draggingSourceOperationMask.rawValue)")
        return highlighted.flatMap { items.indices.contains($0) ? items[$0].isEnabled : nil } ?? false
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlighted = nil
        guard let window, sender != nil, NSEvent.pressedMouseButtons & 1 == 1 else { return }
        if window.frame.insetBy(dx: 1, dy: 1).contains(NSEvent.mouseLocation) {
            onDragSessionEnded?()
        }
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        highlighted = nil
        onDragSessionEnded?()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDragEntered?(sender)
        updateHighlight(forWindowPoint: sender.draggingLocation)
        DragDebug.log("performDragOperation highlighted=\(String(describing: highlighted)) mask=\(sender.draggingSourceOperationMask.rawValue)")
        guard let highlighted, highlighted < items.count, items[highlighted].isEnabled else {
            onCancel?()
            return false
        }
        let item = items[highlighted]
        DispatchQueue.main.async { [weak self] in self?.onSelect?(item) }
        return true
    }

    override func mouseMoved(with event: NSEvent) {
        guard interactive else { return }
        updateHighlight(forWindowPoint: event.locationInWindow)
    }

    override func mouseDown(with event: NSEvent) {
        guard interactive else { return }
        updateHighlight(forWindowPoint: event.locationInWindow)
        if let highlighted, highlighted < items.count, items[highlighted].isEnabled {
            onSelect?(items[highlighted])
        } else {
            onCancel?()
        }
    }

    override func keyDown(with event: NSEvent) {
        guard interactive else { return }
        switch event.keyCode {
        case 53:
            onCancel?()
        case 36, 76:
            if let highlighted, highlighted < items.count, items[highlighted].isEnabled { onSelect?(items[highlighted]) }
        case 123, 126:
            step(-1)
        case 124, 125:
            step(1)
        default:
            super.keyDown(with: event)
        }
    }

    private func step(_ delta: Int) {
        guard !items.isEmpty else { return }
        let current = highlighted ?? -1
        var next = (current + delta) % items.count
        if next < 0 { next += items.count }
        highlighted = next
    }

    func clearHighlight() { highlighted = nil }

    func highlight(_ index: Int) {
        highlighted = items.indices.contains(index) ? index : nil
    }
}
