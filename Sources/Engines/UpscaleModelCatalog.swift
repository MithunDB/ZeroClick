import Foundation

struct UpscaleModel: Identifiable, Hashable {
    let name: String
    let directory: URL
    let parameterFile: URL
    let weightFile: URL

    var id: String { directory.path + "/" + name }

    var displayName: String {
        switch name.lowercased() {
        case "realesr-animevideov3-x4": return "Fast 4× · illustrations"
        case "upscayl-lite-4x": return "Upscayl Lite 4× · personal model"
        case "ultrasharp-4x": return "UltraSharp 4× · non-commercial"
        case "ultramix-balanced-4x": return "Ultramix Balanced 4× · non-commercial"
        default: return name
        }
    }

    // NCNN's -s option is the model's inference scale, not a reliable output
    // resize control for every model. In particular, running an x4 model at
    // -s 2 or -s 3 rearranges tiles instead of producing a smaller image.
    var nativeScale: Int {
        for value in [4, 3, 2] where name.lowercased().contains("x\(value)") { return value }
        return 4
    }
}

enum UpscaleModelCatalog {
    static var personalDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZeroClick/Models", isDirectory: true)
    }

    static var bundledModels: [UpscaleModel] {
        guard let directory = UpscaleEngine.bundledDirectory else { return [] }
        return models(in: directory.appendingPathComponent("models", isDirectory: true), nested: false)
    }

    static var availableModels: [UpscaleModel] {
        bundledModels + models(in: personalDirectory)
    }

    static func models(in root: URL, nested: Bool = true) -> [UpscaleModel] {
        let manager = FileManager.default
        if !nested { return modelsInFolder(root) }
        guard let folders = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return [] }
        return folders.filter { isDirectory($0) }.flatMap(modelsInFolder)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func importPair(parameter: URL, weights: URL, into root: URL = personalDirectory) throws -> UpscaleModel {
        let name = parameter.deletingPathExtension().lastPathComponent
        guard parameter.pathExtension.lowercased() == "param",
              weights.pathExtension.lowercased() == "bin",
              weights.deletingPathExtension().lastPathComponent == name,
              !name.isEmpty, name != ".", name != "..",
              isRegularFile(parameter), isRegularFile(weights),
              hasData(parameter), hasData(weights) else {
            throw SatsumaError.invalidInput("Choose a nonempty .param and .bin pair with the same filename. Symbolic links are not supported.")
        }
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            let importedParameter = folder.appendingPathComponent(name + ".param")
            let importedWeights = folder.appendingPathComponent(name + ".bin")
            try manager.copyItem(at: parameter, to: importedParameter)
            try manager.copyItem(at: weights, to: importedWeights)
            guard hasData(importedParameter), hasData(importedWeights) else {
                throw SatsumaError.invalidInput("The imported model is empty.")
            }
            return UpscaleModel(name: name, directory: folder, parameterFile: importedParameter, weightFile: importedWeights)
        } catch {
            try? manager.removeItem(at: folder)
            throw error
        }
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func modelsInFolder(_ folder: URL) -> [UpscaleModel] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return [] }
        let regular = files.filter(isRegularFile)
        return regular.filter { $0.pathExtension.lowercased() == "param" }.compactMap { parameter -> UpscaleModel? in
            let name = parameter.deletingPathExtension().lastPathComponent
            guard let weights = regular.first(where: { $0.lastPathComponent == name + ".bin" }),
                  hasData(parameter), hasData(weights) else { return nil }
            return UpscaleModel(name: name, directory: folder, parameterFile: parameter, weightFile: weights)
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func hasData(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]) else { return false }
        return (values.fileSize ?? 0) > 0
    }
}
