import CryptoKit
import Foundation
import Testing
@testable import Nasty3DSKit

@Test func newerVersionsAreFoundByNumberNotByText() {
    let cases: [(String, String, Bool)] = [
        ("0.5", "0.4", true), ("v0.5", "0.4", true), ("0.10", "0.9", true), ("0.5", "0.5", false),
        ("0.5.0", "0.5", false), ("0.4", "0.5", false), ("1.0-beta", "0.5", false), ("", "0.5", false),
        ("0.5.1", "0.5", true), ("99.0", "0", true), ("0.5", "", false), ("0..5", "0.4", false), ("v", "0.4", false),
        (" 0.6", "0.5", false), ("0.6\n", "0.5", false), ("99999999999999999999.0", "0.5", false),
    ]
    for (candidate, current, newer) in cases {
        #expect(UpdateFeed.isNewer(candidate, than: current) == newer, "\(candidate) vs \(current)")
    }
}

private func release(tag: String = "v0.6", draft: Bool = false, prerelease: Bool = false,
                     zip: String? = "https://github.com/example/nasty3ds/releases/download/v0.6/Nasty3DS.zip",
                     sig: String? = "https://github.com/example/nasty3ds/releases/download/v0.6/Nasty3DS.zip.sig") -> Data {
    var assets: [[String: Any]] = [["name": "README.txt", "browser_download_url": "https://example.com/readme"]]
    if let zip { assets.append(["name": "Nasty3DS.zip", "browser_download_url": zip, "size": 1000]) }
    if let sig { assets.append(["name": "Nasty3DS.zip.sig", "browser_download_url": sig, "size": 89]) }
    let json: [String: Any] = ["tag_name": tag, "name": "Nasty3DS \(tag)", "draft": draft, "prerelease": prerelease,
                               "html_url": "https://github.com/example/nasty3ds/releases/tag/\(tag)", "assets": assets]
    return try! JSONSerialization.data(withJSONObject: json)
}

@Test func aNewerReleaseIsOffered() throws {
    let offer = try #require(UpdateFeed.offer(json: release(), current: "0.5"))
    #expect(offer.version == "0.6")
    #expect(offer.zip.absoluteString.hasSuffix("/Nasty3DS.zip"))
    #expect(offer.signature.absoluteString.hasSuffix("/Nasty3DS.zip.sig"))
    let local = UpdateFeed.offer(json: release(tag: "99.0", zip: "http://127.0.0.1:8000/Nasty3DS.zip", sig: "http://127.0.0.1:8000/Nasty3DS.zip.sig"), current: "0.5")
    #expect(local?.version == "99.0")       // the local check serves the files on 127.0.0.1
}

@Test func noOfferForAnythingElse() {
    let bad: [(String, Data)] = [
        ("bad JSON", Data("{".utf8)),
        ("not an object", Data("[]".utf8)),
        ("draft", release(draft: true)),
        ("prerelease", release(prerelease: true)),
        ("same version", release(tag: "v0.5")),
        ("older version", release(tag: "v0.4")),
        ("tag that is not a number", release(tag: "latest")),
        ("no zip", release(zip: nil)),
        ("no signature", release(sig: nil)),
        ("plain http zip", release(zip: "http://example.com/Nasty3DS.zip")),
        ("plain http signature", release(sig: "http://example.com/Nasty3DS.zip.sig")),
        ("file url", release(zip: "file:///tmp/Nasty3DS.zip")),
        ("http on another local name", release(zip: "http://localhost:8000/Nasty3DS.zip")),
    ]
    for (name, json) in bad { #expect(UpdateFeed.offer(json: json, current: "0.5") == nil, "\(name)") }
}

@Test func onlyHTTPSOrTheLocalCheckIsAllowed() {
    #expect(UpdateFeed.allowed(URL(string: "https://api.github.com/x")!))
    #expect(UpdateFeed.allowed(URL(string: "http://127.0.0.1:8000/x")!))
    #expect(UpdateFeed.allowed(UpdateFeed.latest))
    for bad in ["http://example.com/x", "http://localhost/x", "ftp://example.com/x", "file:///tmp/x", "https:///x", "data:,x"] {
        #expect(!UpdateFeed.allowed(URL(string: bad)!), "\(bad)")
    }
}

@Test func onlyASignatureFromTheKeyCounts() throws {
    let key = Curve25519.Signing.PrivateKey()
    let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    let file = Data((0..<10_000).map { UInt8($0 % 251) })
    let raw = try key.signature(for: file)
    #expect(raw.count == 64)
    #expect(UpdateFeed.isSigned(file, signature: raw, publicKey: publicKey))
    #expect(UpdateFeed.isSigned(file, signature: Data((raw.base64EncodedString() + "\n").utf8), publicKey: publicKey))
    var changed = file; changed[5000] ^= 1
    #expect(!UpdateFeed.isSigned(changed, signature: raw, publicKey: publicKey))
    #expect(!UpdateFeed.isSigned(file.prefix(9000), signature: raw, publicKey: publicKey))          // cut short
    let other = try Curve25519.Signing.PrivateKey().signature(for: file)
    #expect(!UpdateFeed.isSigned(file, signature: other, publicKey: publicKey))
    #expect(!UpdateFeed.isSigned(file, signature: Data(), publicKey: publicKey))
    #expect(!UpdateFeed.isSigned(file, signature: Data("garbage".utf8), publicKey: publicKey))
    #expect(!UpdateFeed.isSigned(file, signature: Data(repeating: 0, count: 64), publicKey: publicKey))
    #expect(!UpdateFeed.isSigned(file, signature: raw, publicKey: "not a key"))
    #expect(!UpdateFeed.isSigned(file, signature: raw, publicKey: Data(repeating: 1, count: 31).base64EncodedString()))
    // The real constant: a file signed with a test key never passes it.
    #expect(!UpdateFeed.isSigned(file, signature: raw))
}

@Test func theRealPublicKeyIs32Bytes() {
    #expect(Data(base64Encoded: UpdateFeed.publicKey)?.count == 32)
    #expect((try? Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: UpdateFeed.publicKey) ?? Data())) != nil)
}

@Test func aSignInPageIsNotAFeed() {
    #expect(UpdateFeed.isFeed(json: release()))
    #expect(UpdateFeed.isFeed(json: release(tag: "v0.4")))           // an older release is a feed, just no offer
    for bad in ["<html><body>Sign in to the Wi-Fi</body></html>", "", "{}", "[]", #"{"tag_name": 5}"#, #"{"message": "Not Found"}"#] {
        #expect(!UpdateFeed.isFeed(json: Data(bad.utf8)), "\(bad)")
    }
}
