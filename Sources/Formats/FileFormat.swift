import Foundation
import UniformTypeIdentifiers

enum FormatCategory: String, CaseIterable {
    case image
    case audio
    case video
    case document
    case subtitle
    case archive

    var symbol: String {
        switch self {
        case .image: return "photo"
        case .audio: return "waveform"
        case .video: return "film"
        case .document: return "doc.text"
        case .subtitle: return "captions.bubble"
        case .archive: return "archivebox"
        }
    }

    var title: String {
        switch self {
        case .image: return "Image"
        case .audio: return "Audio"
        case .video: return "Video"
        case .document: return "Document"
        case .subtitle: return "Subtitle"
        case .archive: return "Archive"
        }
    }
}

enum FileFormat: String, CaseIterable, Identifiable, Hashable {
    case jpg, png, webp, heic, tiff, svg, avif, bmp, gif
    case mp3, m4a, wav, flac, ogg, opus, aiff, wma
    case mp4, mov, mkv, webm, avi, wmv
    case pdf, docx, txt, md
    case srt, vtt
    case zip, tar, gz, rar

    var id: String { rawValue }

    static let images: [FileFormat] = [.jpg, .png, .webp, .heic, .tiff, .svg, .avif, .bmp]
    static let imageTargets: [FileFormat] = [.jpg, .png, .webp, .heic, .tiff, .avif, .bmp, .pdf]
    static let audio: [FileFormat] = [.mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma]
    static let video: [FileFormat] = [.mp4, .mov, .mkv, .webm, .avi, .wmv]
    static let subtitles: [FileFormat] = [.srt, .vtt]
    static let archives: [FileFormat] = [.zip, .tar, .gz, .rar]

    var category: FormatCategory {
        switch self {
        case .jpg, .png, .webp, .heic, .tiff, .svg, .avif, .bmp: return .image
        case .gif: return .video
        case .mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma: return .audio
        case .mp4, .mov, .mkv, .webm, .avi, .wmv: return .video
        case .pdf, .docx, .txt, .md: return .document
        case .srt, .vtt: return .subtitle
        case .zip, .tar, .gz, .rar: return .archive
        }
    }

    var displayName: String {
        switch self {
        case .gz: return "GZIP"
        default: return rawValue.uppercased()
        }
    }

    var fileExtension: String {
        switch self {
        case .gz: return "tar.gz"
        default: return rawValue
        }
    }

    var aliases: [String] {
        switch self {
        case .jpg: return ["jpg", "jpeg", "jpe", "jfif"]
        case .tiff: return ["tiff", "tif"]
        case .heic: return ["heic", "heif"]
        case .m4a: return ["m4a", "aac", "m4b"]
        case .mp4: return ["mp4", "m4v"]
        case .mov: return ["mov", "qt"]
        case .gz: return ["gz", "tgz"]
        case .txt: return ["txt", "text", "log"]
        case .md: return ["md", "markdown"]
        case .aiff: return ["aiff", "aif"]
        default: return [rawValue]
        }
    }

    var utType: UTType? {
        switch self {
        case .jpg: return .jpeg
        case .png: return .png
        case .webp: return .webP
        case .heic: return .heic
        case .tiff: return .tiff
        case .svg: return .svg
        case .avif: return UTType("public.avif")
        case .bmp: return .bmp
        case .gif: return .gif
        case .mp3: return .mp3
        case .m4a: return .mpeg4Audio
        case .wav: return .wav
        case .flac: return UTType("org.xiph.flac")
        case .ogg: return UTType("org.xiph.ogg-audio") ?? UTType("public.ogg")
        case .opus: return UTType("public.opus") ?? UTType("org.xiph.opus")
        case .aiff: return .aiff
        case .wma: return UTType("com.microsoft.windows-media-wma")
        case .mp4: return .mpeg4Movie
        case .mov: return .quickTimeMovie
        case .mkv: return UTType("org.matroska.mkv")
        case .webm: return UTType("org.webmproject.webm")
        case .avi: return .avi
        case .wmv: return UTType("com.microsoft.windows-media-wmv")
        case .pdf: return .pdf
        case .docx: return UTType("org.openxmlformats.wordprocessingml.document")
        case .txt: return .plainText
        case .md: return UTType(filenameExtension: "md") ?? .plainText
        case .srt: return UTType("com.subrip.srt") ?? .plainText
        case .vtt: return UTType("org.w3.webvtt") ?? .plainText
        case .zip: return .zip
        case .tar: return UTType("public.tar-archive")
        case .gz: return .gzip
        case .rar: return UTType("com.rarlab.rar-archive")
        }
    }

    static func detect(_ url: URL) -> FileFormat? {
        let name = url.lastPathComponent.lowercased()
        let format: FileFormat?
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") {
            format = .gz
        } else {
            format = detect(extension: url.pathExtension)
        }
        guard let format else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return format }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 512), !data.isEmpty else { return nil }
        return matchesKnownSignature(data, format: format) ? format : nil
    }

    private static func matchesKnownSignature(_ data: Data, format: FileFormat) -> Bool {
        let bytes = [UInt8](data)
        func begins(_ signature: [UInt8]) -> Bool { bytes.starts(with: signature) }
        switch format {
        case .jpg: return begins([0xFF, 0xD8, 0xFF])
        case .png: return begins([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        case .gif: return begins(Array("GIF87a".utf8)) || begins(Array("GIF89a".utf8))
        case .pdf: return begins(Array("%PDF-".utf8))
        case .webp: return begins(Array("RIFF".utf8)) && bytes.count >= 12 && Array(bytes[8..<12]) == Array("WEBP".utf8)
        case .bmp: return begins(Array("BM".utf8))
        case .tiff: return begins([0x49, 0x49, 0x2A, 0x00]) || begins([0x4D, 0x4D, 0x00, 0x2A])
        case .zip, .docx: return begins([0x50, 0x4B, 0x03, 0x04])
        case .gz: return begins([0x1F, 0x8B])
        case .rar: return begins([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07])
        case .wav: return begins(Array("RIFF".utf8)) && bytes.count >= 12 && Array(bytes[8..<12]) == Array("WAVE".utf8)
        case .flac: return begins(Array("fLaC".utf8))
        case .ogg, .opus: return begins(Array("OggS".utf8))
        case .txt, .md, .srt, .vtt, .svg: return String(data: data, encoding: .utf8) != nil && !bytes.contains(0)
        default:
            // Some media containers require a deeper parser; at least reject a
            // clearly different supported format before offering actions.
            let known: [FileFormat] = [.jpg, .png, .gif, .pdf, .webp, .bmp, .tiff, .zip, .gz, .rar, .wav, .flac]
            return !known.contains { matchesKnownSignature(data, format: $0) }
        }
    }

    static func detect(extension ext: String) -> FileFormat? {
        let lower = ext.lowercased()
        return allCases.first { $0.aliases.contains(lower) }
    }

    var isMultiTrack: Bool { category == .video || category == .audio }
}
