import AppKit
import LupeCore

/// Finds the word under the mouse by capturing a small region and running Vision OCR on it.
/// Works in every app (PDFs, images, videos, games), but needs Screen Recording.
enum OCRReader {
    /// Region captured around the mouse, in points.
    static let regionSize = CGSize(width: 640, height: 200)

    /// Height of the full-width strip read when the sentence runs past the first one.
    static let wideRegionHeight: CGFloat = 240

    @MainActor
    static func word(at point: CGPoint) async -> TextHit? {
        var region = CGRect(x: point.x - regionSize.width / 2, y: point.y - regionSize.height / 2,
                            width: regionSize.width, height: regionSize.height)
        for attempt in 0..<2 {
            guard let shot = try? await ScreenCapturer.shared.capture(rect: region) else { return nil }
            let image = shot.image
            let lines: [RecognizedLine] = await Task.detached(priority: .userInitiated) {
                (try? TextRecognizer.recognize(image, options: RecognitionOptions(accurate: true))) ?? []
            }.value
            guard let hit = hit(in: lines, frame: shot.frame, at: point) else { return nil }
            // Lines cut by the strip's edge lose half their sentence ("…from the bank nk was great!"):
            // read a wider strip once so the whole sentence goes to the translator.
            if attempt == 0, linesCutByEdge(lines, frame: shot.frame, near: point) {
                // The whole width of the screen, so no line is cut on either side.
                let screen = ScreenCapturer.screen(containing: point)?.frame ?? region
                region = CGRect(x: screen.minX, y: point.y - wideRegionHeight / 2, width: screen.width, height: wideRegionHeight)
                continue
            }
            return hit
        }
        return nil
    }

    /// Whether text near `point` (the line and its neighbours) touches the left or right edge of the capture.
    static func linesCutByEdge(_ lines: [RecognizedLine], frame: CGRect, near point: CGPoint) -> Bool {
        let y = (point.y - frame.minY) / max(frame.height, 1)
        return lines.contains { line in
            let r = line.rect
            let band = max(r.height, 0.02) * 2.5
            return abs(r.midY - y) < band && (r.minX < 0.012 || r.maxX > 0.988)
        }
    }

    static func hit(in lines: [RecognizedLine], frame: CGRect, at point: CGPoint) -> TextHit? {
        TextHitFinder.hit(in: lines, frame: frame, at: point)
    }
}
