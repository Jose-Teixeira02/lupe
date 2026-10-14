import AppKit
import LupeCore

/// Finds the word under the mouse by capturing a small region and running Vision OCR on it.
/// Works in every app (PDFs, images, videos, games), but needs Screen Recording.
enum OCRReader {
    /// Region captured around the mouse, in points.
    static let regionSize = CGSize(width: 640, height: 200)

    @MainActor
    static func word(at point: CGPoint) async -> TextHit? {
        let region = CGRect(x: point.x - regionSize.width / 2, y: point.y - regionSize.height / 2,
                            width: regionSize.width, height: regionSize.height)
        guard let shot = try? await ScreenCapturer.shared.capture(rect: region) else { return nil }
        let image = shot.image
        let lines: [RecognizedLine] = await Task.detached(priority: .userInitiated) {
            (try? TextRecognizer.recognize(image, options: RecognitionOptions(accurate: true))) ?? []
        }.value
        return hit(in: lines, frame: shot.frame, at: point)
    }

    static func hit(in lines: [RecognizedLine], frame: CGRect, at point: CGPoint) -> TextHit? {
        TextHitFinder.hit(in: lines, frame: frame, at: point)
    }
}
