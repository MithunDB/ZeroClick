import CoreImage
import SwiftUI

enum RedactionSelection {
    static func activeID(_ requested: UUID?, among areas: [RectangleOverlay], newlyAdded: Set<UUID> = []) -> UUID? {
        if let newest = areas.last(where: { newlyAdded.contains($0.id) }) { return newest.id }
        if let requested, areas.contains(where: { $0.id == requested }) { return requested }
        return areas.last?.id
    }
}

@MainActor
struct RedactImageToolView: View {
    let session: ToolSession
    @StateObject private var document: ImageDocument
    @State private var rects: [RectangleOverlay] = []
    @State private var selected: UUID?
    @State private var styles: [UUID: RedactionStyle] = [:]
    @State private var strengths: [UUID: Double] = [:]
    @State private var defaultStyle: RedactionStyle = .solid
    @State private var defaultStrength: Double = 1
    @State private var color = Color.black
    @State private var showPreview = false
    @State private var confirmExport = false
    @State private var detecting = false
    @State private var detectionMessage: String?
    @State private var rendered: NSImage?
    @State private var renderTask: Task<Void, Never>?
    @State private var renderGeneration = 0

    init(session: ToolSession) {
        self.session = session
        _document = StateObject(wrappedValue: ImageDocument(url: session.primary, previewMaxPixels: 2000))
    }

    private var activeID: UUID? { RedactionSelection.activeID(selected, among: rects) }

    private var redactions: [Redaction] {
        rects.map { overlay in
            var r = Redaction(rect: overlay.rect)
            r.style = styles[overlay.id] ?? defaultStyle
            r.strength = strengths[overlay.id] ?? defaultStrength
            r.color = color.nsColor.cgColor
            return r
        }
    }

    var body: some View {
        ToolShell(session: session, saveEnabled: !rects.isEmpty, onSave: { confirmExport = true }) {
            ZStack {
                CheckerboardBackground()
                if let preview = document.preview {
                    if showPreview, let rendered {
                        GeometryReader { proxy in
                            let fit = FitGeometry(container: proxy.size, image: document.size)
                            Image(nsImage: rendered).resizable().interpolation(.high)
                                .frame(width: fit.displayRect.width, height: fit.displayRect.height)
                                .offset(x: fit.displayRect.minX, y: fit.displayRect.minY)
                        }
                        .padding(12)
                    } else {
                        RectangleEditorCanvas(image: preview, imageSize: document.size, rectangles: $rects, selected: $selected, allowMultiple: true)
                            .padding(12)
                    }
                } else {
                    LoadingOrError(error: document.error)
                }
            }
        } sidebar: {
            SidebarSection(title: "Redaction style") {
                Picker("", selection: styleBinding) {
                    ForEach(RedactionStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .accessibilityLabel("Redaction style")
                if (activeID.flatMap { styles[$0] } ?? defaultStyle) == .solid {
                    ColorSwatchPicker(title: "Color", color: $color)
                } else {
                    HStack {
                        Text("Strength")
                        Slider(value: strengthBinding, in: 1...8, step: 0.5)
                            .accessibilityLabel("Redaction strength")
                            .accessibilityValue("\(strengthBinding.wrappedValue.formatted(.number.precision(.fractionLength(1)))) times")
                        Text("\(strengthBinding.wrappedValue.formatted(.number.precision(.fractionLength(1))))×")
                            .monospacedDigit().frame(width: 42, alignment: .trailing)
                    }
                    Text("Increase blur radius or pixel block size. For sensitive text, use Solid.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text(activeID == nil ? "Applies to new areas." : "Applies to the selected area.").font(.caption2).foregroundStyle(.secondary)
            }
            SidebarSection(title: "Areas (\(rects.count))") {
                HStack {
                    Button("Suggest faces") { suggest(.faces) }.disabled(detecting || document.preview == nil)
                    Button("Suggest text") { suggest(.text) }.disabled(detecting || document.preview == nil)
                }
                if detecting { ProgressView("Finding areas…") }
                if let detectionMessage { Text(detectionMessage).font(.caption2).foregroundStyle(.secondary) }
                Text("Suggestions may miss content. Review and adjust every area before exporting.")
                    .font(.caption2).foregroundStyle(.secondary)
                if rects.isEmpty {
                    Text("Drag on the photo to cover an area. Drag areas to move them and their corners to resize.").font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(rects) { overlay in
                    HStack {
                        Circle().fill(overlay.id == activeID ? Color.orange : Color.secondary).frame(width: 8, height: 8)
                        Text("Area \(overlay.label)").font(.callout)
                        Text((styles[overlay.id] ?? defaultStyle).title).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { remove(overlay.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selected = overlay.id }
                }
                if !rects.isEmpty {
                    Button("Remove all") { rects.removeAll(); styles.removeAll(); strengths.removeAll(); selected = nil }.controlSize(.small)
                }
            }
            SidebarSection(title: "Preview") {
                Toggle("Show result", isOn: $showPreview)
            }
        }
        .onChange(of: rects) { _ in
            let added = captureNewAreaSettings()
            selected = RedactionSelection.activeID(selected, among: rects, newlyAdded: added)
            relabel()
            scheduleRender()
        }
        .onChange(of: selected) { _ in restoreSelection() }
        .onChange(of: styles) { _ in scheduleRender() }
        .onChange(of: strengths) { _ in scheduleRender() }
        .onChange(of: defaultStrength) { _ in scheduleRender() }
        .onChange(of: color) { _ in scheduleRender() }
        .onChange(of: defaultStyle) { _ in scheduleRender() }
        .onChange(of: showPreview) { _ in scheduleRender() }
        .onDeleteCommand { if let activeID { remove(activeID) } }
        .alert("Export redacted copy?", isPresented: $confirmExport) {
            Button("Export Copy") { save() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Review every covered area. This creates a new file and keeps the original. Blur may not conceal sensitive details.")
        }
    }

    private var styleBinding: Binding<RedactionStyle> {
        Binding(
            get: { activeID.flatMap { styles[$0] } ?? defaultStyle },
            set: { new in
                if let activeID { styles[activeID] = new } else { defaultStyle = new }
                scheduleRender()
            }
        )
    }

    private var strengthBinding: Binding<Double> {
        Binding(
            get: { activeID.flatMap { strengths[$0] } ?? defaultStrength },
            set: { new in
                if let activeID { strengths[activeID] = new } else { defaultStrength = new }
                scheduleRender()
            }
        )
    }

    private func remove(_ id: UUID) {
        rects.removeAll { $0.id == id }
        styles.removeValue(forKey: id)
        strengths.removeValue(forKey: id)
        restoreSelection()
    }

    private func restoreSelection() {
        let active = activeID
        if selected != active { selected = active }
    }

    private func captureNewAreaSettings() -> Set<UUID> {
        var added: Set<UUID> = []
        for overlay in rects where styles[overlay.id] == nil {
            styles[overlay.id] = defaultStyle
            strengths[overlay.id] = defaultStrength
            added.insert(overlay.id)
        }
        return added
    }

    private func relabel() {
        for index in rects.indices where rects[index].label != "\(index + 1)" {
            rects[index].label = "\(index + 1)"
        }
    }

    private func scheduleRender() {
        renderTask?.cancel()
        renderGeneration += 1
        let generation = renderGeneration
        guard showPreview, let preview = document.preview, let cg = preview.cgImage(forProposedRect: nil, context: nil, hints: nil), document.size.width > 0 else { return }
        let scale = CGFloat(cg.width) / document.size.width
        let scaled = redactions.map { r -> Redaction in
            var copy = r
            copy.rect = r.rect.applying(CGAffineTransform(scaleX: scale, y: scale))
            return copy
        }
        renderTask = Task.detached(priority: .userInitiated) {
            let output = ImageOps.redact(CIImage(cgImage: cg), redactions: scaled)
            guard !Task.isCancelled, let image = ImageToolSupport.cgImage(output) else { return }
            let ns = ImageOps.nsImage(image)
            await MainActor.run {
                guard generation == renderGeneration else { return }
                rendered = ns
            }
        }
    }

    private func save() {
        guard !rects.isEmpty, let original = document.original else { return }
        let redactions = redactions
        ImageToolSupport.save(session, suffix: "redacted", preserveMetadata: false) {
            let output = ImageOps.redact(CIImage(cgImage: original), redactions: redactions)
            guard let image = ImageToolSupport.cgImage(output) else { throw SatsumaError.encodeFailed("Rendering failed") }
            return image
        }
    }

    private func suggest(_ kind: RedactionSuggestions.Kind) {
        guard let preview = document.preview,
              let image = preview.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        detecting = true
        detectionMessage = nil
        Task.detached(priority: .userInitiated) {
            do {
                let found = try RedactionSuggestions.detect(kind, in: image)
                await MainActor.run {
                    let size = document.size
                    let scaleX = size.width / CGFloat(image.width)
                    let scaleY = size.height / CGFloat(image.height)
                    let color: Color = kind == .faces ? .orange : .yellow
                    for rect in found {
                        let scaled = CGRect(x: rect.minX * scaleX, y: rect.minY * scaleY,
                                            width: rect.width * scaleX, height: rect.height * scaleY)
                        rects.append(RectangleOverlay(id: UUID(), rect: scaled, color: color, label: ""))
                    }
                    if !found.isEmpty { selected = rects.last?.id }
                    detectionMessage = found.isEmpty ? "No areas found. Add areas manually if needed." : "Added \(found.count) suggested area\(found.count == 1 ? "" : "s"). Review each one."
                    detecting = false
                }
            } catch {
                await MainActor.run {
                    detectionMessage = "Detection failed: \(error.localizedDescription)"
                    detecting = false
                }
            }
        }
    }
}
