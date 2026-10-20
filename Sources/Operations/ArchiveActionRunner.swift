import Foundation

enum ArchiveActionRunner {
    static func zipDestination(for urls: [URL]) -> URL {
        let first = urls[0]
        let stem = urls.count == 1 ? ConversionMatrix.strippedBaseName(first.lastPathComponent) : "Selected Files"
        return ConversionMatrix.uniqueURL(directory: first.deletingLastPathComponent(), baseName: stem, suffix: "", ext: "zip")
    }

    static func extractionDestination(for archive: URL) -> URL {
        ConversionMatrix.uniqueDirectory(directory: archive.deletingLastPathComponent(), name: archive.deletingPathExtension().lastPathComponent)
    }

    static func createZip(from urls: [URL], to destination: URL) async throws -> URL {
        guard !urls.isEmpty else { throw SatsumaError.invalidInput("Choose files to archive.") }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("zeroclick-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        for url in urls {
            try Task.checkCancellation()
            let target = uniqueStagedURL(for: url, in: staging)
            try FileManager.default.copyItem(at: url, to: target)
        }
        return try await OutputWriter.writeAsync(to: destination) { staged in
            try await ZipTool.zip(directory: staging, to: staged)
        }
    }

    static func extractZip(_ archive: URL, to destination: URL) async throws -> URL {
        guard FileFormat.detect(archive) == .zip else { throw SatsumaError.invalidInput("Choose a ZIP archive.") }
        return try await OutputWriter.writeDirectoryAsync(to: destination) { staged in
            try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
            try await ZipTool.unzip(archive, into: staged)
        }
    }

    private static func uniqueStagedURL(for url: URL, in folder: URL) -> URL {
        let base = ConversionMatrix.strippedBaseName(url.lastPathComponent)
        if url.pathExtension.isEmpty {
            return ConversionMatrix.uniqueDirectory(directory: folder, name: url.lastPathComponent)
        }
        return ConversionMatrix.uniqueURL(directory: folder, baseName: base, suffix: "", ext: url.pathExtension)
    }
}
