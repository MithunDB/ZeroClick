import AppKit
import SwiftUI

/// AppKit's magnification keeps the image point under a trackpad pinch fixed.
struct OCRSelectablePreview: NSViewRepresentable {
    let image: NSImage
    let lines: [SearchablePDF.TextLine]
    let query: String
    @Binding var zoom: Double

    func makeCoordinator() -> Coordinator { Coordinator(zoom: $zoom) }

    func makeNSView(context: Context) -> OCRMagnifyingScrollView {
        let scroll = OCRMagnifyingScrollView()
        scroll.allowsMagnification = true
        scroll.minMagnification = 1
        scroll.maxMagnification = 4
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.documentView = OCRImageCanvas()
        context.coordinator.observe(scroll)
        return scroll
    }

    func updateNSView(_ scroll: OCRMagnifyingScrollView, context: Context) {
        scroll.canvas?.configure(image: image, lines: lines, query: query)
        scroll.sizeDocumentToViewport()
        if !context.coordinator.isPinching && abs(Double(scroll.magnification) - zoom) > 0.005 {
            let visible = scroll.contentView.documentVisibleRect
            scroll.setMagnification(CGFloat(zoom), centeredAt: NSPoint(x: visible.midX, y: visible.midY))
        }
    }

    final class Coordinator {
        var zoom: Binding<Double>
        var isPinching = false
        private var observers: [NSObjectProtocol] = []

        init(zoom: Binding<Double>) { self.zoom = zoom }

        func observe(_ scroll: NSScrollView) {
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSScrollView.willStartLiveMagnifyNotification,
                                                object: scroll, queue: .main) { [weak self] _ in
                self?.isPinching = true
            })
            observers.append(center.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification,
                                                object: scroll, queue: .main) { [weak self, weak scroll] _ in
                self?.isPinching = false
                if let scroll { self?.zoom.wrappedValue = Double(scroll.magnification) }
            })
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}

final class OCRMagnifyingScrollView: NSScrollView {
    var canvas: OCRImageCanvas? { documentView as? OCRImageCanvas }
    private var viewportSize: NSSize = .zero

    override func layout() {
        super.layout()
        sizeDocumentToViewport()
    }

    func sizeDocumentToViewport() {
        let size = contentSize
        guard size.width > 0, size.height > 0,
              abs(size.width - viewportSize.width) > 0.5 || abs(size.height - viewportSize.height) > 0.5 else { return }
        viewportSize = size
        canvas?.frame = NSRect(origin: .zero, size: size)
        canvas?.needsLayout = true
    }
}

final class OCRImageCanvas: NSView {
    private struct Token {
        let text: String
        let box: CGRect
        let lineIndex: Int
        let wordIndex: Int
    }

    private var currentImage: NSImage?
    private var currentLines: [SearchablePDF.TextLine] = []
    private var tokens: [Token] = []
    private var currentQuery = ""
    private var imageFrame: CGRect = .zero
    private var selection: ClosedRange<Int>?
    private var selectionAnchor: Int?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    func configure(image: NSImage, lines: [SearchablePDF.TextLine], query: String) {
        if currentImage !== image || currentLines != lines {
            currentImage = image
            currentLines = lines
            tokens = lines.enumerated().flatMap { index, line in
                let words = line.words.isEmpty
                    ? [SearchablePDF.TextWord(text: line.text, normalizedBox: line.normalizedBox)]
                    : line.words
                return words.enumerated().flatMap { wordIndex, word -> [Token] in
                    let glyphs = word.glyphs.isEmpty
                        ? fallbackGlyphs(for: word)
                        : word.glyphs
                    return glyphs.map { Token(text: $0.text, box: $0.normalizedBox,
                                              lineIndex: index, wordIndex: wordIndex) }
                }
            }
            selection = nil
            selectionAnchor = nil
            needsLayout = true
        }
        if currentQuery != query {
            currentQuery = query
            needsDisplay = true
        }
    }

    override func layout() {
        super.layout()
        guard let image = currentImage, image.size.width > 0, image.size.height > 0 else { return }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        imageFrame = CGRect(x: (bounds.width - size.width) / 2,
                            y: (bounds.height - size.height) / 2,
                            width: size.width, height: size.height)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let image = currentImage else { return }
        image.draw(in: imageFrame)
        for index in tokens.indices {
            let rect = rect(for: tokens[index].box)
            let matches = !currentQuery.isEmpty &&
                currentLines[tokens[index].lineIndex].text.localizedCaseInsensitiveContains(currentQuery)
            if matches {
                NSColor.systemYellow.withAlphaComponent(0.38).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
            }
            if selection?.contains(index) == true {
                NSColor.selectedTextBackgroundColor.withAlphaComponent(0.65).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let index = tokenIndex(at: point, nearest: false) else {
            selection = nil
            selectionAnchor = nil
            needsDisplay = true
            return
        }
        selectToken(at: index)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = tokenIndex(at: point, nearest: true) else { return }
        selectThroughToken(at: index)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "c",
           selection != nil {
            copy(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc func copy(_ sender: Any?) {
        let text = selectedText
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(text, forType: .string) {
            try? QuickActionHistory.recordSuccess(.tool(.makeSearchable), in: .tools)
        }
    }

    var selectedText: String {
        guard let selection else { return "" }
        var result = ""
        var previousToken: Token?
        for index in selection {
            let token = tokens[index]
            if let previousToken {
                if previousToken.lineIndex != token.lineIndex { result += "\n" }
                else if previousToken.wordIndex != token.wordIndex { result += " " }
            }
            result += token.text
            previousToken = token
        }
        return result
    }

    var selectableCharacters: [String] { tokens.map(\.text) }

    func selectToken(at index: Int) {
        guard tokens.indices.contains(index) else { return }
        selectionAnchor = index
        selection = index...index
        needsDisplay = true
    }

    func selectThroughToken(at index: Int) {
        guard let anchor = selectionAnchor, tokens.indices.contains(index) else { return }
        selection = min(anchor, index)...max(anchor, index)
        needsDisplay = true
    }

    func tokenFrame(at index: Int) -> CGRect? {
        guard tokens.indices.contains(index) else { return nil }
        return rect(for: tokens[index].box)
    }

    private func rect(for box: CGRect) -> CGRect {
        CGRect(x: imageFrame.minX + box.minX * imageFrame.width,
               y: imageFrame.minY + box.minY * imageFrame.height,
               width: max(2, box.width * imageFrame.width),
               height: max(2, box.height * imageFrame.height))
    }

    private func tokenIndex(at point: CGPoint, nearest: Bool) -> Int? {
        let hits = tokens.indices.filter { rect(for: tokens[$0].box).contains(point) }
        if let hit = hits.min(by: { left, right in
            abs(rect(for: tokens[left].box).midX - point.x) <
                abs(rect(for: tokens[right].box).midX - point.x)
        }) {
            return hit
        }
        guard nearest, !tokens.isEmpty else { return nil }
        return tokens.indices.min { left, right in
            let a = rect(for: tokens[left].box), b = rect(for: tokens[right].box)
            return hypot(point.x - a.midX, point.y - a.midY) < hypot(point.x - b.midX, point.y - b.midY)
        }
    }

    private func fallbackGlyphs(for word: SearchablePDF.TextWord) -> [SearchablePDF.TextGlyph] {
        let characters = Array(word.text).map(String.init)
        guard !characters.isEmpty else { return [] }
        return characters.enumerated().map { index, character in
            let width = word.normalizedBox.width / CGFloat(characters.count)
            return SearchablePDF.TextGlyph(text: character,
                normalizedBox: CGRect(x: word.normalizedBox.minX + CGFloat(index) * width,
                                      y: word.normalizedBox.minY, width: width,
                                      height: word.normalizedBox.height))
        }
    }
}
