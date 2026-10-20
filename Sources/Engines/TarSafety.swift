import Foundation

enum TarSafety {
    static func validate(_ archive: URL) throws {
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        var offset: UInt64 = 0
        var count = 0
        var expanded: UInt64 = 0
        while offset + 512 <= length {
            try handle.seek(toOffset: offset)
            let block = try handle.read(upToCount: 512) ?? Data()
            guard block.count == 512 else { throw SatsumaError.invalidInput("Truncated TAR header.") }
            if block.allSatisfy({ $0 == 0 }) { break }
            guard let name = field(block, 0..<100),
                  let prefix = field(block, 345..<500),
                  let fileSize = octal(block, 124..<136) else {
                throw SatsumaError.invalidInput("Invalid TAR header.")
            }
            let path = prefix.isEmpty ? name : prefix + "/" + name
            guard safePath(path) else { throw SatsumaError.invalidInput("TAR contains an unsafe file path.") }
            let type = block[block.startIndex + 156]
            guard type == 0 || type == 48 || type == 53 || type == 120 || type == 103 else {
                throw SatsumaError.invalidInput("TAR contains a link or unsupported entry.")
            }
            if type == 120 || type == 103 {
                guard fileSize <= 1024 * 1024 else { throw SatsumaError.invalidInput("Oversized TAR metadata.") }
                let metadata = try handle.read(upToCount: Int(fileSize)) ?? Data()
                try validatePAX(metadata)
            }
            expanded += fileSize
            guard expanded <= 4 * 1024 * 1024 * 1024 else {
                throw SatsumaError.invalidInput("TAR contents exceed the extraction limit.")
            }
            let blocks = (fileSize + 511) / 512
            guard blocks <= (UInt64.max - offset - 512) / 512 else {
                throw SatsumaError.invalidInput("Invalid TAR size.")
            }
            offset += 512 + blocks * 512
            guard offset <= length else { throw SatsumaError.invalidInput("Truncated TAR entry.") }
            if type != 120 && type != 103 { count += 1 }
        }
        guard count > 0 else { throw SatsumaError.invalidInput("Empty TAR archive.") }
    }

    private static func validatePAX(_ data: Data) throws {
        var cursor = 0
        while cursor < data.count {
            guard let space = data[cursor...].firstIndex(of: 32),
                  let lengthText = String(bytes: data[cursor..<space], encoding: .ascii),
                  let length = Int(lengthText), length > 0,
                  cursor + length <= data.count else {
                throw SatsumaError.invalidInput("Invalid TAR metadata.")
            }
            let record = data[(space + 1)..<(cursor + length)]
            guard record.last == 10, let equals = record.firstIndex(of: 61),
                  let key = String(bytes: record[..<equals], encoding: .ascii) else {
                throw SatsumaError.invalidInput("Invalid TAR metadata.")
            }
            if key == "path" {
                guard let path = String(bytes: record[(equals + 1)..<(record.endIndex - 1)], encoding: .utf8), safePath(path) else {
                    throw SatsumaError.invalidInput("TAR metadata contains an unsafe path.")
                }
            } else if key == "linkpath" || key == "size" || key.contains("sparse") {
                throw SatsumaError.invalidInput("TAR metadata changes a link or size.")
            }
            cursor += length
        }
    }

    private static func field(_ data: Data, _ range: Range<Int>) -> String? {
        let bytes = data[range].prefix { $0 != 0 }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func octal(_ data: Data, _ range: Range<Int>) -> UInt64? {
        let raw = data[range].prefix { $0 != 0 && $0 != 32 }
        let text = String(bytes: raw, encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? 0 : UInt64(text, radix: 8)
    }

    private static func safePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.value < 32 }) else { return false }
        var parts = path.split(separator: "/", omittingEmptySubsequences: false)
        if parts.last == "" { parts.removeLast() }
        return !parts.isEmpty && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
