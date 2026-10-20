import AppKit
import Foundation
import PDFKit

struct PDFPageRef: Identifiable, Equatable {
    let id = UUID()
    let sourceIndex: Int
    var rotation: Int
    var sourceURL: URL

    static func == (lhs: PDFPageRef, rhs: PDFPageRef) -> Bool {
        lhs.id == rhs.id && lhs.rotation == rhs.rotation
    }
}

enum PDFOps {
    static func unlock(_ url: URL, password: String, to destination: URL) throws {
        guard let source = PDFDocument(url: url) else { throw SatsumaError.unreadable(url) }
        guard source.isEncrypted else { throw SatsumaError.invalidInput("This PDF is not encrypted.") }
        if source.isLocked && !source.unlock(withPassword: password) {
            throw SatsumaError.invalidInput("Incorrect PDF password.")
        }
        guard !source.isLocked, source.pageCount > 0 else {
            throw SatsumaError.invalidInput("This PDF could not be unlocked or has no pages.")
        }
        // PDFKit retains encryption when writing the source document, even after unlock.
        let output = PDFDocument()
        output.documentAttributes = source.documentAttributes
        for index in 0..<source.pageCount {
            guard let page = source.page(at: index), let copy = page.copy() as? PDFPage else {
                throw SatsumaError.invalidInput("A PDF page is no longer available.")
            }
            output.insert(copy, at: output.pageCount)
        }
        guard output.write(to: destination),
              let check = PDFDocument(url: destination),
              !check.isEncrypted, !check.isLocked, check.pageCount == source.pageCount else {
            throw SatsumaError.encodeFailed("Could not verify the unlocked PDF copy.")
        }
    }

    static func document(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else { throw SatsumaError.unreadable(url) }
        if document.isLocked { throw SatsumaError.invalidInput("\(url.lastPathComponent) is password protected.") }
        return document
    }

    static func merge(_ urls: [URL], to destination: URL) throws {
        guard !urls.isEmpty else { throw SatsumaError.invalidInput("Choose PDFs to merge.") }
        let output = PDFDocument()
        for url in urls {
            let source = try document(url)
            guard source.pageCount > 0 else { throw SatsumaError.invalidInput("\(url.lastPathComponent) has no pages.") }
            for index in 0..<source.pageCount {
                guard let page = source.page(at: index) else {
                    throw SatsumaError.invalidInput("A PDF page is no longer available.")
                }
                output.insert(page, at: output.pageCount)
            }
        }
        guard output.write(to: destination) else { throw SatsumaError.encodeFailed(destination.lastPathComponent) }
    }

    static func assemble(pages: [PDFPageRef], to destination: URL) throws {
        var cache: [URL: PDFDocument] = [:]
        let output = PDFDocument()
        for ref in pages {
            let source: PDFDocument
            if let cached = cache[ref.sourceURL] {
                source = cached
            } else {
                source = try document(ref.sourceURL)
                cache[ref.sourceURL] = source
            }
            guard let page = source.page(at: ref.sourceIndex), let copy = page.copy() as? PDFPage else {
                throw SatsumaError.invalidInput("A selected PDF page is no longer available.")
            }
            copy.rotation = ref.rotation
            output.insert(copy, at: output.pageCount)
        }
        guard output.pageCount > 0 else { throw SatsumaError.invalidInput("The document would have no pages.") }
        guard output.write(to: destination) else { throw SatsumaError.encodeFailed(destination.lastPathComponent) }
    }

    enum SplitMode: String, CaseIterable, Identifiable {
        case everyPage, everyN, ranges
        var id: String { rawValue }
        var title: String {
            switch self {
            case .everyPage: return "One file per page"
            case .everyN: return "Every N pages"
            case .ranges: return "Custom page ranges"
            }
        }
    }

    static func parseRanges(_ text: String, pageCount: Int) -> [ClosedRange<Int>] {
        text.split(separator: ",").compactMap { token in
            let part = token.trimmingCharacters(in: .whitespaces)
            if let dash = part.range(of: "-") {
                let a = Int(part[..<dash.lowerBound].trimmingCharacters(in: .whitespaces)) ?? 1
                let b = Int(part[dash.upperBound...].trimmingCharacters(in: .whitespaces)) ?? pageCount
                let lower = max(1, min(a, b)), upper = min(pageCount, max(a, b))
                return lower <= upper ? lower...upper : nil
            }
            if let single = Int(part), single >= 1, single <= pageCount { return single...single }
            return nil
        }
    }

    static func split(_ url: URL, mode: SplitMode, every: Int, ranges: String, into folder: URL) throws -> [URL] {
        let source = try document(url)
        let count = source.pageCount
        guard count > 0 else { throw SatsumaError.invalidInput("\(url.lastPathComponent) has no pages.") }
        let base = ConversionMatrix.strippedBaseName(url.lastPathComponent)
        var groups: [ClosedRange<Int>] = []
        switch mode {
        case .everyPage:
            groups = (1...max(1, count)).map { $0...$0 }
        case .everyN:
            let n = max(1, every)
            var start = 1
            while start <= count {
                groups.append(start...min(count, start + n - 1))
                start += n
            }
        case .ranges:
            groups = parseRanges(ranges, pageCount: count)
        }
        guard !groups.isEmpty else { throw SatsumaError.invalidInput("No valid page ranges.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var outputs: [URL] = []
        for (index, group) in groups.enumerated() {
            let part = PDFDocument()
            for pageNumber in group {
                guard let page = source.page(at: pageNumber - 1) else {
                    throw SatsumaError.invalidInput("A PDF page is no longer available.")
                }
                part.insert(page, at: part.pageCount)
            }
            let name = group.count == 1 ? "\(base) page \(group.lowerBound).pdf" : "\(base) pages \(group.lowerBound)-\(group.upperBound).pdf"
            let output = folder.appendingPathComponent(name.isEmpty ? "\(base) part \(index + 1).pdf" : name)
            guard part.write(to: output) else { throw SatsumaError.encodeFailed(output.lastPathComponent) }
            outputs.append(output)
        }
        return outputs
    }

    static func compress(_ url: URL, strong: Bool, to destination: URL) throws {
        let source = try document(url)
        var options: [PDFDocumentWriteOption: Any] = [:]
        if #available(macOS 13.4, *) {
            options[.saveImagesAsJPEGOption] = true
            options[.optimizeImagesForScreenOption] = true
        }
        if strong {
            guard source.pageCount > 0 else { throw SatsumaError.invalidInput("\(url.lastPathComponent) has no pages.") }
            let rendered = PDFDocument()
            for index in 0..<source.pageCount {
                guard let page = source.page(at: index), let image = PDFRenderer.render(page: page, dpi: 110) else {
                    throw SatsumaError.encodeFailed("Could not render PDF page \(index + 1).")
                }
                let temp = FileManager.default.temporaryDirectory.appendingPathComponent("satsuma-pdfpage-\(UUID().uuidString).jpg")
                try ImageIOBridge.write(image, to: temp, format: .jpg, quality: 0.6)
                defer { try? FileManager.default.removeItem(at: temp) }
                guard let nsImage = NSImage(contentsOf: temp) else {
                    throw SatsumaError.encodeFailed("Could not save PDF page \(index + 1).")
                }
                nsImage.size = page.bounds(for: .mediaBox).size
                guard let newPage = PDFPage(image: nsImage) else {
                    throw SatsumaError.encodeFailed("Could not save PDF page \(index + 1).")
                }
                rendered.insert(newPage, at: rendered.pageCount)
            }
            guard rendered.write(to: destination, withOptions: options) else { throw SatsumaError.encodeFailed(destination.lastPathComponent) }
            return
        }
        guard source.write(to: destination, withOptions: options) else { throw SatsumaError.encodeFailed(destination.lastPathComponent) }
    }

    static func fromImages(_ urls: [URL], to destination: URL, progress: @escaping (Double) -> Void) throws {
        let output = PDFDocument()
        for (index, url) in urls.enumerated() {
            let image = try ImageIOBridge.load(url)
            let nsImage = ImageOps.nsImage(image)
            if let page = PDFPage(image: nsImage) {
                output.insert(page, at: output.pageCount)
            }
            progress(Double(index + 1) / Double(urls.count))
        }
        guard output.pageCount > 0 else { throw SatsumaError.invalidInput("No images could be read.") }
        guard output.write(to: destination) else { throw SatsumaError.encodeFailed(destination.lastPathComponent) }
    }
}
