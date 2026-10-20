import CommonCrypto
import CryptoKit
import Foundation

enum SecureFile {
    private static let magic = Data("ZCLICK01".utf8)
    private static let iterations: UInt32 = 250_000
    private static let maxInput = 512 * 1024 * 1024

    static func sealMessage(_ message: String, password: String) throws -> Data {
        guard !message.isEmpty, !password.isEmpty else { throw SatsumaError.invalidInput("Enter a message and password.") }
        guard message.utf8.count <= 64 * 1024 else { throw SatsumaError.invalidInput("Message exceeds 64 KB.") }
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let key = try deriveKey(password: password, salt: salt)
        let box = try AES.GCM.seal(Data(message.utf8), using: key)
        guard let combined = box.combined else { throw SatsumaError.invalidInput("Could not encrypt message.") }
        return salt + combined
    }

    static func openMessage(_ payload: Data, password: String) throws -> String {
        guard payload.count >= 16 + 28 else { throw SatsumaError.invalidInput("Hidden message is damaged.") }
        let key = try deriveKey(password: password, salt: Data(payload.prefix(16)))
        do {
            let data = try AES.GCM.open(AES.GCM.SealedBox(combined: payload.dropFirst(16)), using: key)
            guard let message = String(data: data, encoding: .utf8) else {
                throw SatsumaError.invalidInput("Hidden message is damaged.")
            }
            return message
        } catch {
            throw SatsumaError.invalidInput("Incorrect password or damaged hidden message.")
        }
    }

    static func isEncrypted(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: magic.count)) == magic
    }

    static func encrypt(_ source: URL, password: String, to destination: URL) throws -> URL {
        guard !password.isEmpty else { throw SatsumaError.invalidInput("Enter a password.") }
        let data = try boundedRead(source)
        guard !data.isEmpty else { throw SatsumaError.invalidInput("Cannot encrypt an empty file.") }
        try Task.checkCancellation()
        let filename = Data(source.lastPathComponent.utf8)
        guard !filename.isEmpty, filename.count <= 1024 else { throw SatsumaError.invalidInput("File name is too long.") }
        var plaintext = Data()
        let length = UInt16(filename.count)
        plaintext.append(UInt8(length & 0xff))
        plaintext.append(UInt8(length >> 8))
        plaintext.append(filename)
        plaintext.append(data)
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let key = try deriveKey(password: password, salt: salt)
        let box = try AES.GCM.seal(plaintext, using: key)
        guard let combined = box.combined else { throw SatsumaError.invalidInput("Could not encrypt file.") }
        var output = magic
        output.append(salt)
        output.append(combined)
        return try OutputWriter.write(to: destination) { staged in
            try output.write(to: staged, options: .atomic)
        }
    }

    static func decrypt(_ source: URL, password: String, into directory: URL) throws -> URL {
        guard !password.isEmpty else { throw SatsumaError.invalidInput("Enter a password.") }
        let encrypted = try boundedRead(source)
        guard encrypted.count >= magic.count + 16 + 28, encrypted.starts(with: magic) else {
            throw SatsumaError.invalidInput("Not a ZeroClick encrypted file.")
        }
        try Task.checkCancellation()
        let salt = encrypted[magic.count..<(magic.count + 16)]
        let combined = encrypted.dropFirst(magic.count + 16)
        let key = try deriveKey(password: password, salt: Data(salt))
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: key)
        } catch {
            throw SatsumaError.invalidInput("Incorrect password or damaged ZeroClick file.")
        }
        guard plaintext.count >= 2 else { throw SatsumaError.invalidInput("Damaged ZeroClick file.") }
        let nameLength = Int(plaintext[0]) | (Int(plaintext[1]) << 8)
        guard nameLength > 0, nameLength <= 1024, plaintext.count >= 2 + nameLength,
              let name = String(data: plaintext[2..<(2 + nameLength)], encoding: .utf8),
              name == URL(fileURLWithPath: name).lastPathComponent,
              name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: { $0.value < 32 }) else {
            throw SatsumaError.invalidInput("Encrypted file contains an unsafe name.")
        }
        let original = URL(fileURLWithPath: name)
        let destination = original.pathExtension.isEmpty
            ? ConversionMatrix.uniqueURL(directory: directory, baseName: name, suffix: "decrypted", ext: "")
            : ConversionMatrix.uniqueURL(directory: directory, baseName: ConversionMatrix.strippedBaseName(name), suffix: "decrypted", ext: original.pathExtension)
        return try OutputWriter.write(to: destination) { staged in
            try plaintext.dropFirst(2 + nameLength).write(to: staged, options: .atomic)
        }
    }

    private static func boundedRead(_ url: URL) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value <= maxInput else {
            throw SatsumaError.invalidInput("Files over 512 MB are not supported by this encrypted-file tool.")
        }
        return try Data(contentsOf: url)
    }

    private static func deriveKey(password: String, salt: Data) throws -> SymmetricKey {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = password.withCString { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes,
                                    password.utf8.count, saltBytes.bindMemory(to: UInt8.self).baseAddress!,
                                    salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                                    &bytes, bytes.count)
            }
        }
        guard result == kCCSuccess else { throw SatsumaError.invalidInput("Could not derive encryption key.") }
        return SymmetricKey(data: bytes)
    }
}
