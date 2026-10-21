import Darwin
import Foundation

@main
enum ReadOnlyFileSmoke {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeroclick-read-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sample.txt")
        let link = root.appendingPathComponent("link.txt")
        try Data("read only".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let fd = try ReadOnlyFile.openRegularFile(at: file.path)
        defer { Darwin.close(fd) }
        var bytes = [UInt8](repeating: 0, count: 9)
        guard Darwin.read(fd, &bytes, bytes.count) == bytes.count,
              String(bytes: bytes, encoding: .utf8) == "read only" else { fatalError("regular-file read failed") }
        for rejected in [link.path, root.path, "relative/path"] {
            do {
                let fd = try ReadOnlyFile.openRegularFile(at: rejected)
                Darwin.close(fd)
                fatalError("accepted forbidden path: \(rejected)")
            } catch ReadOnlyFile.Failure.cannotOpen, ReadOnlyFile.Failure.notRegularFile,
                    ReadOnlyFile.Failure.invalidPath { /* expected */ }
        }
        do {
            let fd = try ReadOnlyFile.openRegularFile(at: file.path, maximumBytes: 3)
            Darwin.close(fd)
            fatalError("accepted oversized file")
        } catch ReadOnlyFile.Failure.tooLarge { /* expected */ }
        print("read-only file gate: pass")
    }
}
