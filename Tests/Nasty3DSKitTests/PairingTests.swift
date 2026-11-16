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
    #expect(p.url(host: "mac.local") == "https://mac.local:8123/?k=S3cret")
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

@Test func storesAndLoads() {
    let defaults = UserDefaults(suiteName: "nasty3ds.test.\(UUID().uuidString)")!
    var p = Pairing(); p.pagePort = 1; p.livePort = 2; p.setUsesPhone(true, game: "/a.cci")
    p.save(to: defaults)
    #expect(Pairing.load(from: defaults) == p)
    let empty = UserDefaults(suiteName: "nasty3ds.test.\(UUID().uuidString)")!
    #expect(Pairing.load(from: empty).secret.count == 43)   // first run makes a secret
}

private func request(_ line: String) -> Data { Data((line + "\r\nHost: x\r\n\r\n").utf8) }

@Test func onlyTheExactPageRequestIsAuthorized() {
    var p = Pairing(); p.secret = "S3cret"
    #expect(PageRequest.isAuthorized(request("GET /?k=S3cret HTTP/1.1"), pairing: p))
    let bad = [
        "GET / HTTP/1.1", "GET /?k= HTTP/1.1", "GET /?k=wrong HTTP/1.1", "GET /?k=S3cretX HTTP/1.1",
        "GET /other?k=S3cret HTTP/1.1", "GET /../etc/passwd?k=S3cret HTTP/1.1", "POST /?k=S3cret HTTP/1.1",
        "GET /?k=S3cret", "GET /?x=1&k=S3cret HTTP/1.1", "",
    ]
    for line in bad { #expect(!PageRequest.isAuthorized(request(line), pairing: p), "\(line)") }
    #expect(!PageRequest.isAuthorized(Data([0xff, 0xfe, 0x00]), pairing: p))
    #expect(!PageRequest.isAuthorized(Data(repeating: 0x41, count: 9000), pairing: p))
}
