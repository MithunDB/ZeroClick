import AppKit
import Foundation

@MainActor
enum FileActionRunner {
    static func perform(_ action: FileAction, with urls: [URL]) {
        guard !urls.isEmpty else { return }
        switch action {
        case .copyPath:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        case .openTerminal:
            let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            let folders = Array(Set(urls.map { url in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
                    ? url : url.deletingLastPathComponent()
            }))
            NSWorkspace.shared.open(folders, withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        case .duplicate:
            for url in urls {
                let destination = duplicateDestination(for: url)
                JobRunner.shared.run(title: "Duplicating", detail: url.lastPathComponent, symbol: "plus.square.on.square") { progress in
                    let staged = destination.deletingLastPathComponent().appendingPathComponent(".zeroclick-\(UUID().uuidString)")
                    do {
                        try Task.checkCancellation()
                        try FileManager.default.copyItem(at: url, to: staged)
                        try Task.checkCancellation()
                        try FileManager.default.moveItem(at: staged, to: destination)
                        progress(1)
                        return [destination]
                    } catch {
                        try? FileManager.default.removeItem(at: staged)
                        throw error
                    }
                }
            }
        case .move:
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "Move Here"
            NSApp.activate(ignoringOtherApps: true)
            panel.begin { response in
                guard response == .OK, let folder = panel.url else { return }
                for url in urls {
                    let destination = uniqueDestination(for: url, in: folder)
                    JobRunner.shared.run(title: "Moving", detail: url.lastPathComponent, symbol: "folder.badge.arrow.forward") { progress in
                        try Task.checkCancellation()
                        try FileManager.default.moveItem(at: url, to: destination)
                        progress(1)
                        return [destination]
                    }
                }
            }
        case .airDrop:
            NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls)
        case .createZip:
            let destination = ArchiveActionRunner.zipDestination(for: urls)
            JobRunner.shared.run(title: "Creating ZIP", detail: destination.lastPathComponent, symbol: "archivebox") { progress in
                let result = try await ArchiveActionRunner.createZip(from: urls, to: destination)
                progress(1)
                return [result]
            }
        case .extractZip:
            guard let source = urls.first, FileFormat.detect(source) == .zip else { return }
            if (try? ZipSafety.validate(source).isEncrypted) == true {
                ToolWindowManager.shared.open(.unlockZIP, files: [source])
                return
            }
            let destination = ArchiveActionRunner.extractionDestination(for: source)
            JobRunner.shared.run(title: "Extracting ZIP", detail: source.lastPathComponent, symbol: "archivebox.fill") { progress in
                let result = try await ArchiveActionRunner.extractZip(source, to: destination)
                progress(1)
                return [result]
            }
        case .encrypt:
            guard let source = urls.first else { return }
            SecureFileWindowManager.shared.open(source, decrypting: false)
        case .decrypt:
            guard let source = urls.first else { return }
            SecureFileWindowManager.shared.open(source, decrypting: true)
        }
    }

    static func duplicateDestination(for url: URL) -> URL {
        uniqueDestination(for: url, in: url.deletingLastPathComponent(), suffix: "copy")
    }

    static func uniqueDestination(for url: URL, in folder: URL, suffix: String = "") -> URL {
        var isDirectory: ObjCBool = false
        let directory = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        let stem = directory ? url.lastPathComponent : ConversionMatrix.strippedBaseName(url.lastPathComponent)
        let name = suffix.isEmpty ? stem : "\(stem) \(suffix)"
        if directory { return ConversionMatrix.uniqueDirectory(directory: folder, name: name) }
        return ConversionMatrix.uniqueURL(directory: folder, baseName: stem, suffix: suffix, ext: url.pathExtension)
    }
}
