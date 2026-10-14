import Foundation
import Security

/// Optional tutor backed by the Claude Messages API (raw HTTP; there is no official Swift SDK).
/// Only the sentence being explained is sent, and only when you press Explain/Check.
public final class ClaudeTutor: Tutor, @unchecked Sendable {
    public let name = "Claude (Anthropic API)"
    public let isOnDevice = false

    public static let model = "claude-opus-5-5"
    private let apiKey: String
    private let session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    public func explain(sentence: String, translation: String?, focus: String?, explainIn language: String) async throws -> String {
        try await send(TutorPrompts.explain(sentence: sentence, translation: translation, focus: focus, language: language),
                       system: TutorPrompts.instructions)
    }

    public func proofread(german: String) async throws -> String {
        let raw = try await send(TutorPrompts.proofread(german), system: TutorPrompts.proofreadInstructions)
        return raw.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"„“”«»")) } ?? raw
    }

    public func explainCorrection(original: String, corrected: String, explainIn language: String) async throws -> String {
        try await send(TutorPrompts.explainCorrection(original: original, corrected: corrected, language: language),
                       system: TutorPrompts.instructions)
    }

    // MARK: HTTP

    struct Request: Encodable {
        struct Message: Encodable { var role: String; var content: String }
        struct OutputConfig: Encodable { var effort: String }
        var model: String
        var max_tokens: Int
        var system: String
        var messages: [Message]
        var output_config: OutputConfig
        /// Server-side fallback: if a safety classifier declines, the API retries on a recommended model.
        var fallbacks: String
    }

    struct Response: Decodable {
        struct Block: Decodable { var type: String; var text: String? }
        var content: [Block]
        var stop_reason: String?
    }

    struct APIErrorBody: Decodable {
        struct Detail: Decodable { var type: String; var message: String }
        var error: Detail
    }

    private func send(_ prompt: String, system: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONEncoder().encode(Request(
            model: Self.model, max_tokens: 16000, system: system,
            messages: [.init(role: "user", content: prompt)],
            output_config: .init(effort: "medium"), fallbacks: "default"))

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = (try? JSONDecoder().decode(APIErrorBody.self, from: data))?.error.message ?? "HTTP \(status)"
            switch status {
            case 401: throw TutorError.unavailable("Claude rejected the API key. Check it in Settings → AI explanations.")
            case 429: throw TutorError.failed("Claude is rate-limited right now. Try again in a moment.")
            default: throw TutorError.failed("Claude error: \(message)")
            }
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        // Check the stop reason before reading content: a declined request has no usable answer.
        if decoded.stop_reason == "refusal" {
            throw TutorError.failed("Claude declined to answer this one.")
        }
        let text = decoded.content.filter { $0.type == "text" }.compactMap(\.text).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TutorError.failed("Claude returned an empty answer.") }
        return text
    }
}

/// Minimal Keychain wrapper for the API key (generic password item).
public enum KeychainStore {
    static let service = "Lupe"

    public static func read(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func save(_ value: String, account: String) -> Bool {
        delete(account)
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account, kSecValueData as String: Data(value.utf8),
                                   kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    public static func delete(_ account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}
