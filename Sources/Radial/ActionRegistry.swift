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
    case copyPath, reveal, openTerminal, duplicate, move, airDrop, createZip, extractZip

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
        }
    }
}

enum ActionRegistry {
    static func items(for mode: WheelMode, formats: [FileFormat], urls: [URL] = [], ffmpegAvailable: Bool? = nil) -> [RadialItem] {
        switch mode {
        case .convert:
            let hasFFmpeg = ffmpegAvailable ?? FFmpeg.isAvailable
            return ConversionMatrix.targets(for: formats)
                .filter { hasFFmpeg || nativeConversionPossible(from: formats, to: $0) }
                .map(RadialItem.init(format:))
        case .tools:
            if formats == [.pdf], urls.count == 1,
               PDFDocument(url: urls[0])?.isEncrypted == true {
                return [RadialItem(tool: .unlockPDF)]
            }
            return ToolID.available(for: formats)
                .filter { $0 != .unlockPDF }
                .map(RadialItem.init(tool:))
        case .actions:
            var actions: [FileAction] = [.copyPath, .reveal, .openTerminal, .duplicate, .move, .airDrop]
            if !urls.isEmpty { actions.append(.createZip) }
            if urls.count == 1, formats == [.zip] { actions.append(.extractZip) }
            return actions.map(RadialItem.init(fileAction:))
        case .ai:
            return AIAction.allCases.map(RadialItem.init(ai:))
        }
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
