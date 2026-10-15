import AppKit
import ScreenCaptureKit

/// A captured piece of screen and where it was, in global Cocoa points (origin bottom-left).
struct CapturedImage {
    var image: CGImage
    var frame: CGRect
    var screen: NSScreen
}

enum CaptureError: Error, LocalizedError {
    case noPermission
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .noPermission: "Lupe needs Screen Recording permission to read text on screen."
        case .noDisplay: "Couldn't find the display under the mouse."
        }
    }
}

/// ScreenCaptureKit screenshots that never include Lupe's own windows (labels, cards).
@MainActor
final class ScreenCapturer {
    static let shared = ScreenCapturer()

    private var content: SCShareableContent?
    private var contentFetched = Date.distantPast

    private func shareableContent() async throws -> SCShareableContent {
        if let content, Date().timeIntervalSince(contentFetched) < 1 { return content }
        do {
            let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            content = c
            contentFetched = Date()
            return c
        } catch {
            throw CaptureError.noPermission
        }
    }

    func invalidate() { content = nil }

    static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    /// Captures `rect` (global points), clipped to the screen that contains its centre.
    /// - Parameter maxPixelWidth: downscale big captures (full screens) to keep OCR fast.
    func capture(rect: CGRect, maxPixelWidth: CGFloat = .infinity) async throws -> CapturedImage {
        guard let screen = Self.screen(containing: CGPoint(x: rect.midX, y: rect.midY)),
              let displayID = Self.displayID(of: screen) else { throw CaptureError.noDisplay }
        let content = try await shareableContent()
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            invalidate()
            throw CaptureError.noDisplay
        }
        // Hide Lupe's floating layers (tags, cards, lens) but keep its normal windows (Journey),
        // so text behind the Journey window isn't "seen through" it.
        let pid = ProcessInfo.processInfo.processIdentifier
        let ownFloating = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer > 0 }
        let filter = SCContentFilter(display: display, excludingWindows: ownFloating)

        let clipped = rect.intersection(screen.frame)
        guard !clipped.isNull, clipped.width > 4, clipped.height > 4 else { throw CaptureError.noDisplay }
        // sourceRect is in the display's local points with a top-left origin.
        let local = CGRect(x: clipped.minX - screen.frame.minX,
                           y: screen.frame.maxY - clipped.maxY,
                           width: clipped.width, height: clipped.height)
        var scale = screen.backingScaleFactor
        if clipped.width * scale > maxPixelWidth { scale = max(1, maxPixelWidth / clipped.width) }

        let config = SCStreamConfiguration()
        config.sourceRect = local
        config.width = Int((clipped.width * scale).rounded())
        config.height = Int((clipped.height * scale).rounded())
        config.showsCursor = false
        config.capturesAudio = false
        config.ignoreShadowsDisplay = true

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return CapturedImage(image: image, frame: clipped, screen: screen)
    }

    func captureScreen(_ screen: NSScreen, maxPixelWidth: CGFloat = 3600) async throws -> CapturedImage {
        try await capture(rect: screen.frame, maxPixelWidth: maxPixelWidth)
    }

    /// A tiny grayscale thumbnail used to notice when the screen content changes.
    func fingerprint(of screen: NSScreen) async throws -> [UInt8] {
        let shot = try await capture(rect: screen.frame, maxPixelWidth: 96)
        return Self.grayscale(shot.image, width: 64, height: 40)
    }

    static func grayscale(_ image: CGImage, width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }

    /// Mean absolute difference between two fingerprints, 0...255.
    static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 255 }
        var total = 0
        for i in 0..<a.count { total += abs(Int(a[i]) - Int(b[i])) }
        return Double(total) / Double(a.count)
    }

    /// Average luminance (0...1) of a region of an image, to pick label colours that contrast with the page.
    static func luminance(of image: CGImage, normalizedRect r: CGRect) -> Double {
        let px = CGRect(x: r.minX * CGFloat(image.width), y: (1 - r.maxY) * CGFloat(image.height),
                        width: max(1, r.width * CGFloat(image.width)), height: max(1, r.height * CGFloat(image.height))).integral
        guard let crop = image.cropping(to: px) else { return 1 }
        let g = grayscale(crop, width: 8, height: 4)
        return Double(g.reduce(0) { $0 + Int($1) }) / Double(g.count) / 255
    }
}
