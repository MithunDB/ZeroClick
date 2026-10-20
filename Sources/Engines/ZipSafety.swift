import Foundation

enum ZipSafety {
    struct Inspection { let isEncrypted: Bool }

    @discardableResult
    static func validate(_ archive: URL) throws -> Inspection {
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size >= 22 else { throw SatsumaError.invalidInput("Invalid ZIP archive.") }
        let tailSize = min(size, 65_557)
        try handle.seek(toOffset: size - tailSize)
        let tail = try handle.read(upToCount: Int(tailSize)) ?? Data()
        guard tail.count >= 22 else { throw SatsumaError.invalidInput("Invalid ZIP archive.") }
        var end: Int?
        for index in stride(from: tail.count - 22, through: 0, by: -1) {
            if value(tail, at: index, count: 4) == 0x06054b50 {
                end = index
                break
            }
        }
        guard let end,
              let entries = value(tail, at: end + 10, count: 2),
              let directorySize = value(tail, at: end + 12, count: 4),
              let directoryOffset = value(tail, at: end + 16, count: 4),
              entries > 0, entries < 65_535,
              directorySize <= 64 * 1024 * 1024,
              directoryOffset + directorySize <= size else {
            throw SatsumaError.invalidInput("Unsupported or invalid ZIP directory.")
        }
        try handle.seek(toOffset: directoryOffset)
        let directory = try handle.read(upToCount: Int(directorySize)) ?? Data()
        guard directory.count == directorySize else { throw SatsumaError.invalidInput("Truncated ZIP directory.") }
        var position = 0
        var expanded: UInt64 = 0
        var encrypted = false
        for _ in 0..<entries {
            guard value(directory, at: position, count: 4) == 0x02014b50,
                  let madeBy = value(directory, at: position + 4, count: 2),
                  let flags = value(directory, at: position + 8, count: 2),
                  let uncompressed = value(directory, at: position + 24, count: 4),
                  let nameLength = value(directory, at: position + 28, count: 2),
                  let extraLength = value(directory, at: position + 30, count: 2),
                  let commentLength = value(directory, at: position + 32, count: 2),
                  let attributes = value(directory, at: position + 38, count: 4),
                  let localOffset = value(directory, at: position + 42, count: 4) else {
                throw SatsumaError.invalidInput("Invalid ZIP entry.")
            }
            let endOfEntry = position + 46 + Int(nameLength) + Int(extraLength) + Int(commentLength)
            guard endOfEntry <= directory.count,
                  let name = String(data: directory[(position + 46)..<(position + 46 + Int(nameLength))], encoding: .utf8),
                  safeName(name) else {
                throw SatsumaError.invalidInput("ZIP contains an unsafe file path.")
            }
            let unixType = (attributes >> 16) & 0xF000
            if madeBy >> 8 == 3 && unixType == 0xA000 {
                throw SatsumaError.invalidInput("ZIP contains a symbolic link.")
            }
            guard localOffset + 30 <= size else { throw SatsumaError.invalidInput("Invalid ZIP local header.") }
            try handle.seek(toOffset: localOffset)
            let localHeader = try handle.read(upToCount: 30) ?? Data()
            guard value(localHeader, at: 0, count: 4) == 0x04034b50,
                  let localFlags = value(localHeader, at: 6, count: 2),
                  (flags & 1) == (localFlags & 1),
                  let localNameLength = value(localHeader, at: 26, count: 2),
                  let localExtraLength = value(localHeader, at: 28, count: 2),
                  localNameLength == nameLength,
                  localOffset + 30 + localNameLength + localExtraLength <= size,
                  let localName = try handle.read(upToCount: Int(localNameLength)),
                  localName == Data(name.utf8) else {
                throw SatsumaError.invalidInput("ZIP headers disagree on a file path.")
            }
            expanded += uncompressed
            encrypted = encrypted || (flags & 1) != 0
            guard expanded <= 4 * 1024 * 1024 * 1024 else {
                throw SatsumaError.invalidInput("ZIP contents exceed the extraction limit.")
            }
            position = endOfEntry
        }
        return Inspection(isEncrypted: encrypted)
    }

    static func safeName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"),
              !name.unicodeScalars.contains(where: { $0.value < 32 }) else { return false }
        var components = name.split(separator: "/", omittingEmptySubsequences: false)
        if components.last == "" { components.removeLast() }
        return !components.isEmpty && components.allSatisfy { !$0.isEmpty && $0 != ".." && $0 != "." }
    }

    private static func value(_ data: Data, at offset: Int, count: Int) -> UInt64? {
        guard offset >= 0, count > 0, offset + count <= data.count else { return nil }
        var result: UInt64 = 0
        for index in 0..<count { result |= UInt64(data[data.startIndex + offset + index]) << (index * 8) }
        return result
    }
}
