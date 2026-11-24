import Foundation

/// What the Mac remembers about the phone: the secret, the two ports, and the games that use it.
public struct Pairing: Codable, Equatable, Sendable {
    public var secret: String
    public var pagePort: UInt16 = 0      // 0 = let the system pick a free port
    public var livePort: UInt16 = 0
    /// A second live port, picked one time. The page knows it, so a saved icon still connects
    /// when another program holds `livePort`. Optional: older pairing data has none.
    public var backupLivePort: UInt16?
    // ponytail: the key is the game file path, so a moved file loses its mark.
    // Change to the game's title ID when Part 3 adds the library.
    public var phoneGames: Set<String> = []

    public init() { secret = Self.newSecret() }

    /// 32 bytes from the system random source, as base64url with no padding (43 characters).
    public static func newSecret() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Constant-time compare: the time does not show how many leading characters are correct.
    public func matches(_ candidate: String) -> Bool {
        let a = Array(secret.utf8), b = Array(candidate.utf8)
        var difference = UInt8(a.count == b.count ? 0 : 1)
        for i in 0..<a.count { difference |= a[i] ^ (i < b.count ? b[i] : 0) }
        return difference == 0
    }

    /// The page address. The port is the one the server listens on now (it can differ for one session).
    public func url(host: String, port: UInt16) -> String { "https://\(host):\(port)/?k=\(secret)" }

    public func usesPhone(game: String) -> Bool { phoneGames.contains(game) }

    public mutating func setUsesPhone(_ on: Bool, game: String) {
        if on { phoneGames.insert(game) } else { phoneGames.remove(game) }
    }

    /// A new secret: every saved page and old QR code stops working.
    public mutating func forget() {
        secret = Self.newSecret()
        phoneGames = []
    }

    /// The old place of the pairing: UserDefaults, under this key.
    private static let key = "phonePairing"

    /// Reads the pairing from `file`. Only when there is no file, it takes the first pairing found
    /// in `legacy` (the old UserDefaults place), else a fresh one, and writes the file. The old
    /// value stays: an older app version can still read it.
    /// A file that cannot be read is moved aside to `phone-pairing.broken-<time>.json`, and a fresh
    /// pairing replaces it (never an old one: that could be a forgotten secret). If it cannot be
    /// moved, it stays as it is and nothing is written now.
    public static func load(file: URL, legacy: [UserDefaults] = [], now: Date = Date()) -> Pairing {
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path) else {
            let old = legacy.lazy.compactMap { $0.data(forKey: key) }.compactMap { try? JSONDecoder().decode(Pairing.self, from: $0) }.first
            let pairing = old ?? Pairing()
            pairing.save(file: file)
            return pairing
        }
        if let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode(Pairing.self, from: data) { return stored }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyyMMdd-HHmmss"
        let aside = file.deletingLastPathComponent().appendingPathComponent("phone-pairing.broken-\(format.string(from: now)).json")
        let fresh = Pairing()
        if (try? fm.moveItem(at: file, to: aside)) != nil { fresh.save(file: file) }
        return fresh
    }

    /// Removes the pairing from the old places, so a forgotten secret cannot come back from there.
    public static func forgetLegacy(_ stores: [UserDefaults]) {
        for store in stores { store.removeObject(forKey: key) }
    }

    /// The file is never readable by others, not even for a moment: a temp file made with mode 0600
    /// in the same folder, then renamed over the target. A new folder gets mode 0700.
    public func save(file: URL) {
        let folder = file.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        guard let data = try? JSONEncoder().encode(self) else { return }
        let temp = folder.appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString)")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
        close(fd)
        if written != data.count || rename(temp.path, file.path) != 0 { unlink(temp.path) }
    }

    /// Which old UserDefaults stores `load(file:legacy:)` reads, best first. A suite name, or nil
    /// for `UserDefaults.standard`. Only the real folder reads them: a scratch profile (also one
    /// that falls back to the real folder) must not copy the real secret, and must not be copied.
    public static func legacyStores(supportDir: URL, defaultDir: URL, bundleID: String?) -> [String?] {
        guard supportDir.standardizedFileURL.path == defaultDir.standardizedFileURL.path else { return [] }
        return bundleID == "app.nasty3ds" ? [nil] : ["app.nasty3ds", nil]
    }

}

/// The page listener answers exactly one request: the page `GET /?k=<secret> HTTP/1.x`, or the
/// worker that keeps a copy of it on the phone, `GET /sw.js?k=<secret> HTTP/1.x`.
public enum PageRequest {
    public enum Kind: Equatable { case page, worker, denied }
    public static let maxLength = 8192

    /// `GET /?k=<secret>` = page. `GET /sw.js?k=<secret>` = worker. All else = denied.
    public static func kind(_ raw: Data, pairing: Pairing) -> Kind {
        guard raw.count <= maxLength, let text = String(data: raw, encoding: .utf8),
              let line = text.components(separatedBy: "\r\n").first
        else { return .denied }
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "GET", parts[2].hasPrefix("HTTP/1.") else { return .denied }
        for (path, kind) in [("/?k=", Kind.page), ("/sw.js?k=", .worker)] where parts[1].hasPrefix(path) {
            return pairing.matches(String(parts[1].dropFirst(path.count))) ? kind : .denied
        }
        return .denied
    }
}
