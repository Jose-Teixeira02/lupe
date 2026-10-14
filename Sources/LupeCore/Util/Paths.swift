import Foundation

/// Where Lupe keeps data and finds language packs.
public enum LupePaths {
    /// `~/Library/Application Support/Lupe` (created on demand). `LUPE_HOME` overrides it (tests, snapshots).
    public static var appSupport: URL {
        let dir: URL
        if let custom = ProcessInfo.processInfo.environment["LUPE_HOME"], !custom.isEmpty {
            dir = URL(fileURLWithPath: custom, isDirectory: true)
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            dir = base.appendingPathComponent("Lupe", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Data folder for one target language, e.g. `.../Lupe/de`.
    public static func dataDirectory(for language: String) -> URL {
        let dir = appSupport.appendingPathComponent(language, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Search order for packs: user packs (drop-in), the app bundle, then the source tree (dev builds).
    public static func packRoots() -> [URL] {
        var roots: [URL] = [appSupport.appendingPathComponent("packs", isDirectory: true)]
        if let res = Bundle.main.resourceURL {
            roots.append(res.appendingPathComponent("packs", isDirectory: true))
        }
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Util
            .deletingLastPathComponent() // LupeCore
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // project root
        roots.append(sourceRoot.appendingPathComponent("packs", isDirectory: true))
        return roots
    }

    public static func packDirectory(for code: String) -> URL? {
        for root in packRoots() {
            let dir = root.appendingPathComponent(code, isDirectory: true)
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("pack.json").path) {
                return dir
            }
        }
        return nil
    }

    /// Every pack that can be loaded, de-duplicated by language code (first root wins).
    public static func availablePacks() -> [PackInfo] {
        var seen = Set<String>()
        var out: [PackInfo] = []
        for root in packRoots() {
            guard let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let url = dir.appendingPathComponent("pack.json")
                guard let data = try? Data(contentsOf: url),
                      let info = try? JSONDecoder().decode(PackInfo.self, from: data),
                      !seen.contains(info.code) else { continue }
                seen.insert(info.code)
                out.append(info)
            }
        }
        return out
    }

    public static func loadLexicon(_ code: String) throws -> Lexicon {
        guard let dir = packDirectory(for: code) else { throw LexiconError.packNotFound(code) }
        return try Lexicon.load(from: dir)
    }
}
