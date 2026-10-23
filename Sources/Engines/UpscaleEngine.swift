import Foundation

enum UpscaleEngine {
    struct Stage: Equatable {
        let inputScale: Int
        let inferredScale: Int
        let outputScale: Int
    }

    // ImageIO must decode each intermediate image to resize it. Cap peak
    // dimensions before starting so a large photo cannot exhaust memory at 8×.
    static let maximumInferredPixels = 100_000_000.0

    static var bundledDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Resources/Upscaler", isDirectory: true)
    }

    static var executable: URL? {
        guard let candidate = bundledDirectory?.appendingPathComponent("realesrgan-ncnn-vulkan"),
              FileManager.default.isExecutableFile(atPath: candidate.path) else { return nil }
        return candidate
    }

    static var isAvailable: Bool {
        guard let executable else { return false }
        return LocalToolHealth.responds(executable.path, arguments: ["-h"], acceptableStatuses: [255]) &&
            !UpscaleModelCatalog.bundledModels.isEmpty
    }

    static func arguments(input: URL, output: URL, model: UpscaleModel, scale: Int, format: FileFormat) throws -> [String] {
        guard [2, 3, 4].contains(scale), [.png, .jpg, .webp].contains(format) else {
            throw SatsumaError.invalidInput("Choose 2×, 3×, or 4× and PNG, JPG, or WebP output.")
        }
        return ["-i", input.path, "-o", output.path, "-m", model.directory.path,
                "-n", model.name, "-s", String(scale), "-f", format.fileExtension]
    }

    static func destinations(for files: [URL], scale: Int, format: FileFormat,
                             directoryFor: (URL) -> URL) -> [URL] {
        var reserved = Set<String>()
        return files.map { source in
            let directory = directoryFor(source)
            let base = ConversionMatrix.strippedBaseName(source.lastPathComponent)
            var suffix = "upscaled \(scale)x"
            var destination = ConversionMatrix.uniqueURL(directory: directory, baseName: base, suffix: suffix,
                                                          ext: format.fileExtension)
            var collision = 2
            while reserved.contains(destination.path) {
                suffix = "upscaled \(scale)x \(collision)"
                destination = ConversionMatrix.uniqueURL(directory: directory, baseName: base, suffix: suffix,
                                                          ext: format.fileExtension)
                collision += 1
            }
            reserved.insert(destination.path)
            return destination
        }
    }

    static func stages(nativeScale: Int, requestedScale: Int) throws -> [Stage] {
        guard (2...4).contains(nativeScale), (2...8).contains(requestedScale) else {
            throw SatsumaError.invalidInput("Choose an upscale amount from 2× to 8×.")
        }
        var passCount = 1
        var availableScale = nativeScale
        while availableScale < requestedScale {
            passCount += 1
            availableScale *= nativeScale
        }
        var inputScale = 1
        return (0..<passCount).map { index in
            let remainingPasses = passCount - index - 1
            let divisor = (0..<remainingPasses).reduce(1) { value, _ in value * nativeScale }
            let outputScale = (requestedScale + divisor - 1) / divisor
            let stage = Stage(inputScale: inputScale, inferredScale: inputScale * nativeScale,
                              outputScale: outputScale)
            inputScale = outputScale
            return stage
        }
    }

    static func maximumSafeScale(for files: [URL], model: UpscaleModel) -> Int {
        let sizes = files.map(ImageIOBridge.pixelSize)
        return maximumSafeScale(for: sizes, nativeScale: model.nativeScale)
    }

    static func maximumSafeScale(for sizes: [CGSize], nativeScale: Int) -> Int {
        guard !sizes.isEmpty else { return 0 }
        for scale in (2...8).reversed() {
            guard let plan = try? stages(nativeScale: nativeScale, requestedScale: scale) else { continue }
            let safe = sizes.allSatisfy { size in
                return size.width > 0 && size.height > 0 && plan.allSatisfy { stage in
                    let width = size.width * Double(stage.inferredScale)
                    let height = size.height * Double(stage.inferredScale)
                    return width <= 32768 && height <= 32768 && width * height <= maximumInferredPixels
                }
            }
            if safe { return scale }
        }
        return 0
    }

    static func upscaleBatch(files: [URL], destinations: [URL], model: UpscaleModel, scale: Int,
                             format: FileFormat, executable: URL? = executable,
                             progress: @escaping (Double) -> Void) async throws -> [URL] {
        guard !files.isEmpty, files.count == destinations.count else {
            throw SatsumaError.invalidInput("Choose at least one image to upscale.")
        }
        var outputs: [URL] = []
        for (index, source) in files.enumerated() {
            try Task.checkCancellation()
            let output = try await upscale(source: source, destination: destinations[index], model: model,
                                           scale: scale, format: format, executable: executable) { fraction in
                progress((Double(index) + fraction) / Double(files.count))
            }
            outputs.append(output)
        }
        return outputs
    }

    static func upscale(source: URL, destination: URL, model: UpscaleModel, scale: Int,
                        format: FileFormat, executable: URL? = executable,
                        progress: ((Double) -> Void)? = nil) async throws -> URL {
        guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw SatsumaError.invalidInput("The local upscaling engine is missing. Rebuild ZeroClick with its verified upscaler resources.")
        }
        guard FileFormat.detect(source)?.category == .image else {
            throw SatsumaError.invalidInput("Choose a readable still image to upscale.")
        }
        guard FileManager.default.fileExists(atPath: model.parameterFile.path),
              FileManager.default.fileExists(atPath: model.weightFile.path) else {
            throw SatsumaError.invalidInput("The selected model files are missing.")
        }
        let originalSize = ImageIOBridge.pixelSize(source)
        let plan = try stages(nativeScale: model.nativeScale, requestedScale: scale)
        guard originalSize.width > 0, originalSize.height > 0,
              plan.allSatisfy({ stage in
                  let width = originalSize.width * Double(stage.inferredScale)
                  let height = originalSize.height * Double(stage.inferredScale)
                  return width <= 32768 && height <= 32768 && width * height <= maximumInferredPixels
              }) else {
            throw SatsumaError.invalidInput("This image is too large for the selected upscale amount. Choose a lower amount or a smaller image.")
        }
        let working = FileManager.default.temporaryDirectory
            .appendingPathComponent("zeroclick-upscale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: working) }
        // This NCNN build recognizes only a model-path ending in "models" or
        // "models2". Personal imports live in UUID folders, so expose a
        // temporary read-only path name without moving or copying the weights.
        let backendModels = working.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: backendModels, withDestinationURL: model.directory)
        let input = working.appendingPathComponent("input.png")
        try ImageIOBridge.write(ImageIOBridge.load(source), to: input, format: .png)
        try Task.checkCancellation()
        return try await OutputWriter.writeAsync(to: destination) { staged in
            var passInput = input
            for (index, stage) in plan.enumerated() {
                try Task.checkCancellation()
                let isLast = index == plan.count - 1
                let needsResize = stage.inferredScale != stage.outputScale
                let passOutput = isLast ? staged : working.appendingPathComponent("pass-\(index).png")
                let inferred = needsResize ? working.appendingPathComponent("inferred-\(index).png") : passOutput
                let backendFormat = (isLast && !needsResize) ? format : .png
                var args = try arguments(input: passInput, output: inferred, model: model,
                                         scale: model.nativeScale, format: backendFormat)
                if let pathIndex = args.firstIndex(of: "-m") { args[pathIndex + 1] = backendModels.path }
                let result = try await Shell.run(executable.path, args)
                try Task.checkCancellation()
                guard result.succeeded else {
                    throw SatsumaError.toolFailed("Upscale", result.stderr.isEmpty ? result.stdout : result.stderr)
                }
                guard ImageIOBridge.pixelSize(inferred) == CGSize(width: originalSize.width * Double(stage.inferredScale),
                                                                   height: originalSize.height * Double(stage.inferredScale)) else {
                    throw SatsumaError.encodeFailed("upscaled image dimensions")
                }
                if needsResize {
                    let image = try ImageIOBridge.load(inferred)
                    let resized = ImageIOBridge.scaled(image, to: CGSize(width: originalSize.width * Double(stage.outputScale),
                                                                         height: originalSize.height * Double(stage.outputScale)))
                    try Task.checkCancellation()
                    try await ImageIOBridge.writeAnyFormat(resized, to: passOutput,
                                                           format: isLast ? format : .png)
                    try? FileManager.default.removeItem(at: inferred)
                }
                passInput = passOutput
                progress?(Double(index + 1) / Double(plan.count))
            }
            let size = ImageIOBridge.pixelSize(staged)
            guard size.width == originalSize.width * Double(scale),
                  size.height == originalSize.height * Double(scale) else {
                throw SatsumaError.encodeFailed("upscaled image dimensions")
            }
        }
    }
}
