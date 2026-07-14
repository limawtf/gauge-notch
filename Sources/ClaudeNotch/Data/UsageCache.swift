import Foundation

/// Cache em disco atomica sob ~/Library/Caches/claude-notch (porta de `_cache_write`/`get_usage`).
final class UsageCache {
    static let usageTTL: TimeInterval = 300
    static let profileTTL: TimeInterval = 6 * 3600

    private let directory: URL
    let usageURL: URL
    let profileURL: URL

    /// Fast-path opcional: cache que o plugin SwiftBar ja mantem, se estiver fresco.
    let pluginUsageURL = URL(
        fileURLWithPath: NSHomeDirectory() + "/Library/Caches/claude-usage-menubar/usage.json"
    )

    /// directory injetavel pra teste; em producao usa sempre ~/Library/Caches/claude-notch.
    init(directory: URL? = nil) {
        self.directory = directory ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches/claude-notch")
        try? FileManager.default.createDirectory(
            at: self.directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        usageURL = self.directory.appendingPathComponent("usage.json")
        profileURL = self.directory.appendingPathComponent("profile.json")
    }

    func age(of url: URL) -> TimeInterval? {
        guard
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
            let modDate = attrs[.modificationDate] as? Date
        else { return nil }
        return Date().timeIntervalSince(modDate)
    }

    func read(_ url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    /// Escrita atomica (tmp + replace), silenciosa em erro (nunca derruba o refresh).
    func write(_ url: URL, data: Data) {
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    /// Dado em cache dentro do TTL, ou nil (fresco ou nao existe/expirado).
    func readFresh(_ url: URL, ttl: TimeInterval) -> Data? {
        guard let age = age(of: url), age < ttl else { return nil }
        return read(url)
    }

    /// Apaga um cache (usado pelo refresh manual, ex. "rm -f USAGE_CACHE" do plugin).
    /// Silencioso se o arquivo nao existe.
    func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
