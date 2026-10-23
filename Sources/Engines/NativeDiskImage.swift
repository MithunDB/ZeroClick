import Foundation

/// A single-file, AES-256 disk image. Passwords are piped to diskutil, never passed in argv.
enum NativeDiskImage {
    static let maximumFileSize: UInt64 = 2 * 1024 * 1024 * 1024
    private static let executable = "/usr/sbin/diskutil"

    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: executable) }

    static func isEncrypted(_ source: URL) -> Bool {
        guard source.pathExtension.lowercased() == "dmg",
              FileManager.default.isExecutableFile(atPath: "/usr/bin/hdiutil") else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["isencrypted", "-plist", source.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let values = plist as? [String: Any] else { return false }
        return values["encrypted"] as? Bool == true
    }

    static func encrypt(_ source: URL, password: String, to destination: URL) async throws -> URL {
        guard isAvailable else { throw SatsumaError.invalidInput("Encrypted disk images require macOS diskutil.") }
        try validate(source, password: password)
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("zeroclick-dmg-\(UUID().uuidString)")
        let contents = workspace.appendingPathComponent("contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let isolated = contents.appendingPathComponent(source.lastPathComponent)
        do { try FileManager.default.linkItem(at: source, to: isolated) }
        catch { try FileManager.default.copyItem(at: source, to: isolated) }
        return try await OutputWriter.writeAsync(to: destination) { staged in
            try Task.checkCancellation()
            let result = try await Shell.runWithInput(executable,
                ["image", "create", "from", "--encrypt", "--stdinpassphrase", "--format", "ULFO",
                 "--volumeName", "ZeroClick Protected File", contents.path, staged.path],
                input: Data((password + "\n").utf8), cancelProcess: true)
            try Task.checkCancellation()
            guard result.succeeded else {
                throw SatsumaError.invalidInput("Could not create the encrypted disk image. Check free disk space and try again.")
            }
        }
    }

    static func decrypt(_ source: URL, password: String, into directory: URL) async throws -> URL {
        guard isAvailable else { throw SatsumaError.invalidInput("Opening encrypted disk images requires macOS diskutil.") }
        guard source.pathExtension.lowercased() == "dmg" else {
            throw SatsumaError.invalidInput("Choose a .dmg disk image.")
        }
        guard isEncrypted(source) else {
            throw SatsumaError.invalidInput("This is not a password-protected disk image.")
        }
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("zeroclick-dmg-\(UUID().uuidString)")
        let mount = workspace.appendingPathComponent("mount")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        var attachedDevice: String?
        defer { if attachedDevice == nil { try? FileManager.default.removeItem(at: workspace) } }
        // Do not cancel an attach halfway through: its device must be discovered and ejected.
        let attached = try await Shell.runWithInput(executable,
            ["image", "attach", "--stdinpassphrase", "--readOnly", "--nobrowse", "--mountPoint", mount.path,
             "--plist", source.path], input: Data((password + "\n").utf8))
        guard attached.succeeded else {
            throw SatsumaError.invalidInput("The disk image could not be opened. Check the password and image integrity.")
        }
        let device = try deviceEntry(from: attached.stdout)
        attachedDevice = device
        var extracted: URL?
        var extractionError: Error?
        do {
            try Task.checkCancellation()
            let entries = try FileManager.default.contentsOfDirectory(at: mount,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                options: [.skipsHiddenFiles])
            guard entries.count == 1, let file = entries.first,
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  UInt64(values.fileSize ?? Int.max) <= maximumFileSize else {
                throw SatsumaError.invalidInput("This disk image must contain exactly one regular file no larger than 2 GB.")
            }
            let staged = workspace.appendingPathComponent("extracted")
            try FileManager.default.copyItem(at: file, to: staged)
            try Task.checkCancellation()
            extracted = staged
        } catch { extractionError = error }
        // Eject the whole device, not just the volume. A cancelled task must still clean it up.
        let ejected = try await Shell.runWithInput(executable, ["eject", device], input: Data())
        guard ejected.succeeded else {
            throw SatsumaError.invalidInput("The disk image could not be detached safely. Eject \(device) in Disk Utility before retrying.")
        }
        attachedDevice = nil
        if let extractionError { throw extractionError }
        try Task.checkCancellation()
        guard let extracted else { throw SatsumaError.invalidInput("No file was found in the disk image.") }
        let name = source.deletingPathExtension().lastPathComponent
        let original = URL(fileURLWithPath: name)
        let destination = ConversionMatrix.uniqueURL(directory: directory,
            baseName: original.deletingPathExtension().lastPathComponent, suffix: "decrypted",
            ext: original.pathExtension)
        return try OutputWriter.write(to: destination) { staged in
            try FileManager.default.moveItem(at: extracted, to: staged)
        }
    }

    private static func validate(_ source: URL, password: String) throws {
        guard password.utf8.count >= 12 else { throw SatsumaError.invalidInput("Use a password of at least 12 UTF-8 bytes.") }
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: source.path)) == nil,
              let attributes = try? FileManager.default.attributesOfItem(atPath: source.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.uint64Value <= maximumFileSize else {
            throw SatsumaError.invalidInput("Choose a regular file no larger than 2 GB.")
        }
    }

    private static func deviceEntry(from output: String) throws -> String {
        guard let data = output.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let root = plist as? [String: Any],
              let entities = root["system-entities"] as? [[String: Any]],
              let identifier = entities.compactMap({ $0["dev-entry"] as? String }).first,
              identifier.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil else {
            throw SatsumaError.invalidInput("The mounted disk image device could not be identified. Eject it in Disk Utility.")
        }
        return "/dev/\(identifier)"
    }
}
