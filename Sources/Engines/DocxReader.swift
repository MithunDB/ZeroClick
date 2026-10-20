import Foundation

enum DocxReader {
    static func read(_ source: URL, paragraphSeparator: String = "\n") async throws -> String {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("zeroclick-docx-read-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await ZipTool.unzip(source, into: temporary)
        let document = temporary.appendingPathComponent("word/document.xml")
        guard let data = try? Data(contentsOf: document) else { throw SatsumaError.unreadable(source) }
        let delegate = DocumentTextParser(paragraphSeparator: paragraphSeparator)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw SatsumaError.unreadable(source) }
        return delegate.text
    }
}

private final class DocumentTextParser: NSObject, XMLParserDelegate {
    let paragraphSeparator: String
    private var paragraphs: [String] = []
    private var current = ""
    private var inParagraph = false
    private var inText = false
    var text: String { paragraphs.joined(separator: paragraphSeparator) }

    init(paragraphSeparator: String) { self.paragraphSeparator = paragraphSeparator }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName.split(separator: ":").last.map(String.init) {
        case "p": current = ""; inParagraph = true
        case "t": inText = inParagraph
        case "tab" where inParagraph: current += "\t"
        case "br", "cr" where inParagraph: current += "\n"
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { current += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        switch elementName.split(separator: ":").last.map(String.init) {
        case "t": inText = false
        case "p" where inParagraph: paragraphs.append(current); inParagraph = false
        default: break
        }
    }
}
