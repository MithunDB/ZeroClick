import AppKit
import SwiftUI

@MainActor
struct UpscaleImageToolView: View {
    let session: ToolSession
    @State private var models = UpscaleModelCatalog.availableModels
    @State private var selectedModelID = UpscaleModelCatalog.availableModels.first?.id ?? ""
    @State private var scale = 4.0
    @State private var outputFormat: FileFormat = .png
    @State private var beforeImage: NSImage?
    @State private var afterImage: NSImage?
    @State private var previewFolder: URL?
    @State private var previewTask: Task<Void, Never>?
    @State private var previewBusy = false
    @State private var previewIndex = 0
    @State private var message: String?
    @State private var maximumScale = 0
    @State private var checkingInput = true

    private var selectedModel: UpscaleModel? { models.first { $0.id == selectedModelID } }
    private var previewSource: URL { session.files[min(previewIndex, session.files.count - 1)] }
    private var preflightID: String { selectedModelID + "|" + previewSource.path }
    private var cappedScale: Binding<Double> {
        Binding(get: { scale }, set: { scale = min($0, Double(max(2, maximumScale))) })
    }

    var body: some View {
        ToolShell(session: session, saveTitle: session.files.count == 1 ? "Upscale copy" : "Upscale \(session.files.count) copies",
                  saveEnabled: selectedModel != nil && maximumScale >= 2 && UpscaleEngine.executable != nil, onSave: run) {
            VStack(spacing: 12) {
                HStack {
                    Text(previewSource.lastPathComponent)
                        .font(.headline).lineLimit(1)
                    Spacer()
                    if session.files.count > 1 {
                        Button { previewIndex -= 1 } label: { Image(systemName: "chevron.left") }
                            .disabled(previewIndex == 0)
                            .accessibilityLabel("Previous image")
                        Text("\(previewIndex + 1) of \(session.files.count)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Button { previewIndex += 1 } label: { Image(systemName: "chevron.right") }
                            .disabled(previewIndex == session.files.count - 1)
                            .accessibilityLabel("Next image")
                    }
                    Button(previewBusy ? "Preparing…" : "Generate preview", action: generatePreview)
                        .disabled(previewBusy || selectedModel == nil || maximumScale < 2)
                }
                HStack(spacing: 12) {
                    previewPane(title: "Before", image: beforeImage)
                    previewPane(title: "After", image: afterImage)
                }
                if session.files.count > 1 {
                    Text("All \(session.files.count) selected images will be processed. Use the arrows to preview each image.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(16)
        } sidebar: {
            SidebarSection(title: "Model") {
                Picker("", selection: $selectedModelID) {
                    ForEach(models) { model in
                        Text(model.displayName)
                            .tag(model.id)
                    }
                }
                .labelsHidden()
                Button("Import local model…", action: importModel)
                FormHint("Optional .param and .bin files stay in Application Support. The bundled fast model favors illustrations; photos may look softer.")
            }
            SidebarSection(title: "Output") {
                HStack {
                    Text("Amount")
                    // A zero-width Slider range (2...2) can spin SwiftUI's
                    // layout before preflight completes. Keep its range stable.
                    Slider(value: cappedScale, in: 2...8, step: 1)
                        .disabled(maximumScale < 2)
                        .accessibilityLabel("Upscale amount")
                        .accessibilityValue("\(Int(scale)) times")
                    Text("\(Int(scale))×").monospacedDigit().frame(width: 34, alignment: .trailing)
                }
                if checkingInput {
                    FormHint("Checking image dimensions…")
                } else if maximumScale < 8 {
                    FormHint(maximumScale < 2 ? "This image is too large to upscale safely." :
                             "This image can be upscaled to \(maximumScale)× with the current memory limit.")
                } else {
                    FormHint("5×–8× uses another local model pass and takes longer.")
                }
                Picker("Format", selection: $outputFormat) {
                    Text("PNG").tag(FileFormat.png)
                    Text("JPG").tag(FileFormat.jpg)
                    Text("WebP").tag(FileFormat.webp)
                }
                FormHint("New copies use collision-safe names. Originals are never overwritten. Progress and cancellation appear after starting.")
            }
            if let message { Text(message).font(.caption).foregroundStyle(.red) }
        }
        .task(id: preflightID) { await preflightInput() }
        .onChange(of: selectedModelID) { _ in clearPreview() }
        .onChange(of: scale) { _ in clearPreview() }
        .onChange(of: previewIndex) { _ in clearPreview() }
        .onDisappear { clearPreview() }
    }

    @ViewBuilder
    private func previewPane(title: String, image: NSImage?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Group {
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    ContentUnavailableView(title == "After" ? "Generate a preview" : "No image", systemImage: "photo")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func preflightInput() async {
        checkingInput = true
        maximumScale = 0
        beforeImage = nil
        guard let model = selectedModel else { checkingInput = false; return }
        let files = session.files
        let source = previewSource
        let result = await Task.detached(priority: .utility) { () -> (Int, Data?) in
            let safeScale = UpscaleEngine.maximumSafeScale(for: files, model: model)
            let preview = safeScale >= 2 ? ImageIOBridge.boundedPreviewData(source, maxPixelSize: 512) : nil
            return (safeScale, preview)
        }.value
        guard !Task.isCancelled else { return }
        maximumScale = result.0
        beforeImage = result.1.flatMap(NSImage.init(data:))
        scale = min(scale, Double(max(2, result.0)))
        checkingInput = false
    }

    private func generatePreview() {
        guard let model = selectedModel else { return }
        clearPreview()
        message = nil
        previewBusy = true
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zeroclick-upscale-preview-\(UUID().uuidString)", isDirectory: true)
        previewFolder = folder
        let source = previewSource
        let requestedScale = Int(scale)
        previewTask = Task {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                let small = folder.appendingPathComponent("before.png")
                guard let previewData = await Task.detached(priority: .utility,
                    operation: { ImageIOBridge.boundedPreviewData(source, maxPixelSize: 384) }).value else {
                    throw SatsumaError.unreadable(source)
                }
                try Task.checkCancellation()
                try previewData.write(to: small)
                let target = folder.appendingPathComponent("after.png")
                let produced = try await UpscaleEngine.upscale(source: small, destination: target, model: model,
                                                                 scale: requestedScale, format: .png)
                try Task.checkCancellation()
                let afterData = await Task.detached(priority: .utility,
                    operation: { ImageIOBridge.boundedPreviewData(produced, maxPixelSize: 512) }).value
                try Task.checkCancellation()
                afterImage = afterData.flatMap(NSImage.init(data:))
            } catch is CancellationError {
                // A changed control or closed window owns the cleanup.
            } catch {
                message = error.localizedDescription
            }
            previewBusy = false
        }
    }

    private func clearPreview() {
        previewTask?.cancel()
        previewTask = nil
        afterImage = nil
        if let previewFolder { try? FileManager.default.removeItem(at: previewFolder) }
        previewFolder = nil
        previewBusy = false
    }

    private func importModel() {
        let panel = NSOpenPanel()
        panel.message = "Choose the .param file. A .bin file with the same name must be beside it."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let parameter = panel.url else { return }
        let weights = parameter.deletingPathExtension().appendingPathExtension("bin")
        do {
            let imported = try UpscaleModelCatalog.importPair(parameter: parameter, weights: weights)
            models = UpscaleModelCatalog.availableModels
            selectedModelID = imported.id
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    private func run() {
        guard let model = selectedModel else { return }
        let files = session.files
        let chosenScale = Int(scale)
        let chosenFormat = outputFormat
        let destinations = UpscaleEngine.destinations(for: files, scale: chosenScale, format: chosenFormat) { source in
            AppSettings.shared.outputLocation.directory(for: source)
        }
        session.run(title: "Upscaling", detail: files.count == 1 ? files[0].lastPathComponent : "\(files.count) images") { progress in
            try await UpscaleEngine.upscaleBatch(files: files, destinations: destinations, model: model,
                                                 scale: chosenScale, format: chosenFormat, progress: progress)
        }
    }
}
