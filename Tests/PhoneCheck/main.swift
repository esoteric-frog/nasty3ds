import CoreGraphics
import Foundation
import ImageIO
import Nasty3DSKit
import Network
import Security

// Starts the real PhoneServer on free ports and attacks it with a small client. No phone, no game.
setvbuf(stdout, nil, _IONBF, 0)
var failures = 0
func check(_ ok: Bool, _ name: String) { print(ok ? "ok   " : "FAIL ", name); if !ok { failures += 1 } }

let defaults = UserDefaults(suiteName: "nasty3ds.phonecheck.\(UUID().uuidString)")!
let host = LocalAddress.host()

// Certificates go to a scratch folder: the check must never replace the CA the iPhone trusts.
PhoneTLS.folder = FileManager.default.temporaryDirectory.appendingPathComponent("nasty3ds-phonecheck-\(UUID().uuidString)")
try! PhoneTLS.ensureCertificates()
let firstFingerprint = PhoneTLS.fingerprint()
// The same Mac name in another letter case must not make a new CA (this bug replaced a CA that
// the user had installed on the iPhone).
try! host.uppercased().replacingOccurrences(of: ".LOCAL", with: ".local")
    .write(to: PhoneTLS.folder.appendingPathComponent("ca.name"), atomically: true, encoding: .utf8)
try! PhoneTLS.ensureCertificates()
check(firstFingerprint != nil && PhoneTLS.fingerprint() == firstFingerprint, "certificates: the same name in another letter case keeps the CA")
check(host == host.lowercased(), "certificates: the host name is in one fixed letter case")
do {    // the name must be the Bonjour name that the network advertises, not the system host name
    let scutil = Process(); let out = Pipe()
    scutil.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil"); scutil.arguments = ["--get", "LocalHostName"]
    scutil.standardOutput = out; try! scutil.run(); scutil.waitUntilExit()
    let bonjour = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
    check(host == bonjour.lowercased() + ".local", "certificates: the host name is the Bonjour local name")
}

/// Trusts only our own CA file, as the iPhone does after the setup. `trustCA: false` = a stranger.
final class Trust: NSObject, URLSessionDelegate {
    let anchor: SecCertificate?
    init(trustCA: Bool) {
        let pem = (try? String(contentsOf: PhoneTLS.caFile, encoding: .utf8)) ?? ""
        let der = Data(base64Encoded: pem.components(separatedBy: "\n").filter { !$0.hasPrefix("-----") }.joined()) ?? Data()
        anchor = trustCA ? SecCertificateCreateWithData(nil, der as CFData) : nil
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust, let anchor else { return (.performDefaultHandling, nil) }
        SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        return SecTrustEvaluateWithError(trust, nil) ? (.useCredential, URLCredential(trust: trust)) : (.cancelAuthenticationChallenge, nil)
    }
}
let trusted = URLSession(configuration: .ephemeral, delegate: Trust(trustCA: true), delegateQueue: nil)
let stranger = URLSession(configuration: .ephemeral, delegate: Trust(trustCA: false), delegateQueue: nil)
let server = PhoneServer(defaults: defaults)
var states: [PhoneServer.State] = []
var touches: [String] = []
let touchLock = NSLock()
server.onStateChange = { states.append($0) }
var trustProblems = 0
server.onTrustProblem = { trustProblems += 1 }
server.onTouch = { t in touchLock.withLock { touches.append(t.map { "\($0.u),\($0.v)" } ?? "nil") } }

/// Open TCP sockets of this process with the given local port (the server side of a connection).
func openSockets(localPort: UInt16) -> Int {
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    p.arguments = ["-nP", "-p", String(getpid()), "-a", "-i", "TCP"]
    p.standardOutput = out; p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return -1 }
    let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    p.waitUntilExit()
    return text.split(separator: "\n").filter { $0.contains(":\(localPort)->") }.count
}

func waitFor(_ what: String, _ condition: @escaping () -> Bool) async -> Bool {
    for _ in 0..<60 { if condition() { return true }; try? await Task.sleep(nanoseconds: 50_000_000) }
    print("timeout waiting for", what); return false
}
func status(_ path: String, scheme: String = "https", session: URLSession? = nil, to hostName: String? = nil) async -> (Int, String) {
    var request = URLRequest(url: URL(string: "\(scheme)://\(hostName ?? host):\(server.pairing.pagePort)\(path)")!)
    request.timeoutInterval = 5
    guard let (data, response) = try? await (session ?? trusted).data(for: request) else { return (-1, "") }
    return ((response as? HTTPURLResponse)?.statusCode ?? -1, String(data: data, encoding: .utf8) ?? "")
}
func socket() -> URLSessionWebSocketTask {
    let task = trusted.webSocketTask(with: URL(string: "wss://\(host):\(server.pairing.livePort)/")!)
    task.resume()
    return task
}
/// True if the server closes the socket within 3 seconds.
func closes(_ task: URLSessionWebSocketTask) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask { do { _ = try await task.receive(); return false } catch { return true } }
        group.addTask { try? await Task.sleep(nanoseconds: 3_000_000_000); return false }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
}
func testImage() -> CGImage {
    let context = CGContext(data: nil, width: 400, height: 480, bitsPerComponent: 8, bytesPerRow: 1600,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)!
    context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 400, height: 480))
    return context.makeImage()!
}

Task {
    server.start()
    check(await waitFor("waiting state") { states.contains(.waiting) }, "server starts on free ports")
    let secret = server.pairing.secret
    check(server.pairing.pagePort != 0 && server.pairing.livePort != 0, "ports are recorded")

    // the page
    check(await status("/").0 == 404, "page: no secret gets 404")
    check(await status("/?k=wrong").0 == 404, "page: wrong secret gets 404")
    check(await status("/other?k=\(secret)").0 == 404, "page: another path gets 404")
    let page = await status("/?k=\(secret)")
    check(page.0 == 200 && page.1.contains("<html"), "page: correct secret gets the page")
    check(!page.1.contains(secret), "page: the page text does not hold the secret")

    // TLS
    check(await status("/?k=\(secret)", session: stranger).0 == -1, "tls: a client that does not trust our CA gets no page")
    check(await status("/?k=\(secret)", scheme: "http").0 == -1, "tls: a plain http request gets no page")
    check(await status("/?k=\(secret)", to: "127.0.0.1").0 == -1, "tls: the wrong host name gets no page")
    check(server.url.hasPrefix("https://\(host):"), "tls: the pairing address is https with the .local name")

    // a phone that does not trust the certificate: the Mac must be able to tell the user
    check(trustProblems == 0, "trust: trusted clients cause no trust problem report, got \(trustProblems)")
    // one bare TCP open-and-close (a port scan, a dropped preconnect) is not a trust problem
    let bare = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: server.pairing.livePort)!, using: .tcp)
    bare.start(queue: .global())
    try? await Task.sleep(nanoseconds: 400_000_000)
    bare.cancel()
    try? await Task.sleep(nanoseconds: 1_200_000_000)
    check(trustProblems == 0, "trust: one bare TCP close on the live port is not reported, got \(trustProblems)")
    // the phone page tries again each few seconds, so a real refusal repeats
    let first = stranger.webSocketTask(with: URL(string: "wss://\(host):\(server.pairing.livePort)/")!)
    first.resume()
    _ = await closes(first)
    try? await Task.sleep(nanoseconds: 1_200_000_000)
    let untrusting = stranger.webSocketTask(with: URL(string: "wss://\(host):\(server.pairing.livePort)/")!)
    untrusting.resume()
    _ = await closes(untrusting)
    _ = await waitFor("trust problem") { trustProblems == 1 }      // the server can take some seconds to see it
    check(await waitFor("trust problem") { trustProblems == 1 }, "trust: a client that refuses the certificate on the live port is reported")

    // the live connection
    let wrong = socket()
    try? await wrong.send(.string(#"{"t":"hello","k":"wrong"}"#))
    check(await closes(wrong), "live: wrong hello is closed")
    let early = socket()
    try? await early.send(.string(#"{"t":"down","u":0.5,"v":0.5}"#))
    check(await closes(early), "live: a message before hello is closed")
    check(!touchLock.withLock { touches.contains("0.5,0.5") }, "live: a touch before hello does not reach the game")

    let phone = socket()
    try? await phone.send(.string(#"{"t":"hello","k":"\#(secret)"}"#))
    check(await waitFor("connected") { states.last == .connected }, "live: correct hello connects")
    var sawFrame = false
    for _ in 0..<40 where !sawFrame {
        server.submit(testImage(), split: FrameSplit(frameWidth: 400, frameHeight: 480))
        if case .data(let data)? = try? await phone.receive(),
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            sawFrame = image.width == 320 && image.height == 240
        }
    }
    check(sawFrame, "live: a JPEG frame of 320 x 240 arrives")
    try? await phone.send(.string(#"{"t":"down","u":1,"v":1}"#))
    check(await waitFor("touch") { touchLock.withLock { touches.last == "1.0,1.0" } }, "live: a touch reaches the game")
    phone.cancel(with: .goingAway, reason: nil)
    check(await waitFor("release") { touchLock.withLock { touches.last == "nil" } }, "live: the touch releases when the phone goes")
    check(await waitFor("waiting again") { states.last == .waiting }, "live: state goes back to waiting")

    // a phone that goes silent in the middle of a drag (Wi-Fi lost: no close arrives)
    let silent = socket()
    try? await silent.send(.string(#"{"t":"hello","k":"\#(secret)"}"#))
    _ = await waitFor("connected") { states.last == .connected }
    try? await silent.send(.string(#"{"t":"down","u":0.5,"v":0.5}"#))
    _ = await waitFor("touch") { touchLock.withLock { touches.last == "0.5,0.5" } }
    // this client never answers a ping and never closes
    var released = false
    for _ in 0..<100 where !released {
        released = touchLock.withLock { touches.last == "nil" }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    check(released, "silent phone: the touch releases within 5 s with no close from the phone")
    check(await waitFor("waiting after silence") { states.last == .waiting }, "silent phone: state goes back to waiting")
    silent.cancel(with: .goingAway, reason: nil)
    try? await Task.sleep(nanoseconds: 300_000_000)

    // a neighbour opens many connections and says nothing: the server must not hold them all
    // (each one costs a file descriptor; a Finder-started app has only 256)
    import_flood: do {
        var silentOnes: [NWConnection] = []
        for port in [server.pairing.pagePort, server.pairing.livePort] {
            for _ in 0..<40 {
                let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
                c.start(queue: .global()); silentOnes.append(c)
            }
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let held = server.connectionCount
        // the real sockets, not only the server's list: an evicted connection must close at once
        let pageSockets = openSockets(localPort: server.pairing.pagePort)
        check(pageSockets <= PhoneServer.maxPageConnections + 1, "flood: the page port holds \(pageSockets) real sockets (cap \(PhoneServer.maxPageConnections))")
        check(held <= PhoneServer.maxPageConnections + PhoneServer.maxWaiting + 1, "flood: 80 silent connections, the server holds \(held)")
        check(await status("/?k=\(server.pairing.secret)").0 == 200, "flood: the page is still served during the flood")
        silentOnes.forEach { $0.cancel() }
        try? await Task.sleep(nanoseconds: 800_000_000)
    }

    // limits
    // 4 silent connections hold every waiting slot; the real phone must still get in
    let idle = (0..<4).map { _ in socket() }
    try? await Task.sleep(nanoseconds: 500_000_000)
    let fifth = socket()
    try? await fifth.send(.string(#"{"t":"hello","k":"\#(secret)"}"#))
    check(await waitFor("fifth connects") { states.last == .connected }, "limit: with 4 silent connections waiting, the real phone still connects")
    check(server.connectionCount <= PhoneServer.maxWaiting + 1, "limit: the oldest silent connection was dropped, the server holds \(server.connectionCount)")
    fifth.cancel(with: .goingAway, reason: nil)
    idle.forEach { $0.cancel(with: .goingAway, reason: nil) }
    _ = await waitFor("waiting") { states.last == .waiting }
    try? await Task.sleep(nanoseconds: 500_000_000)

    // plain http and random bytes on the live port are not a trust problem
    let before = trustProblems
    for _ in 0..<5 {
        let junk = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: server.pairing.livePort)!, using: .tcp)
        junk.start(queue: .global())
        junk.send(content: Data("GET / HTTP/1.1\r\n\r\n".utf8), completion: .idempotent)
        try? await Task.sleep(nanoseconds: 200_000_000)
        junk.cancel()
    }
    try? await Task.sleep(nanoseconds: 1_500_000_000)
    check(trustProblems == before, "trust: plain http on the live port is not reported as a trust problem (\(trustProblems - before) reports)")

    let big = socket()
    try? await big.send(.string(#"{"t":"hello","k":"\#(secret)"}"#))
    _ = await waitFor("connected") { states.last == .connected }
    try? await big.send(.string(#"{"t":"up","pad":""# + String(repeating: "x", count: 400) + #""}"#))
    check(await waitFor("oversize closes") { states.last == .waiting }, "limit: an oversize message closes the connection")

    // stop then start at once (a second game opens while the old phone session ends)
    states.removeAll()
    server.stop()
    server.start()
    try? await Task.sleep(nanoseconds: 600_000_000)
    check(states.last == .waiting, "restart: stop then start at once ends in the waiting state, got \(String(describing: states.last))")
    check(await status("/?k=\(server.pairing.secret)").0 == 200, "restart: the page is served after stop then start")

    // forget
    server.forget()
    try? await Task.sleep(nanoseconds: 300_000_000)
    check(await status("/?k=\(secret)").0 == 404, "forget: the old secret gets 404")
    check(server.pairing.secret != secret, "forget: a new secret exists")

    // a remembered port that is in use
    let takenPage = server.pairing.pagePort
    let second = PhoneServer(defaults: defaults)        // loads the same ports
    var secondStates: [PhoneServer.State] = []
    second.onStateChange = { secondStates.append($0) }
    second.start()
    check(await waitFor("second server") { secondStates.contains(.waiting) }, "ports: a second server starts")
    check(second.pairing.pagePort != takenPage && second.pairing.pagePort != 0, "ports: it took a free port")

    try? FileManager.default.removeItem(at: PhoneTLS.folder)     // scratch keys do not stay on disk
    print(failures == 0 ? "PASS: check-phone" : "FAILED: \(failures) checks")
    exit(failures == 0 ? 0 : 1)
}
RunLoop.main.run()
