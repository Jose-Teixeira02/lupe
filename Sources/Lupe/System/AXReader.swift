import AppKit
import ApplicationServices
import LupeCore

/// Reads exact text from apps that expose it (most native apps, Safari, Mail, Notes...).
/// Requires the Accessibility permission. Every call is bounded by a short messaging timeout.
enum AXReader {
    private static let systemWide: AXUIElement = {
        let e = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(e, 0.25)
        return e
    }()

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Primary screen height, for flipping between Cocoa (bottom-left) and AX (top-left) coordinates.
    private static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    static func toAX(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: primaryHeight - p.y) }

    static func fromAX(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// The word under a point (global Cocoa coordinates), or nil if the app doesn't expose text there.
    static func word(at point: CGPoint) -> TextHit? {
        guard isTrusted else { return nil }
        let ax = toAX(point)
        var elementRef: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(ax.x), Float(ax.y), &elementRef) == .success,
              let element = elementRef else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.25)

        // Character index under the point.
        var pointValue = ax
        guard let axPoint = AXValueCreate(.cgPoint, &pointValue) else { return nil }
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXRangeForPositionParameterizedAttribute as CFString, axPoint, &rangeRef) == .success,
              let rangeValue = rangeRef, CFGetTypeID(rangeValue) == AXValueGetTypeID() else {
            return staticTextHit(element, at: point)
        }
        var charRange = CFRange()
        AXValueGetValue(rangeValue as! AXValue, .cfRange, &charRange)
        guard charRange.location >= 0 else { return nil }

        // Read a window of text around it (avoids pulling huge documents).
        let total = intAttribute(element, kAXNumberOfCharactersAttribute) ?? Int.max
        let start = max(0, charRange.location - 300)
        let length = min(600, max(0, total - start))
        guard length > 0, let window = string(element, range: CFRange(location: start, length: length)) else { return nil }
        let ns = window as NSString
        let offset16 = charRange.location - start
        guard offset16 >= 0, offset16 < ns.length else { return nil }

        // Map UTF-16 offset to a String index, then find the word and sentence.
        guard let idx = Range(NSRange(location: offset16, length: 1), in: window)?.lowerBound,
              let wordRange = TextTools.wordRanges(in: window).first(where: { $0.contains(idx) }) else { return nil }
        let word = String(window[wordRange])
        guard TextTools.isMostlyLetters(word) else { return nil }
        let sentence = TextTools.sentence(in: window, containing: wordRange)
        guard let rangeInSentence = locate(wordRange: wordRange, in: window, sentence: sentence) else { return nil }

        // Word bounds on screen.
        var rect: CGRect?
        let ns16 = NSRange(wordRange, in: window)
        var wordCF = CFRange(location: start + ns16.location, length: ns16.length)
        if let rv = AXValueCreate(.cfRange, &wordCF) {
            var boundsRef: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, rv, &boundsRef) == .success,
               let b = boundsRef, CFGetTypeID(b) == AXValueGetTypeID() {
                var r = CGRect.zero
                AXValueGetValue(b as! AXValue, .cgRect, &r)
                if r.width > 0 && r.height > 0 { rect = fromAX(r) }
            }
        }
        // Reject hits where the reported bounds are far from the mouse (some apps return garbage).
        if let r = rect, r.insetBy(dx: -12, dy: -12).contains(point) == false { return nil }
        return TextHit(word: word, context: sentence, range: rangeInSentence, rect: rect, source: .accessibility)
    }

    /// Labels and buttons (AXStaticText without text ranges): use the whole value when it's short.
    private static func staticTextHit(_ element: AXUIElement, at point: CGPoint) -> TextHit? {
        guard let value = stringAttribute(element, kAXValueAttribute) ?? stringAttribute(element, kAXTitleAttribute),
              !value.isEmpty, value.count <= 60 else { return nil }
        let ranges = TextTools.wordRanges(in: value)
        guard ranges.count == 1, let r = ranges.first else { return nil }
        var rect: CGRect?
        if let frame = frameAttribute(element) { rect = fromAX(frame) }
        return TextHit(word: String(value[r]), context: value, range: r, rect: rect, source: .accessibility)
    }

    /// Selected text in the focused app.
    static func selectedText() -> String? {
        guard isTrusted else { return nil }
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID() else { return nil }
        let element = f as! AXUIElement
        let text = stringAttribute(element, kAXSelectedTextAttribute)
        return text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? text : nil
    }

    // MARK: Helpers

    private static func locate(wordRange: Range<String.Index>, in window: String, sentence: String) -> Range<String.Index>? {
        let word = String(window[wordRange])
        // Find the occurrence of the word in the sentence closest to its position in the window.
        guard let sentenceStart = window.range(of: sentence)?.lowerBound else { return sentence.range(of: word) }
        let target = window.distance(from: sentenceStart, to: wordRange.lowerBound)
        guard target >= 0, target <= sentence.count else { return sentence.range(of: word) }
        let lo = sentence.index(sentence.startIndex, offsetBy: target)
        guard let hi = sentence.index(lo, offsetBy: word.count, limitedBy: sentence.endIndex) else { return sentence.range(of: word) }
        return sentence[lo..<hi] == word ? lo..<hi : sentence.range(of: word)
    }

    private static func string(_ e: AXUIElement, range: CFRange) -> String? {
        var r = range
        guard let rv = AXValueCreate(.cfRange, &r) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(e, kAXStringForRangeParameterizedAttribute as CFString, rv, &out) == .success else {
            // Some elements only expose their full value.
            guard let full = stringAttribute(e, kAXValueAttribute) else { return nil }
            let ns = full as NSString
            let safe = NSIntersectionRange(NSRange(location: range.location, length: range.length), NSRange(location: 0, length: ns.length))
            return safe.length > 0 ? ns.substring(with: safe) : nil
        }
        return out as? String
    }

    private static func stringAttribute(_ e: AXUIElement, _ attr: String) -> String? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &out) == .success else { return nil }
        return out as? String
    }

    private static func intAttribute(_ e: AXUIElement, _ attr: String) -> Int? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &out) == .success else { return nil }
        return (out as? NSNumber)?.intValue
    }

    private static func frameAttribute(_ e: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &size) == .success,
              let p = pos, let s = size else { return nil }
        var point = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &sz)
        return CGRect(origin: point, size: sz)
    }
}
