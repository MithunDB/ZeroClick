import Foundation

enum OutputWriter {
    static func write(to destination: URL, operation: (URL) throws -> Void) throws -> URL {
        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent(".zeroclick-\(UUID().uuidString).\(destination.pathExtension)")
        do {
            try Task.checkCancellation()
            try operation(staged)
            try Task.checkCancellation()
            let attributes = try FileManager.default.attributesOfItem(atPath: staged.path)
            guard (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0 else {
                throw SatsumaError.encodeFailed(destination.lastPathComponent)
            }
            try FileManager.default.moveItem(at: staged, to: destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }

    static func writeAsync(to destination: URL, operation: (URL) async throws -> Void) async throws -> URL {
        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent(".zeroclick-\(UUID().uuidString).\(destination.pathExtension)")
        do {
            try Task.checkCancellation()
            try await operation(staged)
            try Task.checkCancellation()
            let attributes = try FileManager.default.attributesOfItem(atPath: staged.path)
            guard (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0 else {
                throw SatsumaError.encodeFailed(destination.lastPathComponent)
            }
            try FileManager.default.moveItem(at: staged, to: destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }

    static func writeDirectory(to destination: URL, operation: (URL) throws -> Void) throws -> URL {
        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent(".zeroclick-\(UUID().uuidString)", isDirectory: true)
        do {
            try Task.checkCancellation()
            try operation(staged)
            try Task.checkCancellation()
            let files = try FileManager.default.contentsOfDirectory(atPath: staged.path)
            guard !files.isEmpty else { throw SatsumaError.encodeFailed(destination.lastPathComponent) }
            try FileManager.default.moveItem(at: staged, to: destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }

    static func writeDirectoryAsync(to destination: URL, operation: (URL) async throws -> Void) async throws -> URL {
        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent(".zeroclick-\(UUID().uuidString)", isDirectory: true)
        do {
            try Task.checkCancellation()
            try await operation(staged)
            try Task.checkCancellation()
            let files = try FileManager.default.contentsOfDirectory(atPath: staged.path)
            guard !files.isEmpty else { throw SatsumaError.encodeFailed(destination.lastPathComponent) }
            try FileManager.default.moveItem(at: staged, to: destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }
}
