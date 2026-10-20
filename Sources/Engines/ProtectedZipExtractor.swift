import Foundation

// libarchive is supplied by macOS. The password is passed directly to the
// library and never appears in a child process's arguments or a log entry.
private enum ArchiveC {
    @_silgen_name("archive_read_new") static func new() -> OpaquePointer?
    @_silgen_name("archive_read_support_filter_all") static func filters(_ archive: OpaquePointer) -> Int32
    @_silgen_name("archive_read_support_format_zip") static func zip(_ archive: OpaquePointer) -> Int32
    @_silgen_name("archive_read_add_passphrase") static func passphrase(_ archive: OpaquePointer, _ password: UnsafePointer<CChar>) -> Int32
    @_silgen_name("archive_read_open_filename") static func open(_ archive: OpaquePointer, _ path: UnsafePointer<CChar>, _ blockSize: Int) -> Int32
    @_silgen_name("archive_read_next_header") static func next(_ archive: OpaquePointer, _ entry: UnsafeMutablePointer<OpaquePointer?>) -> Int32
    @_silgen_name("archive_entry_pathname") static func name(_ entry: OpaquePointer) -> UnsafePointer<CChar>?
    @_silgen_name("archive_entry_filetype") static func type(_ entry: OpaquePointer) -> UInt32
    @_silgen_name("archive_entry_size") static func size(_ entry: OpaquePointer) -> Int64
    @_silgen_name("archive_read_data") static func read(_ archive: OpaquePointer, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int
    @_silgen_name("archive_read_free") static func free(_ archive: OpaquePointer) -> Int32
}

enum ProtectedZipExtractor {
    static func extract(_ source: URL, into destination: URL, password: String) throws {
        guard !password.isEmpty else { throw SatsumaError.invalidInput("Enter a ZIP password.") }
        let inspection = try ZipSafety.validate(source)
        guard inspection.isEncrypted else { throw SatsumaError.invalidInput("This ZIP is not password protected.") }
        guard let archive = ArchiveC.new() else { throw SatsumaError.invalidInput("Could not open ZIP extractor.") }
        defer { _ = ArchiveC.free(archive) }
        guard ArchiveC.filters(archive) == 0, ArchiveC.zip(archive) == 0,
              password.withCString({ ArchiveC.passphrase(archive, $0) }) == 0,
              source.path.withCString({ ArchiveC.open(archive, $0, 64 * 1024) }) == 0 else {
            throw SatsumaError.invalidInput("Could not open protected ZIP.")
        }
        let fm = FileManager.default
        var total: Int64 = 0
        var entry: OpaquePointer?
        while true {
            try Task.checkCancellation()
            let status = ArchiveC.next(archive, &entry)
            if status == 1 { break } // ARCHIVE_EOF
            guard status == 0, let entry, let pointer = ArchiveC.name(entry) else {
                throw SatsumaError.invalidInput("Incorrect ZIP password or damaged encrypted ZIP.")
            }
            let name = String(cString: pointer)
            guard ZipSafety.safeName(name) else { throw SatsumaError.invalidInput("ZIP contains an unsafe file path.") }
            let target = destination.appendingPathComponent(name)
            let type = ArchiveC.type(entry)
            if type == 0o040000 || (type == 0 && name.hasSuffix("/")) {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            guard type == 0o100000 || type == 0 else {
                throw SatsumaError.invalidInput("ZIP contains an unsupported file type.")
            }
            let expected = ArchiveC.size(entry)
            guard expected >= 0, expected <= 4 * 1024 * 1024 * 1024,
                  total <= 4 * 1024 * 1024 * 1024 - expected else {
                throw SatsumaError.invalidInput("ZIP contents exceed the extraction limit.")
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard !fm.fileExists(atPath: target.path),
                  fm.createFile(atPath: target.path, contents: nil),
                  let output = FileHandle(forWritingAtPath: target.path) else {
                throw SatsumaError.invalidInput("ZIP contains duplicate or conflicting paths.")
            }
            defer { try? output.close() }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            var written: Int64 = 0
            while true {
                try Task.checkCancellation()
                let count = buffer.withUnsafeMutableBytes { bytes in ArchiveC.read(archive, bytes.baseAddress!, bytes.count) }
                if count == 0 { break }
                guard count > 0, Int64(count) <= expected - written else {
                    throw SatsumaError.invalidInput("Incorrect ZIP password or damaged encrypted ZIP.")
                }
                try output.write(contentsOf: buffer.prefix(count))
                written += Int64(count)
            }
            guard written == expected else { throw SatsumaError.invalidInput("Damaged encrypted ZIP.") }
            total += written
        }
    }
}
