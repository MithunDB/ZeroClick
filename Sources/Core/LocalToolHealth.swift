import Foundation

/// Fast, bounded launch check for local tools displayed in the synchronous wheel.
enum LocalToolHealth {
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var values: [String: Bool] = [:]
    }
    private static let cache = Cache()

    static func responds(_ path: String, arguments: [String], acceptableStatuses: Set<Int32> = [0]) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }
        let metadata = try? FileManager.default.attributesOfItem(atPath: path)
        let stamp = (metadata?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (metadata?[.size] as? NSNumber)?.int64Value ?? 0
        let key = "\(path)|\(stamp)|\(size)|\(arguments.joined(separator: ","))|\(acceptableStatuses.sorted())"
        if let known = cache.lock.withLock({ cache.values[key] }) { return known }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        let healthy: Bool
        do {
            try process.run()
            if done.wait(timeout: .now() + 0.5) == .success {
                healthy = acceptableStatuses.contains(process.terminationStatus)
            } else {
                process.terminate()
                healthy = false
            }
        } catch { healthy = false }
        cache.lock.withLock { cache.values[key] = healthy }
        return healthy
    }
}
