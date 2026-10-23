import Foundation
import Darwin

struct ShellResult {
    let status: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { status == 0 }
}

final class PipeBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func set(stdout data: Data) { lock.withLock { stdout = data } }
    func set(stderr data: Data) { lock.withLock { stderr = data } }

    func result(status: Int32) -> ShellResult {
        lock.withLock {
            ShellResult(status: status, stdout: String(decoding: stdout, as: UTF8.self), stderr: String(decoding: stderr, as: UTF8.self))
        }
    }
}

final class ProcessBox: @unchecked Sendable {
    let process = Process()
    func terminate() {
        if process.isRunning { process.terminate() }
    }
}

enum Shell {
    /// Supplies sensitive input through a pipe. The input is never included in argv or diagnostics.
    /// Mounting callers must finish the command and detach its device even if their task is cancelled.
    static func runWithInput(_ executable: String, _ arguments: [String], input: Data,
                             cancelProcess: Bool = false) async throws -> ShellResult {
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { continuation in
            let process = box.process
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let inputPipe = Pipe()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            let buffer = PipeBuffer()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                buffer.set(stdout: outputPipe.fileHandleForReading.readDataToEndOfFile())
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                buffer.set(stderr: errorPipe.fileHandleForReading.readDataToEndOfFile())
                group.leave()
            }
            process.terminationHandler = { finished in
                group.wait()
                continuation.resume(returning: buffer.result(status: finished.terminationStatus))
            }
            do {
                try process.run()
                if cancelProcess && Task.isCancelled { box.terminate() }
                DispatchQueue.global().async {
                    try? inputPipe.fileHandleForWriting.write(contentsOf: input)
                    try? inputPipe.fileHandleForWriting.close()
                }
            } catch {
                try? inputPipe.fileHandleForWriting.close()
                continuation.resume(throwing: error)
            }
          }
        } onCancel: {
            if cancelProcess { box.terminate() }
        }
    }

    static func runToFile(_ executable: String, _ arguments: [String], output url: URL) async throws -> ShellResult {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let process = box.process
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardOutput = file
                let errorPipe = Pipe()
                process.standardError = errorPipe
                let errorBuffer = PipeBuffer()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errorBuffer.set(stderr: errorPipe.fileHandleForReading.readDataToEndOfFile())
                    group.leave()
                }
                process.terminationHandler = { proc in
                    group.wait()
                    continuation.resume(returning: errorBuffer.result(status: proc.terminationStatus))
                }
                do { try process.run() }
                catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            box.terminate()
        }
    }

    static func run(_ executable: String, _ arguments: [String], currentDirectory: URL? = nil) async throws -> ShellResult {
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let process = box.process
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                if let currentDirectory { process.currentDirectoryURL = currentDirectory }
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                let output = PipeBuffer()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    output.set(stdout: outPipe.fileHandleForReading.readDataToEndOfFile())
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    output.set(stderr: errPipe.fileHandleForReading.readDataToEndOfFile())
                    group.leave()
                }
                process.terminationHandler = { proc in
                    group.wait()
                    continuation.resume(returning: output.result(status: proc.terminationStatus))
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            box.terminate()
        }
    }

    static func which(_ name: String, extra: [String] = []) -> String? {
        let fm = FileManager.default
        var candidates = extra
        candidates += [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/opt/local/bin/\(name)",
            "\(fm.homeDirectoryForCurrentUser.path)/.local/bin/\(name)",
            "/usr/bin/\(name)",
            "/bin/\(name)",
        ]
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: name)?.path {
            candidates.insert(bundled, at: 0)
        }
        if let resource = Bundle.main.resourceURL?.appendingPathComponent(name).path {
            candidates.insert(resource, at: 1)
        }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }
}
