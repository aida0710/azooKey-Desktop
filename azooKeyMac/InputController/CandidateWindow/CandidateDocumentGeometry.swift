import AppKit

/// IMK character indices are UTF-16 offsets relative to the inline session.
/// Reject wrapped, vertical, missing, or non-increasing client rectangles.
struct CandidateDocumentGeometry {
    let anchor: CGPoint
    let widths: [CGFloat]

    init?(words: [String], preedit: String, rectAtOffset: (Int) -> NSRect) {
        // Bound synchronous requests into the document application.
        let maximumWordCount = 64
        guard !words.isEmpty, words.count <= maximumWordCount, words.joined() == preedit else {
            return nil
        }
        var offsets = [0]
        for word in words { offsets.append(offsets.last! + word.utf16.count) }
        let rects = offsets.map(rectAtOffset)
        guard let first = rects.first, first.height > 0,
              rects.allSatisfy({ $0.minX.isFinite && $0.minY.isFinite && abs($0.minY - first.minY) <= 1 && abs($0.height - first.height) <= 1 }) else {
            return nil
        }
        let widths = zip(rects, rects.dropFirst()).map { $1.minX - $0.minX }
        guard widths.allSatisfy({ $0 >= 6 && $0 < 4000 }) else {
            return nil
        }
        self.anchor = CGPoint(x: first.minX - 12, y: first.minY)
        self.widths = widths
    }

    func fits(in bounds: CGRect) -> Bool {
        let popupWidth = max(CandidateDetailView.minimumWidth, widths.reduce(12, +))
        return bounds.contains(anchor) && anchor.x + popupWidth <= bounds.maxX
    }
}
