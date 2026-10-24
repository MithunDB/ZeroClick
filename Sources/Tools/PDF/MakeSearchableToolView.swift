import AppKit
import SwiftUI

@MainActor
struct MakeSearchableToolView: View {
    let session: ToolSession
    @State private var recognizedText = ""
    @State private var scanning = false
    @State private var message: String?
    @State private var scanTask: Task<[SearchablePDF.ScannedPage], Error>?
    @State private var pages: [SearchablePDF.ScannedPage] = []
    @State private var pageIndex = 0
    @State private var displayImage: NSImage?
    @State private var searchQuery = ""
    @State private var previewZoom = 1.0

    private var matchingPages: [Int] {
        guard !searchQuery.isEmpty else { return [] }
        return pages.indices.filter { index in
            pages[index].text.localizedCaseInsensitiveContains(searchQuery)
                || pages[index].lines.contains { $0.text.localizedCaseInsensitiveContains(searchQuery) }
        }
    }

    private var uncertainLineCount: Int { pages.reduce(0) { $0 + $1.uncertainLineCount } }

    var body: some View {
        FormShell(session: session, saveTitle: "Save searchable PDF copy", saveEnabled: !scanning, onSave: save) {
            FormHeading("Make searchable")
            FormHint("Scan locally, select letters on the image, search the scan, or copy the text. A PDF copy is saved only when you choose it.")
            HStack(spacing: 12) {
                Button(scanning ? "Scanning…" : "Scan text") { scan() }
                    .disabled(scanning)
                Button("Copy text") { copyText() }
                    .disabled(recognizedText.isEmpty || scanning)
                if scanning { ProgressView().controlSize(.small) }
            }
            if !pages.isEmpty {
                if uncertainLineCount > 0 {
                    Label("\(uncertainLineCount) scanned line\(uncertainLineCount == 1 ? "" : "s") may be inaccurate. Check the preview or edit the copied text before using it.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                HStack(spacing: 10) {
                    TextField("Find a word or phrase in scan", text: $searchQuery)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Find in scanned text")
                    Text(searchQuery.isEmpty ? "" : "\(matchingPages.count) page\(matchingPages.count == 1 ? "" : "s")")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button("Previous match") { selectMatch(backward: true) }
                        .disabled(matchingPages.isEmpty)
                    Button("Next match") { selectMatch(backward: false) }
                        .disabled(matchingPages.isEmpty)
                }
                if pages.count > 1 {
                    HStack {
                        Button("Previous page") { pageIndex -= 1; loadPageImage() }
                            .disabled(pageIndex == 0)
                        Text("Page \(pageIndex + 1) of \(pages.count)")
                            .font(.caption.monospacedDigit())
                        Button("Next page") { pageIndex += 1; loadPageImage() }
                            .disabled(pageIndex == pages.count - 1)
                    }
                }
                if let displayImage, pages.indices.contains(pageIndex) {
                    HStack(spacing: 10) {
                        Button { previewZoom = max(1, previewZoom - 0.25) } label: {
                            Image(systemName: "minus.magnifyingglass")
                        }
                        .disabled(previewZoom <= 1)
                        .accessibilityLabel("Zoom out scanned image")
                        Slider(value: $previewZoom, in: 1...4, step: 0.25)
                            .accessibilityLabel("Scanned image zoom")
                        Button { previewZoom = min(4, previewZoom + 0.25) } label: {
                            Image(systemName: "plus.magnifyingglass")
                        }
                        .disabled(previewZoom >= 4)
                        .accessibilityLabel("Zoom in scanned image")
                        Text("\(Int(previewZoom * 100))%")
                            .font(.caption.monospacedDigit())
                            .frame(width: 44, alignment: .trailing)
                        Button("Fit") { previewZoom = 1 }
                            .disabled(previewZoom == 1)
                    }
                    OCRSelectablePreview(image: displayImage, lines: pages[pageIndex].lines,
                                         query: searchQuery, zoom: $previewZoom)
                        .frame(height: 310)
                        .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("Scanned page with selectable text")
                    Text("Pinch with two fingers at the area you want to enlarge, or use the slider. Drag across letters and press Command-C to copy the highlighted text. Search highlights matches; the image stays unchanged.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("All recognized text · editable for copying")
                .font(.caption.weight(.semibold))
            TextEditor(text: $recognizedText)
                .font(.body)
                .frame(height: 150)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .accessibilityLabel("Recognized text; editable for copying")
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Text("Edits here affect copied text. PDF export recognizes the original again to align invisible text with the page. Unclear print and handwriting may be inaccurate.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onDisappear { scanTask?.cancel() }
    }

    private func scan() {
        let source = session.primary
        scanning = true
        message = nil
        let work = Task.detached(priority: .userInitiated) {
            try SearchablePDF.scanPages(from: source)
        }
        scanTask = work
        Task {
            do {
                let scanned = try await work.value
                pages = scanned
                pageIndex = 0
                previewZoom = 1
                recognizedText = scanned.map(\.text).joined(separator: "\n\n")
                loadPageImage()
                message = recognizedText.isEmpty ? "No text was found. Try a clearer image or page." : nil
            } catch is CancellationError {
                message = nil
            } catch {
                message = error.localizedDescription
            }
            scanning = false
            scanTask = nil
        }
    }

    private func loadPageImage() {
        do {
            displayImage = try SearchablePDF.displayImage(from: session.primary, pageIndex: pageIndex)
        } catch {
            displayImage = nil
            message = error.localizedDescription
        }
    }

    private func selectMatch(backward: Bool) {
        guard !matchingPages.isEmpty else { return }
        let candidate = backward
            ? matchingPages.last(where: { $0 < pageIndex }) ?? matchingPages.last!
            : matchingPages.first(where: { $0 > pageIndex }) ?? matchingPages.first!
        pageIndex = candidate
        loadPageImage()
    }

    private func copyText() {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(recognizedText, forType: .string) {
            message = "Text copied. The source file was not changed."
            try? QuickActionHistory.recordSuccess(.tool(.makeSearchable), in: .tools)
        } else {
            message = "Could not copy text to the clipboard."
        }
    }

    private func save() {
        let source = session.primary
        let destination = session.outputURL(suffix: "searchable", ext: "pdf")
        session.run(title: "Making searchable", detail: source.lastPathComponent) { progress in
            progress(0.1)
            let worker = Task.detached(priority: .userInitiated) {
                try OutputWriter.write(to: destination) { staged in
                    try SearchablePDF.create(from: source, to: staged)
                }
            }
            let result = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            progress(1)
            return [result]
        }
    }
}
