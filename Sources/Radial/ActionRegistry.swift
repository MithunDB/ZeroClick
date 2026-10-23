import Foundation
import PDFKit

enum WheelMode: Equatable {
    case convert
    case tools
    case actions
    case ai

    var centerTitle: String {
        switch self {
        case .convert: "CONVERT"
        case .tools: "TOOLS"
        case .actions: "FILE ACTIONS"
        case .ai: "AI · COMING LATER"
        }
    }
}

enum FileAction: String, CaseIterable, Hashable {
    case copyPath, reveal, openTerminal, duplicate, move, airDrop, createZip, extractZip, encrypt, decrypt

    var title: String {
        switch self {
        case .copyPath: return "Copy Path"
        case .reveal: return "Reveal in Finder"
        case .openTerminal: return "Open in Terminal"
        case .duplicate: return "Duplicate"
        case .move: return "Move…"
        case .airDrop: return "AirDrop…"
        case .createZip: return "Create ZIP"
        case .extractZip: return "Extract ZIP"
        case .encrypt: return "Encrypt file"
        case .decrypt: return "Decrypt file"
        }
    }

    var symbol: String {
        switch self {
        case .copyPath: return "document.on.clipboard"
        case .reveal: return "folder"
        case .openTerminal: return "terminal"
        case .duplicate: return "plus.square.on.square"
        case .move: return "folder.badge.arrow.forward"
        case .airDrop: return "airdrop"
        case .createZip: return "archivebox"
        case .extractZip: return "archivebox.fill"
        case .encrypt: return "lock.doc"
        case .decrypt: return "lock.open"
        }
    }
}

enum ActionRegistry {
    static func items(for mode: WheelMode, formats: [FileFormat], urls: [URL] = [],
                      ffmpegAvailable: Bool? = nil, bsdtarAvailable: Bool? = nil) -> [RadialItem] {
        switch mode {
        case .convert:
            let hasFFmpeg = ffmpegAvailable ?? FFmpeg.isAvailable
            let hasBsdtar = bsdtarAvailable ?? LocalToolHealth.responds("/usr/bin/bsdtar", arguments: ["--version"])
            let completeSelection = urls.isEmpty || urls.count == formats.count
            let available = Set(completeSelection ? ConversionMatrix.targets(for: formats) : [])
            let categories = Set(formats.map(\.category))
            let candidates = FileFormat.allCases.filter { source in
                categories.contains(source.category)
            }.flatMap(ConversionMatrix.targets(for:))
            var seen: Set<FileFormat> = []
            return candidates.filter { seen.insert($0).inserted }.map { target in
                if !available.contains(target) {
                    return RadialItem(format: target, disabledReason: "Not for selection")
                }
                if formats.contains(.rar) && !hasBsdtar {
                    return RadialItem(format: target, disabledReason: "Needs macOS bsdtar; restore the system archive tool")
                }
                if !hasFFmpeg && !nativeConversionPossible(from: formats, to: target) {
                    return RadialItem(format: target, disabledReason: "Needs working FFmpeg; install it or set its path in Settings")
                }
                return RadialItem(format: target)
            }
        case .tools:
            let available = Set(availableTools(for: formats, urls: urls))
            let categories = Set(formats.map(\.category))
            let candidates = ToolID.allCases.filter { tool in
                !categories.isDisjoint(with: tool.categories)
            }
            if categories.isEmpty {
                return [ToolID.encryptFile, .decryptFile].map { tool in
                    RadialItem(tool: tool, disabledReason: available.contains(tool) ? nil : "Not for selection")
                }
            }
            return candidates.map { tool in
                if tool == .upscaleImage && !UpscaleEngine.isAvailable {
                    return RadialItem(tool: tool,
                        disabledReason: "Upscaler unavailable; prepare verified resources and rebuild")
                }
                return RadialItem(tool: tool, disabledReason: available.contains(tool) ? nil : "Not for selection")
            }
        case .actions:
            let available = Set(availableActions(for: formats, urls: urls))
            return FileAction.allCases.map { action in
                RadialItem(fileAction: action, disabledReason: available.contains(action) ? nil : "Not for selection")
            }
        case .ai:
            return AIAction.allCases.map(RadialItem.init(ai:))
        }
    }

    private static func availableTools(for formats: [FileFormat], urls: [URL]) -> [ToolID] {
            if urls.count > 1 && urls.count != formats.count { return [] }
            if urls.count == 1,
               SecureFile.isEncrypted(urls[0]) || NativeEncryptedArchive.isEncrypted(urls[0]) ||
               (NativeDiskImage.isAvailable && NativeDiskImage.isEncrypted(urls[0])) {
                return [.decryptFile]
            }
            if formats == [.zip], urls.count == 1,
               (try? ZipSafety.validate(urls[0]).isEncrypted) == true {
                return [.unlockZIP, .encryptFile]
            }
            if formats == [.pdf], urls.count == 1,
               PDFDocument(url: urls[0])?.isEncrypted == true {
                return [.unlockPDF, .encryptFile]
            }
            if formats.isEmpty, urls.count == 1,
               !["zclick", "aea", "dmg"].contains(urls[0].pathExtension.lowercased()) {
                var directory: ObjCBool = false
                if FileManager.default.fileExists(atPath: urls[0].path, isDirectory: &directory), !directory.boolValue {
                    return [.encryptFile]
                }
            }
            return ToolID.available(for: formats)
                .filter { tool in
                    tool != .unlockPDF && tool != .unlockZIP && tool != .decryptFile &&
                    (tool != .upscaleImage || UpscaleEngine.isAvailable)
                }
    }

    private static func availableActions(for formats: [FileFormat], urls: [URL]) -> [FileAction] {
            var actions: [FileAction] = [.copyPath, .reveal, .openTerminal, .duplicate, .move, .airDrop]
            if !urls.isEmpty { actions.append(.createZip) }
            if urls.count == 1, formats == [.zip] { actions.append(.extractZip) }
            var isDirectory: ObjCBool = false
            if urls.count == 1,
               FileManager.default.fileExists(atPath: urls[0].path, isDirectory: &isDirectory),
               !isDirectory.boolValue {
                if SecureFile.isEncrypted(urls[0]) || NativeEncryptedArchive.isEncrypted(urls[0]) ||
                   (NativeDiskImage.isAvailable && NativeDiskImage.isEncrypted(urls[0])) {
                    actions.append(.decrypt)
                } else if !["zclick", "aea", "dmg"].contains(urls[0].pathExtension.lowercased()) {
                    actions.append(.encrypt)
                }
            }
            return actions
    }

    private static func nativeConversionPossible(from sources: [FileFormat], to target: FileFormat) -> Bool {
        sources.allSatisfy { source in
            switch source.category {
            case .image:
                return target == .pdf || target == .docx || ImageIOBridge.canEncodeNatively(target)
            case .audio:
                let nativeSources: Set<FileFormat> = [.mp3, .m4a, .wav, .aiff]
                return nativeSources.contains(source) && AudioEngine.nativeTargets.contains(target)
            case .video:
                return [.mp4, .mov].contains(source) && VideoEngine.nativeTargets.contains(target)
            default:
                return true
            }
        }
    }
}
