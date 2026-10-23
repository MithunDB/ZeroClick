import CryptoKit
import Foundation

/// Optional OpenStego RandomLSB interoperability. The GPL OpenStego JAR is user-supplied,
/// hash-checked, and stored outside ZeroClick.app; no OpenStego code is redistributed.
enum OpenStegoBridge {
    private static let expectedSHA256 = "2ce8e84bfac3e7d3fd3386db04b103ee3bf3be08d0b4baeaf77718861e6105a1"
    private static let maximumJarSize = 10 * 1024 * 1024
    private static let maximumMessageSize = 65_536

    static var installedJar: URL? {
        let jar = jarDestination
        return (try? validatedJar(jar)) == true ? jar : nil
    }

    static let javaAvailable: Bool = {
        guard let java = Shell.which("java") else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: java)
        process.arguments = ["-version"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch { return false }
    }()

    @discardableResult
    static func importJar(_ source: URL) throws -> URL {
        guard try validatedJar(source) else {
            throw SatsumaError.invalidInput("Choose the official OpenStego 0.8.6 openstego.jar. Other JARs are not run.")
        }
        let destination = jarDestination
        if (try? validatedJar(destination)) == true { return destination }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        return try OutputWriter.write(to: destination) { staged in
            try FileManager.default.copyItem(at: source, to: staged)
        }
    }

    static func hide(_ message: String, password: String, in source: URL, to destination: URL,
                     jarOverride: URL? = nil) async throws -> URL {
        guard !message.isEmpty, message.utf8.count <= maximumMessageSize, !password.isEmpty else {
            throw SatsumaError.invalidInput("Enter a message up to 65,536 UTF-8 bytes and a password.")
        }
        let (java, jar) = try runtime(jarOverride: jarOverride)
        return try await OutputWriter.writeAsync(to: destination) { staged in
            let workspace = try privateWorkspace()
            defer { try? FileManager.default.removeItem(at: workspace) }
            let messageFile = workspace.appendingPathComponent("message.txt")
            try Data(message.utf8).write(to: messageFile, options: .atomic)
            let result = try await Shell.runWithInput(java,
                ["-jar", jar.path, "embed", "-a", "randomlsb", "-mf", messageFile.path,
                 "-cf", source.path, "-sf", staged.path, "-e", "-A", "AES256"],
                input: Data((password + "\n").utf8), cancelProcess: true)
            try Task.checkCancellation()
            guard result.succeeded else {
                throw SatsumaError.invalidInput("OpenStego could not hide the message. Check the cover image and capacity.")
            }
        }
    }

    static func reveal(from source: URL, password: String, jarOverride: URL? = nil) async throws -> String {
        guard !password.isEmpty else { throw SatsumaError.invalidInput("Enter the OpenStego password.") }
        let (java, jar) = try runtime(jarOverride: jarOverride)
        let workspace = try privateWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let extracted = workspace.appendingPathComponent("message.txt")
        let result = try await Shell.runWithInput(java,
            ["-jar", jar.path, "extract", "-a", "randomlsb", "-sf", source.path,
             "-xf", extracted.path],
            input: Data((password + "\n").utf8), cancelProcess: true)
        try Task.checkCancellation()
        guard result.succeeded else {
            throw SatsumaError.invalidInput("OpenStego could not reveal a message. Check the format and password.")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: extracted.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= maximumMessageSize else {
            throw SatsumaError.invalidInput("OpenStego payload is too large for this text tool.")
        }
        let bytes = try Data(contentsOf: extracted)
        guard let message = String(data: bytes, encoding: .utf8) else {
            throw SatsumaError.invalidInput("OpenStego contains a binary file, not UTF-8 text.")
        }
        return message
    }

    private static func runtime(jarOverride: URL?) throws -> (java: String, jar: URL) {
        guard javaAvailable, let java = Shell.which("java") else {
            throw SatsumaError.invalidInput("Install Java to use the optional OpenStego format.")
        }
        let jar = jarOverride ?? installedJar
        guard let jar, (try? validatedJar(jar)) == true else {
            throw SatsumaError.invalidInput("Import the official OpenStego 0.8.6 JAR first.")
        }
        return (java, jar)
    }

    private static var jarDestination: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ZeroClick/OpenStego", isDirectory: true)
            .appendingPathComponent("openstego-0.8.6.jar")
    }

    private static func validatedJar(_ source: URL) throws -> Bool {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { return false }
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        guard let size = attributes[.size] as? NSNumber,
              size.intValue > 0, size.intValue <= maximumJarSize else { return false }
        let digest = SHA256.hash(data: try Data(contentsOf: source))
            .map { String(format: "%02x", $0) }.joined()
        return digest == expectedSHA256
    }

    private static func privateWorkspace() throws -> URL {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("zeroclick-openstego-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return workspace
    }
}
