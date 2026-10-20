import Foundation

struct ConversionRequest {
    let source: URL
    let sourceFormat: FileFormat
    let target: FileFormat
    let destination: URL
    let progress: (Double) -> Void
}

protocol ConversionEngine {
    func supports(from: FileFormat, to: FileFormat) -> Bool
    func convert(_ request: ConversionRequest) async throws
}

enum Engines {
    static let all: [ConversionEngine] = [
        ImageEngine(),
        AudioEngine(),
        VideoEngine(),
        DocumentEngine(),
        SubtitleEngine(),
        ArchiveEngine(),
    ]

    static func engine(from: FileFormat, to: FileFormat) -> ConversionEngine? {
        all.first { $0.supports(from: from, to: to) }
    }

    static func convert(_ request: ConversionRequest, using selectedEngine: ConversionEngine? = nil) async throws -> URL {
        guard let engine = selectedEngine ?? engine(from: request.sourceFormat, to: request.target) else {
            DiagnosticLog.log("no engine for \(request.sourceFormat.rawValue) -> \(request.target.rawValue)")
            throw SatsumaError.unsupportedConversion(request.sourceFormat, request.target)
        }
        DiagnosticLog.log("engine \(type(of: engine)) \(request.sourceFormat.rawValue) -> \(request.target.rawValue) src=\(request.source.path)")
        let temp = request.destination.deletingLastPathComponent()
            .appendingPathComponent(".zeroclick-\(UUID().uuidString).\(request.destination.pathExtension)")
        let staged = ConversionRequest(
            source: request.source,
            sourceFormat: request.sourceFormat,
            target: request.target,
            destination: temp,
            progress: request.progress
        )
        do {
            try await engine.convert(staged)
            try Task.checkCancellation()
            DiagnosticLog.log("engine finished, staged=\(temp.lastPathComponent)")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: temp.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    let contents = try FileManager.default.contentsOfDirectory(atPath: temp.path)
                    guard !contents.isEmpty else {
                        throw SatsumaError.encodeFailed(request.destination.lastPathComponent)
                    }
                    let folder = ConversionMatrix.uniqueDirectory(
                        directory: request.destination.deletingLastPathComponent(),
                        name: request.destination.deletingPathExtension().lastPathComponent
                    )
                    try FileManager.default.moveItem(at: temp, to: folder)
                    return folder
                } else {
                    let attributes = try FileManager.default.attributesOfItem(atPath: temp.path)
                    guard (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0 else {
                        throw SatsumaError.encodeFailed(request.destination.lastPathComponent)
                    }
                    try FileManager.default.moveItem(at: temp, to: request.destination)
                    return request.destination
                }
            } else {
                throw SatsumaError.encodeFailed(request.destination.lastPathComponent)
            }
        } catch {
            DiagnosticLog.log("engine threw: \(error)")
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }
}
