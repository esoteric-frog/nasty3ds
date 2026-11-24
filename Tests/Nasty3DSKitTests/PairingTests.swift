import Foundation
import Testing
@testable import Nasty3DSKit

@Test func aNewSecretIs32RandomBytesInURLSafeText() {
    let a = Pairing.newSecret(), b = Pairing.newSecret()
    #expect(a != b)
    #expect(a.count == 43)   // 32 bytes in base64 with no padding
    #expect(a.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
}

@Test func matchesOnlyTheExactSecret() {
    let p = Pairing()
    #expect(p.matches(p.secret))
    #expect(!p.matches(""))
    #expect(!p.matches(String(p.secret.dropLast())))
    #expect(!p.matches(p.secret + "a"))
    #expect(!p.matches(String(p.secret.dropLast()) + (p.secret.last == "a" ? "b" : "a")))
}

@Test func buildsThePageAddress() {
    var p = Pairing(); p.secret = "S3cret"; p.pagePort = 8123
    #expect(p.url(host: "mac.local", port: 4000) == "https://mac.local:4000/?k=S3cret")
}

@Test func remembersWhichGamesUseThePhone() {
    var p = Pairing()
    #expect(!p.usesPhone(game: "/a.cci"))
    p.setUsesPhone(true, game: "/a.cci")
    #expect(p.usesPhone(game: "/a.cci") && !p.usesPhone(game: "/b.cci"))
    p.setUsesPhone(false, game: "/a.cci")
    #expect(!p.usesPhone(game: "/a.cci"))
}

@Test func forgetMakesANewSecretAndClearsTheGames() {
    var p = Pairing(); p.pagePort = 8123; p.setUsesPhone(true, game: "/a.cci")
    let old = p.secret
    p.forget()
    #expect(p.secret != old && !p.matches(old))
    #expect(p.phoneGames.isEmpty)
    #expect(p.pagePort == 8123)   // ports stay, so the listener need not move
}

/// A pairing file in a new temp folder, and a defaults store that no other test sees.
private func scratchFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("nasty3ds-pairing-\(UUID().uuidString)/phone-pairing.json")
}
private func scratchDefaults(with pairing: Pairing? = nil) -> UserDefaults {
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    if let pairing { defaults.set(try! JSONEncoder().encode(pairing), forKey: "phonePairing") }
    return defaults
}

@Test func aFirstLoadMakesAPairingFileOnlyTheOwnerCanRead() throws {
    let file = scratchFile()
    let first = Pairing.load(file: file)
    #expect(first.secret.count == 43)
    let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
    #expect(Pairing.load(file: file).secret == first.secret)
}

@Test func withNoFileTheFirstOldPairingMovesIntoTheFile() throws {
    var a = Pairing(); a.pagePort = 4001; a.livePort = 4002; a.setUsesPhone(true, game: "/a.cci")
    var b = Pairing(); b.pagePort = 5001; b.livePort = 5002
    let file = scratchFile()
    let oldA = scratchDefaults(with: a)
    #expect(Pairing.load(file: file, legacy: [oldA, scratchDefaults(with: b)]) == a)
    let stored = try JSONDecoder().decode(Pairing.self, from: Data(contentsOf: file))
    #expect(stored == a)
    #expect(oldA.data(forKey: "phonePairing") != nil)     // an older app version can still read it
}

@Test func theFileWinsOverAnOldPairing() {
    let file = scratchFile()
    var mine = Pairing(); mine.pagePort = 4001
    mine.save(file: file)
    #expect(Pairing.load(file: file, legacy: [scratchDefaults(with: Pairing())]) == mine)
}

@Test func aBrokenFileGivesAFreshPairing() throws {
    let file = scratchFile()
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{not json".utf8).write(to: file)
    #expect(Pairing.load(file: file).secret.count == 43)
}

@Test func storesAndLoads() {
    let file = scratchFile()
    var p = Pairing(); p.pagePort = 1; p.livePort = 2; p.setUsesPhone(true, game: "/a.cci")
    p.save(file: file)
    #expect(Pairing.load(file: file) == p)
}

private func request(_ line: String) -> Data { Data((line + "\r\nHost: x\r\n\r\n").utf8) }

@Test func onlyTheExactPageAndWorkerRequestsAreServed() {
    var p = Pairing(); p.secret = "S3cret"
    #expect(PageRequest.kind(request("GET /?k=S3cret HTTP/1.1"), pairing: p) == .page)
    #expect(PageRequest.kind(request("GET /sw.js?k=S3cret HTTP/1.1"), pairing: p) == .worker)
    let bad = [
        "GET / HTTP/1.1", "GET /?k= HTTP/1.1", "GET /?k=wrong HTTP/1.1", "GET /?k=S3cretX HTTP/1.1",
        "GET /other?k=S3cret HTTP/1.1", "GET /../etc/passwd?k=S3cret HTTP/1.1", "POST /?k=S3cret HTTP/1.1",
        "GET /?k=S3cret", "GET /?x=1&k=S3cret HTTP/1.1", "",
        "GET /sw.js HTTP/1.1", "GET /sw.js?k=wrong HTTP/1.1", "GET /sw.js?k= HTTP/1.1", "POST /sw.js?k=S3cret HTTP/1.1",
        "GET /sw.jsx?k=S3cret HTTP/1.1", "GET /a/sw.js?k=S3cret HTTP/1.1", "GET /sw.js?k=S3cret",
    ]
    for line in bad { #expect(PageRequest.kind(request(line), pairing: p) == .denied, "\(line)") }
    #expect(PageRequest.kind(Data([0xff, 0xfe, 0x00]), pairing: p) == .denied)
    #expect(PageRequest.kind(Data(repeating: 0x41, count: 9000), pairing: p) == .denied)
    #expect(PageRequest.kind(Data(("GET /sw.js?k=S3cret HTTP/1.1\r\n" + String(repeating: "x", count: 9000)).utf8), pairing: p) == .denied)
}

@Test func onlyTheRealFolderReadsTheOldPairings() {
    let real = URL(fileURLWithPath: "/private/tmp/n3-home/Library/Application Support/Nasty3DS")
    // The app bundle: its own defaults are app.nasty3ds (nil = UserDefaults.standard).
    #expect(Pairing.legacyStores(supportDir: real, defaultDir: real, bundleID: "app.nasty3ds") == [nil])
    // A bare build: the app's pairing first, then the bare build's own.
    #expect(Pairing.legacyStores(supportDir: real, defaultDir: real, bundleID: nil) == ["app.nasty3ds", nil])
    #expect(Pairing.legacyStores(supportDir: URL(fileURLWithPath: real.path + "/"), defaultDir: real, bundleID: nil) == ["app.nasty3ds", nil])
    // A scratch profile reads none, so it never copies the real secret.
    #expect(Pairing.legacyStores(supportDir: URL(fileURLWithPath: "/tmp/scratch"), defaultDir: real, bundleID: "app.nasty3ds").isEmpty)
    #expect(Pairing.legacyStores(supportDir: URL(fileURLWithPath: "/tmp/scratch"), defaultDir: real, bundleID: nil).isEmpty)
}

@Test func oldPairingDataWithNoBackupPortStillLoads() throws {
    let old = #"{"secret":"S3cret","pagePort":4001,"livePort":4002,"phoneGames":["/a.cci"]}"#
    let p = try JSONDecoder().decode(Pairing.self, from: Data(old.utf8))
    #expect(p.secret == "S3cret" && p.livePort == 4002 && p.backupLivePort == nil)
    var q = p; q.backupLivePort = 31000
    q.forget()
    #expect(q.backupLivePort == 31000 && q.livePort == 4002)     // forget changes only the secret and the games
}

@Test func aFileThatCannotBeReadIsMovedAsideAndTheOldPairingIsNotTaken() throws {
    let file = scratchFile()
    let folder = file.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("{not json".utf8).write(to: file)
    let old = Pairing()
    let loaded = Pairing.load(file: file, legacy: [scratchDefaults(with: old)])
    #expect(loaded.secret != old.secret)                       // a broken file must not bring back an old secret
    let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    let broken = try #require(names.first { $0.hasPrefix("phone-pairing.broken-") && $0.hasSuffix(".json") })
    #expect(try Data(contentsOf: folder.appendingPathComponent(broken)) == Data("{not json".utf8))
    #expect(Pairing.load(file: file).secret == loaded.secret)  // the fresh pairing is in the file now
}

@Test func aBrokenFileThatCannotBeMovedIsLeftAlone() throws {
    let file = scratchFile()
    let folder = file.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("{not json".utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)     // no move, no write
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
    #expect(Pairing.load(file: file).secret.count == 43)
    #expect(try Data(contentsOf: file) == Data("{not json".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["phone-pairing.json"])
}

@Test func aForgottenSecretNeverComesBackFromTheOldPlace() throws {
    let file = scratchFile()
    let old = Pairing()
    let store = scratchDefaults(with: old)
    var p = Pairing.load(file: file, legacy: [store])
    #expect(p.secret == old.secret)                             // moved over from the old place
    p.forget()
    p.save(file: file)
    Pairing.forgetLegacy([store])
    try FileManager.default.removeItem(at: file)
    #expect(Pairing.load(file: file, legacy: [store]).secret != old.secret)
}

@Test func theFileAndANewFolderAreForTheOwnerOnly() throws {
    let file = scratchFile()
    Pairing().save(file: file)
    let fm = FileManager.default
    #expect(try fm.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? Int == 0o700)
    #expect(try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
    var p = Pairing(); p.pagePort = 4001
    p.save(file: file)                                          // a second save replaces the file
    #expect(Pairing.load(file: file) == p)
    #expect(try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
    #expect(try fm.contentsOfDirectory(atPath: file.deletingLastPathComponent().path) == ["phone-pairing.json"])   // no temp file left
}
