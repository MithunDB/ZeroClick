import AppKit
import CoreText
import PDFKit
import Vision

enum SearchablePDF {
    struct TextGlyph: Equatable {
        let text: String
        let normalizedBox: CGRect
    }

    struct TextWord: Equatable {
        let text: String
        let normalizedBox: CGRect
        var glyphs: [TextGlyph] = []
    }

    struct TextLine: Equatable {
        let text: String
        let normalizedBox: CGRect
        let confidence: Float
        var words: [TextWord] = []

        var needsReview: Bool { confidence < 0.6 }
    }

    struct ScannedPage {
        let number: Int
        let text: String
        let lines: [TextLine]

        var uncertainLineCount: Int { lines.filter(\.needsReview).count }
    }

    /// OCR coordinates are kept in memory for selecting text over a preview.
    /// This scan does not create or modify any file.
    static func scanPages(from source: URL) throws -> [ScannedPage] {
        if FileFormat.detect(source) == .pdf {
            let document = try readablePDF(source)
            return try (0..<document.pageCount).map { index in
                try Task.checkCancellation()
                guard let page = document.page(at: index) else { throw SatsumaError.unreadable(source) }
                let native = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let lines = native.isEmpty
                    ? try recognize(in: previewImage(for: page, index: index))
                    : nativeLines(for: page)
                return ScannedPage(number: index + 1,
                                   text: native.isEmpty ? lines.map(\.text).joined(separator: "\n") : native,
                                   lines: lines)
            }
        }
        guard let format = FileFormat.detect(source), format.category == .image else {
            throw SatsumaError.invalidInput("Choose a supported image or PDF.")
        }
        let lines = try recognize(in: ImageIOBridge.load(source, maxPixelSize: 2400))
        return [ScannedPage(number: 1, text: lines.map(\.text).joined(separator: "\n"), lines: lines)]
    }

    static func displayImage(from source: URL, pageIndex: Int) throws -> NSImage {
        if FileFormat.detect(source) == .pdf {
            let document = try readablePDF(source)
            guard let page = document.page(at: pageIndex) else { throw SatsumaError.unreadable(source) }
            let bounds = page.bounds(for: .mediaBox)
            let scale = min(2, 1600 / max(bounds.width, bounds.height, 1))
            return page.thumbnail(of: CGSize(width: max(1, bounds.width * scale),
                                             height: max(1, bounds.height * scale)), for: .mediaBox)
        }
        let image = try ImageIOBridge.load(source, maxPixelSize: 1600)
        return NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
    }

    /// OCR for the temporary editor/clipboard path. This method writes no files.
    static func extractText(from source: URL) throws -> String {
        if FileFormat.detect(source) == .pdf {
            let document = try readablePDF(source)
            var pages: [String] = []
            for index in 0..<document.pageCount {
                try Task.checkCancellation()
                guard let page = document.page(at: index) else { continue }
                if let existing = page.string, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    pages.append(existing)
                } else {
                    pages.append(try recognize(in: previewImage(for: page, index: index)).map(\.text).joined(separator: "\n"))
                }
            }
            return pages.joined(separator: "\n\n")
        }
        guard let format = FileFormat.detect(source), format.category == .image else {
            throw SatsumaError.invalidInput("Choose a supported image or PDF.")
        }
        let image = try ImageIOBridge.load(source, maxPixelSize: 2400)
        return try recognize(in: image).map(\.text).joined(separator: "\n")
    }

    static func create(from source: URL, to destination: URL) throws {
        if FileFormat.detect(source) == .pdf {
            try createFromPDF(source, to: destination)
        } else {
            try createFromImage(source, to: destination)
        }
        guard let result = PDFDocument(url: destination), result.pageCount > 0,
              !(result.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SatsumaError.encodeFailed("The PDF text layer could not be verified.")
        }
    }

    private static func createFromImage(_ source: URL, to destination: URL) throws {
        guard let format = FileFormat.detect(source), format.category == .image else {
            throw SatsumaError.invalidInput("Choose a supported image or PDF.")
        }
        let dimensions = ImageIOBridge.pixelSize(source)
        if dimensions.width > 0 && dimensions.height > 0 && dimensions.width * dimensions.height > 36_000_000 {
            throw SatsumaError.invalidInput("This image is too large for a safe searchable-PDF export.")
        }
        try Task.checkCancellation()
        let image = try ImageIOBridge.load(source)
        let lines = try recognize(in: ImageIOBridge.load(source, maxPixelSize: 2400))
        guard !lines.isEmpty else { throw SatsumaError.invalidInput("No text was recognized in this image.") }
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2)
        var mediaBox = bounds
        guard let context = CGContext(destination as CFURL, mediaBox: &mediaBox, nil) else {
            throw SatsumaError.encodeFailed("Could not create the searchable PDF.")
        }
        context.beginPDFPage(pageInfo(for: bounds))
        context.draw(image, in: bounds)
        lines.forEach { drawInvisible($0, in: bounds, context: context) }
        context.endPDFPage()
        context.closePDF()
    }

    private static func createFromPDF(_ source: URL, to destination: URL) throws {
        let document = try readablePDF(source)
        guard document.pageCount > 0 else { throw SatsumaError.invalidInput("This PDF has no pages.") }
        // Reject before writing any page so an annotation, form or rotated page
        // cannot be silently changed by PDFKit's drawing path.
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), page.annotations.isEmpty, page.rotation == 0 else {
                throw SatsumaError.invalidInput("This PDF has annotations, form fields, or rotated pages that cannot be preserved safely yet.")
            }
        }
        var mediaBox = document.page(at: 0)!.bounds(for: .mediaBox)
        guard let context = CGContext(destination as CFURL, mediaBox: &mediaBox, nil) else {
            throw SatsumaError.encodeFailed("Could not create the searchable PDF.")
        }
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { throw SatsumaError.unreadable(source) }
            let media = page.bounds(for: .mediaBox)
            guard media.width > 0, media.height > 0 else {
                throw SatsumaError.invalidInput("Page \(index + 1) has invalid dimensions.")
            }
            let alreadyHasText = !(page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let lines = alreadyHasText ? [] : try recognize(in: previewImage(for: page, index: index))
            let outputBounds = CGRect(origin: .zero, size: media.size)
            context.beginPDFPage(pageInfo(for: outputBounds))
            context.saveGState()
            context.translateBy(x: -media.minX, y: -media.minY)
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
            lines.forEach { drawInvisible($0, in: outputBounds, context: context) }
            context.endPDFPage()
        }
        context.closePDF()
        guard let output = PDFDocument(url: destination), output.pageCount == document.pageCount else {
            throw SatsumaError.encodeFailed("The PDF page count changed during export.")
        }
    }

    private static func readablePDF(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else { throw SatsumaError.unreadable(url) }
        guard !document.isEncrypted && !document.isLocked else {
            throw SatsumaError.invalidInput("Unlock this PDF before scanning it.")
        }
        return document
    }

    private static func pageInfo(for bounds: CGRect) -> CFDictionary {
        var mediaBox = bounds
        let data = Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size)
        return [kCGPDFContextMediaBox: data as CFData] as CFDictionary
    }

    private static func previewImage(for page: PDFPage, index: Int) throws -> CGImage {
        let bounds = page.bounds(for: .mediaBox)
        let scale = min(2, 2400 / max(bounds.width, bounds.height, 1))
        let size = NSSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        guard let image = page.thumbnail(of: size, for: .mediaBox)
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw SatsumaError.invalidInput("Could not scan page \(index + 1).")
        }
        return image
    }

    private static func nativeLines(for page: PDFPage) -> [TextLine] {
        let media = page.bounds(for: .mediaBox)
        guard media.width > 0, media.height > 0 else { return [] }
        return (page.selection(for: media)?.selectionsByLine() ?? []).compactMap { selection in
            guard let rawText = selection.string,
                  !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let box = selection.bounds(for: page)
            let lineRange = selection.range(at: 0, on: page)
            let words = wordMatches(in: rawText).compactMap { match -> TextWord? in
                guard lineRange.location != NSNotFound,
                      let selectedWord = page.selection(for: NSRange(location: lineRange.location + match.range.location,
                                                                     length: match.range.length)) else { return nil }
                let wordBox = selectedWord.bounds(for: page)
                let wordText = (rawText as NSString).substring(with: match.range)
                let glyphs = characterRanges(in: wordText).map { character, offset in
                    let range = NSRange(location: lineRange.location + match.range.location + offset.location,
                                        length: offset.length)
                    let bounds = page.selection(for: range)?.bounds(for: page)
                    let usable = valid(bounds) && bounds!.width <= wordBox.width *
                        min(1, CGFloat(offset.length * 2) / CGFloat(max(1, match.range.length)))
                    return TextGlyph(text: character, normalizedBox: normalized(
                        usable ? bounds! : proportionalBox(wordBox, characterRange: offset,
                                                            textLength: match.range.length), in: media))
                }
                return TextWord(text: wordText, normalizedBox: normalized(wordBox, in: media), glyphs: glyphs)
            }
            return TextLine(text: rawText.trimmingCharacters(in: .whitespacesAndNewlines), normalizedBox: CGRect(
                x: (box.minX - media.minX) / media.width,
                y: (box.minY - media.minY) / media.height,
                width: box.width / media.width,
                height: box.height / media.height
            ), confidence: 1, words: words)
        }
    }

    private static func recognize(in image: CGImage) throws -> [TextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        try Task.checkCancellation()
        return (request.results ?? []).compactMap { observation -> TextLine? in
            guard let candidate = observation.topCandidates(1).first,
                  !candidate.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let words = wordMatches(in: candidate.string).compactMap { match -> TextWord? in
                guard let range = Range(match.range, in: candidate.string),
                      let box = try? candidate.boundingBox(for: range) else { return nil }
                let wordText = (candidate.string as NSString).substring(with: match.range)
                let glyphs = characterRanges(in: wordText).map { character, offset in
                    let absolute = NSRange(location: match.range.location + offset.location, length: offset.length)
                    let characterBox = Range(absolute, in: candidate.string)
                        .flatMap { try? candidate.boundingBox(for: $0)?.boundingBox }
                    let wordBox = box.boundingBox
                    let usable = valid(characterBox) && characterBox!.width <= wordBox.width *
                        min(1, CGFloat(offset.length * 2) / CGFloat(max(1, match.range.length)))
                    return TextGlyph(text: character,
                                     normalizedBox: usable ? characterBox! :
                                        proportionalBox(wordBox, characterRange: offset,
                                                        textLength: match.range.length))
                }
                return TextWord(text: wordText, normalizedBox: box.boundingBox, glyphs: glyphs)
            }
            return TextLine(text: candidate.string, normalizedBox: observation.boundingBox,
                            confidence: candidate.confidence, words: words)
        }
    }

    private static func wordMatches(in text: String) -> [NSTextCheckingResult] {
        guard let pattern = try? NSRegularExpression(pattern: "\\S+") else { return [] }
        return pattern.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    private static func characterRanges(in text: String) -> [(String, NSRange)] {
        text.indices.map { start in
            let end = text.index(after: start)
            return (String(text[start..<end]), NSRange(start..<end, in: text))
        }
    }

    private static func valid(_ box: CGRect?) -> Bool {
        guard let box else { return false }
        return box.width > 0 && box.height > 0 && box.minX.isFinite && box.minY.isFinite
    }

    private static func proportionalBox(_ box: CGRect, characterRange: NSRange, textLength: Int) -> CGRect {
        let count = CGFloat(max(1, textLength))
        return CGRect(x: box.minX + box.width * CGFloat(characterRange.location) / count,
                      y: box.minY, width: box.width * CGFloat(characterRange.length) / count,
                      height: box.height)
    }

    private static func normalized(_ box: CGRect, in page: CGRect) -> CGRect {
        CGRect(x: (box.minX - page.minX) / page.width,
               y: (box.minY - page.minY) / page.height,
               width: box.width / page.width,
               height: box.height / page.height)
    }

    private static func drawInvisible(_ line: TextLine, in page: CGRect, context: CGContext) {
        let box = line.normalizedBox
        let rect = CGRect(x: box.minX * page.width, y: box.minY * page.height,
                          width: box.width * page.width, height: box.height * page.height)
        guard rect.width > 1, rect.height > 1 else { return }
        let font = CTFontCreateWithName("Helvetica" as CFString, max(4, rect.height * 0.8), nil)
        let attributed = NSAttributedString(string: line.text,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let textLine = CTLineCreateWithAttributedString(attributed)
        let width = CTLineGetTypographicBounds(textLine, nil, nil, nil)
        guard width > 0 else { return }
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        context.textMatrix = CGAffineTransform(scaleX: rect.width / width, y: 1)
        context.textPosition = CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.1)
        CTLineDraw(textLine, context)
        context.restoreGState()
    }
}
