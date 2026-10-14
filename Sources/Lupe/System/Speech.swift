import AVFoundation
import Foundation

/// Speaks target-language text with the best installed voice (premium > enhanced > default).
@MainActor
final class Speech {
    static let shared = Speech()
    private let synth = AVSpeechSynthesizer()
    private var voiceCache: [String: AVSpeechSynthesisVoice] = [:]

    func voice(for language: String) -> AVSpeechSynthesisVoice? {
        if let v = voiceCache[language] { return v }
        let prefix = language.split(separator: "-").first.map(String.init) ?? language
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(prefix) }
        func score(_ v: AVSpeechSynthesisVoice) -> Int {
            var s = 0
            switch v.quality {
            case .premium: s += 30
            case .enhanced: s += 20
            default: s += 0
            }
            if v.language == language { s += 5 }
            // Novelty voices are fun but not for learning pronunciation.
            if v.voiceTraits.contains(.isNoveltyVoice) { s -= 100 }
            return s
        }
        let best = candidates.max { score($0) < score($1) } ?? AVSpeechSynthesisVoice(language: language)
        voiceCache[language] = best
        return best
    }

    func speak(_ text: String, language: String, slow: Bool = false) {
        guard !text.isEmpty else { return }
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        let u = AVSpeechUtterance(string: text)
        u.voice = voice(for: language)
        u.rate = slow ? 0.36 : 0.47
        u.preUtteranceDelay = 0
        synth.speak(u)
    }

    func stop() { synth.stopSpeaking(at: .immediate) }

    /// "Anna (enhanced)" for the settings screen.
    func voiceDescription(for language: String) -> String {
        guard let v = voice(for: language) else { return "No voice installed" }
        let q: String
        switch v.quality {
        case .premium: q = "premium"
        case .enhanced: q = "enhanced"
        default: q = "default quality"
        }
        return "\(v.name) (\(q))"
    }
}
