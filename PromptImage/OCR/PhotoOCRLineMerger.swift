import CoreGraphics
import Foundation

/// Resolve duplicate observations only where different OCR tiles saw the same line.
/// A detection survives even when its neighboring tile failed to recognize it.
nonisolated enum PhotoOCRLineMerger {
    struct Detection: Sendable {
        let line: PhotoOCRLine
        let tileIndex: Int
        let isInterior: Bool
    }

    private struct Candidate {
        let detection: Detection
        let text: String

        init(_ detection: Detection) {
            self.detection = detection
            text = String(detection.line.text.lowercased().filter { $0.isLetter || $0.isNumber })
        }
    }

    static func merge(_ detections: [Detection]) -> [PhotoOCRLine] {
        var retained: [Candidate] = []
        for detection in detections {
            let candidate = Candidate(detection)
            let matches = retained.indices.filter { duplicates(retained[$0], candidate) }
            var winner = candidate
            for index in matches { winner = preferred(retained[index], winner) }
            for index in matches.reversed() { retained.remove(at: index) }
            retained.append(winner)
        }

        // Top-to-bottom, then left-to-right; this is not document layout reconstruction.
        return retained.map(\.detection.line).sorted {
            if $0.boundingBox.midY != $1.boundingBox.midY { return $0.boundingBox.midY > $1.boundingBox.midY }
            return $0.boundingBox.minX < $1.boundingBox.minX
        }
    }

    private static func duplicates(_ left: Candidate, _ right: Candidate) -> Bool {
        guard left.detection.tileIndex != right.detection.tileIndex else { return false }
        let a = left.detection.line.boundingBox
        let b = right.detection.line.boundingBox
        let intersection = a.intersection(b)
        guard a.width > 0, b.width > 0, a.height > 0, b.height > 0,
              !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return false }
        let overlap = intersection.width * intersection.height / min(a.width * a.height, b.width * b.height)
        let verticalOverlap = intersection.height / min(a.height, b.height)
        guard overlap >= 0.6, verticalOverlap >= 0.7 else { return false }
        if compatible(left.text, right.text) { return true }

        // Tile context may change Vision's spelling. Near-identical line geometry
        // is also sufficient, but a nearby word or a separate row is not.
        return overlap >= 0.85
            && min(a.width, b.width) / max(a.width, b.width) >= 0.75
            && min(a.height, b.height) / max(a.height, b.height) >= 0.7
            && abs(a.midY - b.midY) <= max(a.height, b.height) * 0.2
    }

    private static func compatible(_ left: String, _ right: String) -> Bool {
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left == right { return true }
        return min(left.count, right.count) >= 4 && (left.contains(right) || right.contains(left))
    }

    private static func preferred(_ left: Candidate, _ right: Candidate) -> Candidate {
        // A longer matching string recovers a line clipped by an internal crop edge.
        if compatible(left.text, right.text), left.text.count != right.text.count {
            return left.text.count > right.text.count ? left : right
        }
        if left.detection.isInterior != right.detection.isInterior {
            return left.detection.isInterior ? left : right
        }
        if left.detection.line.confidence != right.detection.line.confidence {
            return left.detection.line.confidence > right.detection.line.confidence ? left : right
        }
        if left.text.count != right.text.count { return left.text.count > right.text.count ? left : right }
        return left.detection.tileIndex <= right.detection.tileIndex ? left : right
    }
}
