import Foundation

/// What the Mac remembers about the phone: the secret, the two ports, and the games that use it.
public struct Pairing: Codable, Equatable, Sendable {
    public var secret: String
    public var pagePort: UInt16 = 0      // 0 = let the system pick a free port
    public var livePort: UInt16 = 0
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

    public func url(host: String) -> String { "https://\(host):\(pagePort)/?k=\(secret)" }

    public func usesPhone(game: String) -> Bool { phoneGames.contains(game) }

    public mutating func setUsesPhone(_ on: Bool, game: String) {
        if on { phoneGames.insert(game) } else { phoneGames.remove(game) }
    }

    /// A new secret: every saved page and old QR code stops working.
    public mutating func forget() {
        secret = Self.newSecret()
        phoneGames = []
    }

    private static let key = "phonePairing"

    public static func load(from defaults: UserDefaults = .standard) -> Pairing {
        if let data = defaults.data(forKey: key), let stored = try? JSONDecoder().decode(Pairing.self, from: data) {
            return stored
        }
        let fresh = Pairing()
        fresh.save(to: defaults)
        return fresh
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

/// The page listener answers exactly one request: `GET /?k=<secret> HTTP/1.x`.
public enum PageRequest {
    public static let maxLength = 8192

    public static func isAuthorized(_ raw: Data, pairing: Pairing) -> Bool {
        guard raw.count <= maxLength, let text = String(data: raw, encoding: .utf8),
              let line = text.components(separatedBy: "\r\n").first
        else { return false }
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "GET", parts[2].hasPrefix("HTTP/1."),
              parts[1].hasPrefix("/?k=")
        else { return false }
        return pairing.matches(String(parts[1].dropFirst(4)))
    }
}
