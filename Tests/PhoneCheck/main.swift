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

let pairingFile = FileManager.default.temporaryDirectory.appendingPathComponent("nasty3ds-phonecheck-pairing-\(UUID().uuidString).json")
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
let server = PhoneServer(pairingFile: pairingFile)
var states: [PhoneServer.State] = []
var touches: [String] = []
let touchLock = NSLock()
server.onStateChange = { states.append($0) }
var trustProblems = 0
server.onTrustProblem = { trustProblems += 1 }
var notes: [String] = []
server.onNote = { notes.append($0) }

/// A plain BSD socket on `port`: a listener, or (outbound) a connection to a local listener whose
/// local end is bound to `port`. Another program can hold a port in both ways.
func holdPort(_ port: UInt16, outbound: Bool) -> Int32 {
    func bound(_ port: UInt16, loopback: Bool) -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        var one: Int32 = 1        // a closed connection on the port (TIME_WAIT) must not stop the holder
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian; a.sin_addr.s_addr = loopback ? inet_addr("127.0.0.1") : INADDR_ANY
        let ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if ok != 0 { print("bind \(port) failed: errno \(errno)"); close(fd); return -1 }
        return fd
    }
    guard outbound else {
        let fd = bound(port, loopback: false)
        if fd >= 0 { Darwin.listen(fd, 4) }
        return fd
    }
    let target = bound(0, loopback: true)
    guard target >= 0 else { return -1 }
    Darwin.listen(target, 4)
    var t = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &t) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(target, $0, &len) } }
    let fd = bound(port, loopback: true)
    guard fd >= 0 else { return -1 }
    // Close with a reset: a normal close leaves the port in TIME_WAIT for a while, and then the
    // server rightly takes the backup port on the next start too.
    var hard = linger(l_onoff: 1, l_linger: 0)
    setsockopt(fd, SOL_SOCKET, SO_LINGER, &hard, socklen_t(MemoryLayout<linger>.size))
    let ok = withUnsafePointer(to: &t) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) } }
    if ok != 0 { print("connect failed: errno \(errno)"); close(fd); return -1 }
    return fd       // the target listener stays open with it; the check process ends soon
}
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

func waitFor(_ what: String, seconds: Double = 3, _ condition: @escaping () -> Bool) async -> Bool {
    for _ in 0..<Int(seconds * 20) { if condition() { return true }; try? await Task.sleep(nanoseconds: 50_000_000) }
    print("timeout waiting for", what); return false
}
func status(_ path: String, scheme: String = "https", session: URLSession? = nil, to hostName: String? = nil, port: UInt16? = nil) async -> (Int, String) {
    var request = URLRequest(url: URL(string: "\(scheme)://\(hostName ?? host):\(port ?? server.activePorts.page)\(path)")!)
    request.timeoutInterval = 5
    guard let (data, response) = try? await (session ?? trusted).data(for: request) else { return (-1, "") }
    return ((response as? HTTPURLResponse)?.statusCode ?? -1, String(data: data, encoding: .utf8) ?? "")
}
func headers(_ path: String) async -> HTTPURLResponse? {
    var request = URLRequest(url: URL(string: "https://\(host):\(server.activePorts.page)\(path)")!)
    request.timeoutInterval = 5
    return (try? await trusted.data(for: request))?.1 as? HTTPURLResponse
}
func socket() -> URLSessionWebSocketTask {
    let task = trusted.webSocketTask(with: URL(string: "wss://\(host):\(server.activePorts.live)/")!)
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
    check(server.activePorts == (server.pairing.pagePort, server.pairing.livePort) && server.stablePorts, "ports: the server listens on the saved ports")
    check(PortChoice.range.contains(server.pairing.pagePort) && PortChoice.range.contains(server.pairing.livePort),
          "first ports: both are inside \(PortChoice.range), got \(server.pairing.pagePort) and \(server.pairing.livePort)")
    check(server.pairing.backupLivePort.map { PortChoice.range.contains($0) && $0 != server.pairing.livePort && $0 != server.pairing.pagePort } == true,
          "first ports: a backup live port is picked and saved: \(String(describing: server.pairing.backupLivePort))")

    // the page
    check(await status("/").0 == 404, "page: no secret gets 404")
    check(await status("/?k=wrong").0 == 404, "page: wrong secret gets 404")
    check(await status("/other?k=\(secret)").0 == 404, "page: another path gets 404")
    let page = await status("/?k=\(secret)")
    check(page.0 == 200 && page.1.contains("<html"), "page: correct secret gets the page")
    check(!page.1.contains(secret), "page: the page text does not hold the secret")
    let pageHead = await headers("/?k=\(secret)")
    let policy = pageHead?.value(forHTTPHeaderField: "Content-Security-Policy") ?? ""
    check(policy.contains("worker-src 'self'") && policy.contains("connect-src 'self' wss://\(host):\(server.activePorts.live) wss://"),
          "page: the policy allows the worker, the page's own copy and each live port: \(policy)")
    let worker = await status("/sw.js?k=\(secret)")
    let workerHead = await headers("/sw.js?k=\(secret)")
    check(worker.0 == 200 && worker.1.contains("'navigate'"), "worker: the correct secret gets the worker")
    check(workerHead?.value(forHTTPHeaderField: "Content-Type") == "text/javascript; charset=utf-8"
          && workerHead?.value(forHTTPHeaderField: "Cache-Control") == "no-store", "worker: it is JavaScript and not kept by the browser")
    check(await status("/sw.js").0 == 404, "worker: no secret gets 404")
    check(await status("/sw.js?k=wrong").0 == 404, "worker: wrong secret gets 404")

    // TLS
    check(await status("/?k=\(secret)", session: stranger).0 == -1, "tls: a client that does not trust our CA gets no page")
    check(await status("/?k=\(secret)", scheme: "http").0 == -1, "tls: a plain http request gets no page")
    check(await status("/?k=\(secret)", to: "127.0.0.1").0 == -1, "tls: the wrong host name gets no page")
    check(server.url.hasPrefix("https://\(host):"), "tls: the pairing address is https with the .local name")

    // a phone that does not trust the certificate: the Mac must be able to tell the user
    check(trustProblems == 0, "trust: trusted clients cause no trust problem report, got \(trustProblems)")
    // one bare TCP open-and-close (a port scan, a dropped preconnect) is not a trust problem
    let bare = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: server.activePorts.live)!, using: .tcp)
    bare.start(queue: .global())
    try? await Task.sleep(nanoseconds: 400_000_000)
    bare.cancel()
    try? await Task.sleep(nanoseconds: 1_200_000_000)
    check(trustProblems == 0, "trust: one bare TCP close on the live port is not reported, got \(trustProblems)")
    // the phone page tries again each few seconds, so a real refusal repeats
    let first = stranger.webSocketTask(with: URL(string: "wss://\(host):\(server.activePorts.live)/")!)
    first.resume()
    _ = await closes(first)
    try? await Task.sleep(nanoseconds: 1_200_000_000)
    let untrusting = stranger.webSocketTask(with: URL(string: "wss://\(host):\(server.activePorts.live)/")!)
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
        for port in [server.activePorts.page, server.activePorts.live] {
            for _ in 0..<40 {
                let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
                c.start(queue: .global()); silentOnes.append(c)
            }
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let held = server.connectionCount
        // the real sockets, not only the server's list: an evicted connection must close at once
        let pageSockets = openSockets(localPort: server.activePorts.page)
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
        let junk = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: server.activePorts.live)!, using: .tcp)
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
    let restartBegan = Date()
    server.stop()
    server.start()
    // The server waits for its old port (and makes TLS options, about 100 ms, on each try): a busy Mac needs longer.
    _ = await waitFor("waiting after stop then start", seconds: 6) { states.last == .waiting }
    let restartMs = Int(Date().timeIntervalSince(restartBegan) * 1000)
    check(states.last == .waiting, "restart: stop then start at once ends in the waiting state after \(restartMs) ms, got \(String(describing: states.last))")
    check(await status("/?k=\(server.pairing.secret)").0 == 200, "restart: the page is served after stop then start")
    // A cancelled listener holds its port for about 60 ms: the server must wait for it, not move.
    let saved = (server.pairing.pagePort, server.pairing.livePort)
    for round in 1...5 {
        states.removeAll()
        server.stop(); server.start()
        _ = await waitFor("waiting after restart \(round)", seconds: 6) { states.last == .waiting }
        let file = Pairing.load(file: pairingFile)
        check(server.activePorts == saved && (file.pagePort, file.livePort) == saved && server.stablePorts,
              "restart keeps ports (\(round) of 5): active \(server.activePorts), saved \(file.pagePort) \(file.livePort), was \(saved)")
    }
    // Many starts at once (a double click on Use Phone): one port walk only. A second walk would
    // find the saved ports busy and move to a port for this session after about 2 s.
    states.removeAll()
    server.stop(); server.start(); server.start(); server.start()
    _ = await waitFor("waiting after many starts", seconds: 3) { states.last == .waiting }
    try? await Task.sleep(nanoseconds: 2_800_000_000)
    check(server.activePorts == saved && server.stablePorts && states.filter { $0 == .starting }.count == 1,
          "many starts: one walk, on the saved ports: \(server.activePorts), states \(states)")

    // forget
    server.forget()
    try? await Task.sleep(nanoseconds: 300_000_000)
    check(await status("/?k=\(secret)").0 == 404, "forget: the old secret gets 404")
    check(server.pairing.secret != secret, "forget: a new secret exists")

    // a remembered port that another program holds: this session gets another port, the saved
    // ports stay, and the next start is on the saved ports again
    let savedPorts = Pairing.load(file: pairingFile)
    let (oldPage, oldLive) = (savedPorts.pagePort, savedPorts.livePort)
    let backup = savedPorts.backupLivePort ?? 0
    func restart(holding ports: [(UInt16, Bool)]) async -> [Int32] {
        states.removeAll()
        server.stop()
        try? await Task.sleep(nanoseconds: 300_000_000)      // the old listeners free their ports
        let holders = ports.map { holdPort($0.0, outbound: $0.1) }
        server.start()
        _ = await waitFor("waiting with busy ports", seconds: 15) { states.last == .waiting }
        return holders
    }
    func release(_ holders: [Int32]) { holders.forEach { if $0 >= 0 { close($0) } } }
    func savedUnchanged() -> Bool {
        let now = Pairing.load(file: pairingFile)
        return (now.pagePort, now.livePort, now.backupLivePort) == (oldPage, oldLive, savedPorts.backupLivePort)
    }

    var holders = await restart(holding: [(oldPage, false)])
    check(holders.allSatisfy { $0 >= 0 }, "busy page port: a plain socket holds port \(oldPage)")
    var active = server.activePorts
    check(active.page != oldPage && PortChoice.range.contains(active.page), "busy page port: this session uses \(active.page), inside the range")
    check(await status("/?k=\(server.pairing.secret)").0 == 200, "busy page port: the page answers on the session port")
    check(savedUnchanged(), "busy page port: the saved ports do not change")
    check(!server.stablePorts, "busy page port: stablePorts is false")
    check(notes.contains { $0.contains("page port \(oldPage) is busy") && $0.contains("\(active.page)") }, "busy page port: one note line says so: \(notes)")
    release(holders)
    _ = await restart(holding: [])
    check(server.activePorts == (oldPage, oldLive) && server.stablePorts, "busy page port: the next start is on the saved ports again: \(server.activePorts)")

    holders = await restart(holding: [(oldLive, true)])
    check(holders.allSatisfy { $0 >= 0 }, "busy live port: an outbound connection holds port \(oldLive)")
    active = server.activePorts
    check(active.page == oldPage && active.live == backup, "busy live port: the live listener moves to the backup port \(backup), got \(active)")
    check(savedUnchanged() && server.stablePorts, "busy live port: the saved ports do not change, and the ports count as stable")
    let backupPage = await status("/?k=\(server.pairing.secret)")
    check(backupPage.0 == 200 && backupPage.1.contains("const ports = [\(backup),\(oldLive)];") && backupPage.1.contains("const stable = 1 === 1;"),
          "busy live port: the page tries the backup port first, then the saved one, and counts as stable")
    let onBackup = socket()
    try? await onBackup.send(.string(#"{"t":"hello","k":"\#(server.pairing.secret)"}"#))
    check(await waitFor("connected on backup") { states.last == .connected }, "busy live port: a phone connects on the backup port")
    onBackup.cancel(with: .goingAway, reason: nil)
    release(holders)

    holders = await restart(holding: [(oldLive, true), (backup, false)])
    active = server.activePorts
    check(active.live != oldLive && active.live != backup && PortChoice.range.contains(active.live), "busy live and backup ports: this session uses \(active.live)")
    check(savedUnchanged() && !server.stablePorts, "busy live and backup ports: the saved ports do not change, stablePorts is false")
    release(holders)
    _ = await restart(holding: [])
    check(server.activePorts == (oldPage, oldLive) && server.stablePorts, "busy ports: the next start is on the saved ports again: \(server.activePorts)")

    // a second server on the same file (a second copy of the app) gets ports for its session only
    let second = PhoneServer(pairingFile: pairingFile)
    var secondStates: [PhoneServer.State] = []
    second.onStateChange = { secondStates.append($0) }
    second.start()
    check(await waitFor("second server", seconds: 15) { secondStates.contains(.waiting) }, "second server: it starts")
    check(second.activePorts.page != oldPage && second.activePorts.page != 0 && !second.stablePorts, "second server: it takes a session page port: \(second.activePorts)")
    check(savedUnchanged(), "second server: the saved ports do not change")
    second.stop()
    check(!notes.contains { $0.contains(server.pairing.secret) }, "notes never hold the secret")

    try? FileManager.default.removeItem(at: PhoneTLS.folder)     // scratch keys do not stay on disk
    print(failures == 0 ? "PASS: check-phone" : "FAILED: \(failures) checks")
    exit(failures == 0 ? 0 : 1)
}
RunLoop.main.run()
