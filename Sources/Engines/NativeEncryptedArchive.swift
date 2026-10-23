import AppleArchive
import Foundation
import System

/// Password-protected Apple Encrypted Archives containing one regular file.
/// Legacy `.zclick` and PNG-message cryptography remain in `SecureFile`.
enum NativeEncryptedArchive {
    static let maximumFileSize: UInt64 = 2 * 1024 * 1024 * 1024
    private static let keys = ArchiveHeader.FieldKeySet("TYP,PAT,DAT,SIZ,MOD,MTM")!

    static func isEncrypted(_ source: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: source) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data("AEA1".utf8)
    }

    static func encrypt(_ source: URL, password: String, to destination: URL) throws -> URL {
        try encryptWork(source, password: password, to: destination, cancellation: nil)
    }

    static func encryptAsync(_ source: URL, password: String, to destination: URL) async throws -> URL {
        let cancellation = ArchiveCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            do {
                return try encryptWork(source, password: password, to: destination, cancellation: cancellation)
            } catch {
                if Task.isCancelled || cancellation.isCancelled { throw CancellationError() }
                throw error
            }
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
            cancellation.cancel()
        }
    }

    private static func encryptWork(_ source: URL, password: String, to destination: URL,
                                    cancellation: ArchiveCancellation?) throws -> URL {
        try validatePassword(password)
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: source.path)) == nil,
              let attributes = try? FileManager.default.attributesOfItem(atPath: source.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.uint64Value <= maximumFileSize else {
            throw SatsumaError.invalidInput("Choose a regular file no larger than 2 GB.")
        }
        return try OutputWriter.write(to: destination) { staged in
            try Task.checkCancellation()
            try cancellation?.check()
            let context = ArchiveEncryptionContext(
                profile: .hkdf_sha256_aesctr_hmac__scrypt__none,
                compressionAlgorithm: .lzfse)
            try context.setPassword(password)
            guard let file = ArchiveByteStream.fileStream(path: FilePath(staged.path), mode: .writeOnly,
                    options: [.create, .exclusiveCreate], permissions: FilePermissions(rawValue: 0o600)),
                  let encrypted = ArchiveByteStream.encryptionStream(writingTo: file, encryptionContext: context),
                  let encoder = ArchiveStream.encodeStream(writingTo: encrypted) else {
                throw SatsumaError.invalidInput("Could not create Apple Encrypted Archive.")
            }
            cancellation?.register(file)
            cancellation?.register(encrypted)
            cancellation?.register(encoder)
            defer {
                try? encoder.close()
                try? encrypted.close()
                try? file.close()
            }
            let selectedName = source.lastPathComponent
            var selectedCount = 0
            try encoder.writeDirectoryContents(
                archiveFrom: FilePath(source.deletingLastPathComponent().path),
                keySet: keys,
                selectUsing: { message, path, _ in
                    if Task.isCancelled || cancellation?.isCancelled == true { return .cancel }
                    if message == .searchExclude || message == .searchPruneDirectory {
                        return path.string.isEmpty || path.string == selectedName ? .ok : .skip
                    }
                    if message == .encodeScanning && path.string == selectedName { selectedCount += 1 }
                    return .ok
                }, threadCount: 1)
            guard selectedCount == 1 else {
                throw SatsumaError.invalidInput("The source file changed while preparing the archive.")
            }
            try Task.checkCancellation()
            try cancellation?.check()
            try encoder.close()
            try encrypted.close()
            try file.close()
        }
    }

    static func decrypt(_ source: URL, password: String, into directory: URL) throws -> URL {
        try decryptWork(source, password: password, into: directory, cancellation: nil)
    }

    static func decryptAsync(_ source: URL, password: String, into directory: URL) async throws -> URL {
        let cancellation = ArchiveCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            do {
                return try decryptWork(source, password: password, into: directory, cancellation: cancellation)
            } catch {
                if Task.isCancelled || cancellation.isCancelled { throw CancellationError() }
                throw error
            }
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
            cancellation.cancel()
        }
    }

    private static func decryptWork(_ source: URL, password: String, into directory: URL,
                                    cancellation: ArchiveCancellation?) throws -> URL {
        try validatePassword(password)
        let staging = directory.appendingPathComponent(".zeroclick-aea-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        try Task.checkCancellation()
        try cancellation?.check()
        guard let file = ArchiveByteStream.fileStream(path: FilePath(source.path), mode: .readOnly,
                options: [], permissions: FilePermissions(rawValue: 0o600)),
              let context = ArchiveEncryptionContext(from: file) else {
            throw SatsumaError.invalidInput("This is not a readable Apple Encrypted Archive.")
        }
        defer { try? file.close() }
        do { try context.setPassword(password) }
        catch { throw SatsumaError.invalidInput("Incorrect password or damaged Apple Encrypted Archive.") }
        guard let decrypted = ArchiveByteStream.decryptionStream(readingFrom: file, encryptionContext: context),
              let decoder = ArchiveStream.decodeStream(readingFrom: decrypted) else {
            throw SatsumaError.invalidInput("Incorrect password or damaged Apple Encrypted Archive.")
        }
        cancellation?.register(file)
        cancellation?.register(decrypted)
        cancellation?.register(decoder)
        defer {
            try? decoder.close()
            try? decrypted.close()
        }
        var extractedName: String?
        var rejected = false
        let filter: ArchiveHeader.EntryFilter = { message, path, data in
            if Task.isCancelled || cancellation?.isCancelled == true { rejected = true; return .cancel }
            if message == .extractBegin {
                guard case .header(let header)? = data else { rejected = true; return .cancel }
                let name = path.string
                if name.isEmpty && header.entryType == .directory { return .ok }
                guard header.entryType == .regularFile,
                      extractedName == nil,
                      safeName(name),
                      case .uint(_, let size)? = header.field(forKey: ArchiveHeader.FieldKey("SIZ")),
                      size <= maximumFileSize else {
                    rejected = true
                    return .cancel
                }
                extractedName = name
            }
            if message == .extractAttributes || message == .extractXAT || message == .extractACL {
                return .skip
            }
            return .ok
        }
        guard let extractor = ArchiveStream.extractStream(extractingTo: FilePath(staging.path), selectUsing: filter) else {
            throw SatsumaError.invalidInput("Could not prepare archive extraction.")
        }
        cancellation?.register(extractor)
        defer { try? extractor.close() }
        do {
            _ = try ArchiveStream.process(readingFrom: decoder, writingTo: extractor, threadCount: 1)
            try Task.checkCancellation()
            try cancellation?.check()
            try extractor.close()
        } catch {
            if Task.isCancelled || cancellation?.isCancelled == true { throw CancellationError() }
            if rejected { throw SatsumaError.invalidInput("Archive must contain one safe regular file.") }
            throw SatsumaError.invalidInput("Incorrect password or damaged Apple Encrypted Archive.")
        }
        guard !rejected, let name = extractedName else {
            throw SatsumaError.invalidInput("Archive must contain one safe regular file.")
        }
        let extracted = staging.appendingPathComponent(name)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: extracted.path),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            throw SatsumaError.invalidInput("Archive did not contain a readable file.")
        }
        let original = URL(fileURLWithPath: name)
        let destination = ConversionMatrix.uniqueURL(
            directory: directory,
            baseName: original.pathExtension.isEmpty ? name : ConversionMatrix.strippedBaseName(name),
            suffix: "decrypted", ext: original.pathExtension)
        try cancellation?.check()
        return try OutputWriter.write(to: destination) { staged in
            try FileManager.default.moveItem(at: extracted, to: staged)
        }
    }

    private static func validatePassword(_ password: String) throws {
        guard password.utf8.count >= 20 else {
            throw SatsumaError.invalidInput("Use a password of at least 20 UTF-8 bytes.")
        }
    }

    private static func safeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." &&
        !name.contains("/") && !name.contains("\\") &&
        !name.unicodeScalars.contains(where: { $0.value < 32 })
    }
}

private final class ArchiveCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var byteStreams: [ArchiveByteStream] = []
    private var archiveStreams: [ArchiveStream] = []

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func check() throws {
        if isCancelled { throw CancellationError() }
    }

    func register(_ stream: ArchiveByteStream) {
        lock.lock()
        byteStreams.append(stream)
        let alreadyCancelled = cancelled
        lock.unlock()
        if alreadyCancelled { stream.cancel() }
    }

    func register(_ stream: ArchiveStream) {
        lock.lock()
        archiveStreams.append(stream)
        let alreadyCancelled = cancelled
        lock.unlock()
        if alreadyCancelled { stream.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let bytes = byteStreams
        let archives = archiveStreams
        lock.unlock()
        for stream in archives { stream.cancel() }
        for stream in bytes { stream.cancel() }
    }
}
