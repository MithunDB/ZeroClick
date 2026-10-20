import CoreGraphics
import Foundation
import Vision

enum RedactionSuggestions {
    enum Kind { case faces, text }

    static func detect(_ kind: Kind, in image: CGImage) throws -> [CGRect] {
        let boxes: [CGRect]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        switch kind {
        case .faces:
            let request = VNDetectFaceRectanglesRequest()
            try handler.perform([request])
            boxes = (request.results ?? []).map(\.boundingBox)
        case .text:
            let request = VNDetectTextRectanglesRequest()
            request.reportCharacterBoxes = false
            try handler.perform([request])
            boxes = (request.results ?? []).map(\.boundingBox)
        }
        let size = CGSize(width: image.width, height: image.height)
        return boxes.compactMap { box in
            let rect = imageRect(from: box, size: size)
            return rect.width >= 2 && rect.height >= 2 ? rect : nil
        }
    }

    static func imageRect(from normalized: CGRect, size: CGSize) -> CGRect {
        CGRect(
            x: normalized.minX * size.width,
            y: (1 - normalized.maxY) * size.height,
            width: normalized.width * size.width,
            height: normalized.height * size.height
        ).intersection(CGRect(origin: .zero, size: size))
    }
}
