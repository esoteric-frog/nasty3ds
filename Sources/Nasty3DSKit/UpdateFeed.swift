import CryptoKit
import Foundation

/// A new version on GitHub that this Mac may install.
public struct UpdateOffer: Equatable, Sendable {
    public let version: String      // "0.6", no leading v
    public let zip: URL             // asset named exactly "Nasty3DS.zip"
    public let signature: URL       // asset named exactly "Nasty3DS.zip.sig"
}

/// The rules of an update: which version is newer, which release counts, and which file is real.
public enum UpdateFeed {
    /// By repo number, not by name: a new account or repo name does not break the update.
    public static let latest = URL(string: "https://api.github.com/repositories/1459367212/releases/latest")!
    /// Ed25519 public key (base64, 32 bytes). Only the owner's Mac has the private key.
    public static let publicKey = "v+G0D+8vtQmVKwXj7F4eTRMGzN/+S4mJWSsKga05dt0="
    public static let maxZipBytes = 300 * 1024 * 1024

    /// Numbers split by dots; a leading "v" is dropped; "0.10" is newer than "0.9"; "0.5" equals "0.5.0".
    /// Anything that is not digits and dots is never newer.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let a = numbers(candidate), let b = numbers(current) else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// "v0.10.1" = [0, 10, 1]. Nil for anything else (empty parts, letters, spaces, huge numbers).
    private static func numbers(_ version: String) -> [Int]? {
        let text = version.hasPrefix("v") ? version.dropFirst() : Substring(version)
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !text.isEmpty, parts.allSatisfy({ (1...9).contains($0.count) && $0.allSatisfy { ("0"..."9").contains($0) } })
        else { return nil }
        return parts.map { Int($0)! }
    }

    private struct Release: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: String }
        let tag_name: String
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]
    }

    /// True when the body is a release at all: a JSON object with a string `tag_name`. A sign-in
    /// page of a hotel Wi-Fi is not, and must not read as "up to date".
    public static func isFeed(json: Data) -> Bool {
        ((try? JSONSerialization.jsonObject(with: json)) as? [String: Any])?["tag_name"] is String
    }

    /// GitHub "latest release" JSON. Nil when: bad JSON, `draft` or `prerelease` true, the tag is
    /// not newer than `current`, an asset is missing, or an asset URL is not `allowed`.
    public static func offer(json: Data, current: String) -> UpdateOffer? {
        guard let release = try? JSONDecoder().decode(Release.self, from: json),
              release.draft != true, release.prerelease != true,
              isNewer(release.tag_name, than: current) else { return nil }
        func asset(_ name: String) -> URL? {
            release.assets.first { $0.name == name }.flatMap { URL(string: $0.browser_download_url) }.flatMap { allowed($0) ? $0 : nil }
        }
        guard let zip = asset("Nasty3DS.zip"), let signature = asset("Nasty3DS.zip.sig") else { return nil }
        let tag = release.tag_name
        return UpdateOffer(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, zip: zip, signature: signature)
    }

    /// https with a host, or http on 127.0.0.1 (for the local check). Nothing else.
    public static func allowed(_ url: URL) -> Bool {
        guard let host = url.host, !host.isEmpty else { return false }
        return url.scheme == "https" || (url.scheme == "http" && host == "127.0.0.1")
    }

    /// True only when `signature` (64 raw bytes, or their base64 text with optional newline)
    /// is a valid Ed25519 signature of `file` for `publicKey`.
    public static func isSigned(_ file: Data, signature: Data, publicKey: String = publicKey) -> Bool {
        guard let keyBytes = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes) else { return false }
        var raw = signature
        if raw.count != 64 {
            guard let text = String(data: signature, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let decoded = Data(base64Encoded: text) else { return false }
            raw = decoded
        }
        return raw.count == 64 && key.isValidSignature(raw, for: file)
    }
}
