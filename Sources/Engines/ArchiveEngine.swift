import Foundation

struct ArchiveEngine: ConversionEngine {
    func supports(from: FileFormat, to: FileFormat) -> Bool {
        from.category == .archive && to.category == .archive && to != .rar
    }

    func convert(_ request: ConversionRequest) async throws {
        if request.target == .rar {
            throw SatsumaError.invalidInput("RAR archives can be read but macOS has no free RAR encoder. Choose ZIP, TAR, or GZIP instead.")
        }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("satsuma-archive-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        try await extract(request.source, format: request.sourceFormat, into: staging)
        request.progress(0.5)
        try await pack(staging, as: request.target, to: request.destination)
        request.progress(1)
    }

    func extract(_ archive: URL, format: FileFormat, into directory: URL) async throws {
        switch format {
        case .zip:
            try await ZipTool.unzip(archive, into: directory)
        case .tar:
            try TarSafety.validate(archive)
            let result = try await Shell.run("/usr/bin/tar", ["-xf", archive.path, "-C", directory.path])
            guard result.succeeded else { throw SatsumaError.toolFailed("tar", result.stderr) }
        case .gz:
            let name = archive.lastPathComponent.lowercased()
            if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") {
                let expanded = FileManager.default.temporaryDirectory.appendingPathComponent("zeroclick-tar-preflight-\(UUID().uuidString).tar")
                defer { try? FileManager.default.removeItem(at: expanded) }
                let unpack = try await Shell.runToFile("/usr/bin/gunzip", ["-c", archive.path], output: expanded)
                guard unpack.succeeded else { throw SatsumaError.toolFailed("gunzip", unpack.stderr) }
                try TarSafety.validate(expanded)
                let result = try await Shell.run("/usr/bin/tar", ["-xzf", archive.path, "-C", directory.path])
                guard result.succeeded else { throw SatsumaError.toolFailed("tar", result.stderr) }
            } else {
                let output = directory.appendingPathComponent(archive.deletingPathExtension().lastPathComponent)
                let result = try await Shell.runToFile("/usr/bin/gunzip", ["-c", archive.path], output: output)
                guard result.succeeded else { throw SatsumaError.toolFailed("gunzip", result.stderr) }
            }
        case .rar:
            // Repack in memory/disk without extracting archive entries. The
            // resulting TAR can be checked before any content reaches output.
            let repacked = FileManager.default.temporaryDirectory.appendingPathComponent("zeroclick-rar-preflight-\(UUID().uuidString).tar")
            defer { try? FileManager.default.removeItem(at: repacked) }
            let pack = try await Shell.run("/usr/bin/bsdtar", ["-cf", repacked.path, "-C", archive.deletingLastPathComponent().path, "@\(archive.lastPathComponent)"])
            guard pack.succeeded else { throw SatsumaError.toolFailed("rar", pack.stderr) }
            try Task.checkCancellation()
            try TarSafety.validate(repacked)
            let extract = try await Shell.run("/usr/bin/tar", ["-xf", repacked.path, "-C", directory.path])
            guard extract.succeeded else { throw SatsumaError.toolFailed("tar", extract.stderr) }
        default:
            throw SatsumaError.unsupportedConversion(format, .zip)
        }
    }

    func pack(_ directory: URL, as format: FileFormat, to destination: URL) async throws {
        switch format {
        case .zip:
            try await ZipTool.zip(directory: directory, to: destination)
        case .tar:
            let result = try await Shell.run("/usr/bin/tar", ["-cf", destination.path, "-C", directory.path, "."])
            guard result.succeeded else { throw SatsumaError.toolFailed("tar", result.stderr) }
        case .gz:
            let result = try await Shell.run("/usr/bin/tar", ["-czf", destination.path, "-C", directory.path, "."])
            guard result.succeeded else { throw SatsumaError.toolFailed("tar", result.stderr) }
        default:
            throw SatsumaError.unsupportedConversion(.zip, format)
        }
    }
}
