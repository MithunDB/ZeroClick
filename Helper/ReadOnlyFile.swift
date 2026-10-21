import Darwin
import Foundation

// This is a low-level building block for a future authorized daemon. It is
// intentionally outside Brisk's app Sources and is not packaged or installed.
// The daemon must validate the XPC caller and authorization before calling it.
enum ReadOnlyFile {
    enum Failure: Error {
        case invalidPath
        case cannotOpen(Int32)
        case notRegularFile
        case tooLarge
        case cannotInspect(Int32)
    }

    static func openRegularFile(at path: String, maximumBytes: Int64 = 2_147_483_648) throws -> Int32 {
        guard path.hasPrefix("/"), !path.isEmpty, !path.utf8.contains(0) else { throw Failure.invalidPath }
        let descriptor = path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw Failure.cannotOpen(errno) }
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw Failure.cannotInspect(errno) }
            guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { throw Failure.notRegularFile }
            guard info.st_size >= 0, info.st_size <= maximumBytes else { throw Failure.tooLarge }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }
}
