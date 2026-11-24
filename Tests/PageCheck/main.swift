import AppKit
import Nasty3DSKit
import Security
import WebKit

// End to end in WebKit, the engine Safari on the iPhone uses: the real PhoneServer (scratch
// certificates), the real page over https, the live connection over wss, frames in, touch out.
setvbuf(stdout, nil, _IONBF, 0)
var failures = 0
func check(_ ok: Bool, _ name: String) { print(ok ? "ok   " : "FAIL ", name); if !ok { failures += 1 } }

PhoneTLS.folder = FileManager.default.temporaryDirectory.appendingPathComponent("nasty3ds-pagecheck-\(UUID().uuidString)")
let pairingFile = FileManager.default.temporaryDirectory.appendingPathComponent("nasty3ds-pagecheck-pairing-\(UUID().uuidString).json")
let server = PhoneServer(pairingFile: pairingFile)
var states: [PhoneServer.State] = []
var touches: [String] = []
let touchLock = NSLock()
server.onStateChange = { states.append($0) }
server.onTouch = { t in touchLock.withLock { touches.append(t.map { String(format: "%.2f,%.2f", $0.u, $0.v) } ?? "nil") } }

final class Page: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var errors: [String] = []
    var challenges = 0
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) { errors.append("\(message.body)") }
    // Trust only our CA, as the iPhone does after the setup.
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        challenges += 1
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let pem = try? String(contentsOf: PhoneTLS.caFile, encoding: .utf8),
              let der = Data(base64Encoded: pem.components(separatedBy: "\n").filter { !$0.hasPrefix("-----") }.joined()),
              let anchor = SecCertificateCreateWithData(nil, der as CFData)
        else { completionHandler(.performDefaultHandling, nil); return }
        SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        completionHandler(SecTrustEvaluateWithError(trust, nil) ? .useCredential : .cancelAuthenticationChallenge, URLCredential(trust: trust))
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        errors.append("navigation failed: \((error as NSError).code)")
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

let page = Page()
let config = WKWebViewConfiguration()
config.websiteDataStore = .nonPersistent()
// The check window is off screen, so the page is "hidden", and WebKit slows the timers of a
// hidden page to many seconds. A phone runs the page on screen: let the timers run at speed.
config.preferences.inactiveSchedulingPolicy = .none
config.userContentController.add(page, name: "errors")
config.userContentController.addUserScript(WKUserScript(source: """
    window.addEventListener('error', (e) => window.webkit.messageHandlers.errors.postMessage('script: ' + e.message + ' @line ' + e.lineno));
    // A stand-in for the Screen Wake Lock: it refuses a request with no finished tap, as Safari can.
    window.__wake = { asked: 0, held: 0, tapDone: false };
    Object.defineProperty(navigator, 'wakeLock', { configurable: true, value: { request: async () => {
      window.__wake.asked++;
      if (!window.__wake.tapDone) throw new DOMException('no user activation', 'NotAllowedError');
      window.__wake.held++;
      return { addEventListener() {} };
    } } });
    document.addEventListener('securitypolicyviolation', (e) => window.webkit.messageHandlers.errors.postMessage('csp: ' + e.violatedDirective + ' blocked ' + e.blockedURI));
    """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
let app = NSApplication.shared
let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
web.navigationDelegate = page
let window = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
window.contentView = web
window.setFrameOrigin(NSPoint(x: -3000, y: -3000))      // off screen: WebKit draws only in a window that is ordered in
window.orderBack(nil)

func js(_ source: String, _ done: @escaping (String) -> Void) {
    web.evaluateJavaScript(source) { result, error in done((result as? String) ?? "error: \(String(describing: error))") }
}
func after(_ seconds: Double, _ work: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work) }
func finish() {
    try? FileManager.default.removeItem(at: PhoneTLS.folder)
    print(failures == 0 ? "PASS: check-page" : "FAILED: \(failures) checks")
    exit(failures == 0 ? 0 : 1)
}

func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
@MainActor func eval(_ source: String) async -> String {
    await withCheckedContinuation { done in js(source) { done.resume(returning: $0) } }
}
/// For a script that awaits: the result of its `return`, as text.
@MainActor func evalAsync(_ body: String) async -> String {
    do { return "\(try await web.callAsyncJavaScript(body, contentWorld: .page) ?? "nil")" } catch { return "error: \(error)" }
}
@MainActor func waitUntil(_ seconds: Double, _ condition: () async -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { if await condition() { return true }; await pause(0.25) }
    return false
}
@MainActor func pictureLive() async -> Bool {
    let live = await eval("String(document.getElementById('screen').classList.contains('live'))")
    return states.last == .connected && live == "true"
}
@MainActor func statusText() async -> String {
    await eval("document.getElementById('status') ? document.getElementById('status').textContent : 'no page'")
}
/// A plain listening socket on `port`: another program that holds the port.
func holdPort(_ port: UInt16) -> Int32 {
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
    var a = sockaddr_in()
    a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET)
    a.sin_port = port.bigEndian; a.sin_addr.s_addr = INADDR_ANY
    let ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    guard ok == 0, Darwin.listen(fd, 4) == 0 else { print("hold \(port) failed: errno \(errno)"); close(fd); return -1 }
    return fd
}

/// The parts after the first live picture: a dead link with no close, the copy of the page on
/// the phone (service worker), and the backup live port.
@MainActor func laterParts() async {
    // A link that dies with no close (a page back from the background can hold one): the page
    // must replace it by itself, and only once.
    let before = server.helloCount
    server.muteForCheck = true
    let muted = Date()
    let replaced = await waitUntil(12) { server.helloCount > before }
    let took = Date().timeIntervalSince(muted)
    server.muteForCheck = false
    check(replaced && took < 10.5, "watchdog: a link that goes quiet with no close is replaced by a new one, after \(String(format: "%.1f", took)) s")
    let recovered = server.helloCount
    await pause(10)
    check(server.helloCount - recovered <= 1, "watchdog: at most one new connection in the 10 s after recovery, got \(server.helloCount - recovered)")
    check(await pictureLive(), "watchdog: the picture is live again: \(states.suffix(3))")

    // The copy of the page on the phone (the home screen icon opens before the Mac is ready).
    guard await eval("String('serviceWorker' in navigator)") == "true" else {
        print("SKIP: this WebKit view has no service worker")
        return
    }
    var controlled = await waitUntil(10) { await eval("String(!!navigator.serviceWorker.controller)") == "true" }
    if !controlled {
        web.reload()
        controlled = await waitUntil(10) { await eval("String(!!navigator.serviceWorker.controller)") == "true" }
    }
    check(controlled, "offline: the service worker controls the page")
    let primed = await evalAsync("const c = await caches.open('nasty3ds-1'); return String(!!(await c.match(location.href)));")
    check(primed == "true", "offline: the page is in the phone's copy: \(primed)")
    server.stop()
    await pause(0.5)
    page.errors.removeAll()
    web.reload()
    let offline = await waitUntil(15) { await statusText().contains("Start a game on your Mac.") }
    let shown = await statusText()
    check(offline && page.errors.isEmpty, "offline: with the Mac not serving, the page opens from the copy and says what to do: \(shown) \(page.errors)")
    server.start()
    check(await waitUntil(15) { await pictureLive() }, "offline: when the Mac serves again, frames come with no reload")

    // The copy finds the Mac on the backup live port when another program holds the saved one.
    let live = server.pairing.livePort, backup = server.pairing.backupLivePort ?? 0
    server.stop()
    await pause(0.5)
    web.reload()
    _ = await waitUntil(15) { await statusText().contains("Start a game on your Mac.") }
    let holder = holdPort(live)
    server.start()
    let onBackup = await waitUntil(30) { await pictureLive() }
    check(holder >= 0 && onBackup && server.activePorts.live == backup,
          "backup port: the copy of the page connects on the backup port \(backup) with no new scan: \(server.activePorts)")
    if holder >= 0 { close(holder) }
}

server.start()
after(2.0) {
    check(states.last == .waiting, "the server waits for a phone: \(states)")
    web.load(URLRequest(url: URL(string: server.url)!))
    let frames = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
        server.submit(testImage(), split: FrameSplit(frameWidth: 400, frameHeight: 480))
    }
    after(5.0) {
        js("JSON.stringify({ src: document.getElementById('screen').src.slice(0, 5), status: document.getElementById('status').textContent, ready: socket ? socket.readyState : -1, live: document.getElementById('screen').classList.contains('live'), opacity: getComputedStyle(document.getElementById('screen')).opacity, w: document.getElementById('screen').naturalWidth, hidden: document.visibilityState })") { state in
            check(server.wakeReport == "no:NotAllowedError", "before a tap, the Mac knows the lock was refused: \(String(describing: server.wakeReport))")
            check(state.contains(#""live":true"#), "the picture is shown, not only loaded: \(state)")
            check(page.errors.isEmpty, "no script, policy or navigation error in WebKit: \(page.errors)")
            check(states.last == .connected, "the server sees the phone connected: \(states)")
            check(state.contains(#""src":"blob:""#), "frames reach the picture: \(state)")
            check(state.contains(#""status":"""#), "the status text is empty when connected")
            js("""
                (() => { const v = document.getElementById('screen'); const r = v.getBoundingClientRect();
                  const o = { bubbles: true, clientX: r.left + r.width * 0.25, clientY: r.top + r.height * 0.75, pointerId: 1, pointerType: 'touch', buttons: 1 };
                  try { v.dispatchEvent(new PointerEvent('pointerdown', o)); } catch (e) { return 'threw ' + e; }
                  return 'sent'; })()
                """) { sent in
                after(1.0) {
                    check(touchLock.withLock { touches.last == "0.25,0.75" }, "a touch on the page reaches the game: \(sent) \(touchLock.withLock { touches.suffix(2) })")
                    // the display must stay on: asked at load, and held after the first finished tap
                    js("""
                        (async () => { const w = window.__wake; const atLoad = w.asked;
                          w.tapDone = true;
                          const v = document.getElementById('screen');
                          v.dispatchEvent(new PointerEvent('pointerup', { bubbles: true, pointerId: 1, pointerType: 'touch' }));
                          await new Promise((r) => setTimeout(r, 100));
                          return JSON.stringify({ atLoad, held: w.held }); })()
                        """) { _ in }
                    // the full-screen note: visible in Safari, hidden after "Hide", and it stays hidden
                    js("JSON.stringify({ shown: getComputedStyle(document.getElementById('tip')).display, text: document.getElementById('tip').textContent, wake: window.__wake })") { tip in
                        check(tip.contains(#""held":1"#), "the wake lock is held after the first finished tap, with a refusal before it: \(tip.suffix(60))")
                        check(tip.contains(#""shown":"flex""#) && tip.contains("Add to Home Screen"), "the full-screen note shows in Safari: \(tip)")
                        let shot = WKSnapshotConfiguration()
                        web.takeSnapshot(with: shot) { image, _ in
                            if let folder = ProcessInfo.processInfo.environment["N3_SNAPSHOT_DIR"], let tiff = image?.tiffRepresentation,
                               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                                try? png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("phone-page.png"))
                            }
                            js("document.getElementById('tipHide').click(); JSON.stringify({ shown: getComputedStyle(document.getElementById('tip')).display, stored: localStorage.getItem('tipHidden') })") { hidden in
                                check(hidden.contains(#""shown":"none""#) && hidden.contains(#""stored":"1""#), "Hide removes the note and remembers it: \(hidden)")
                                after(1.5) {     // the report rides on the next ping, one each second
                                    check(server.wakeReport == "held", "the page reports its display lock to the Mac: \(String(describing: server.wakeReport))")
                                    Task { @MainActor in
                                        await laterParts()
                                        frames.invalidate()
                                        finish()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
app.run()
