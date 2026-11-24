import AppKit
import ImageIO
import Nasty3DSKit
import Network
import UniformTypeIdentifiers

/// Serves the lower screen to one phone on the local network.
/// All state is owned by `queue`, except `pairing`, the active ports and the round-trip time, which a lock guards.
final class PhoneServer {
    enum State: Equatable { case stopped, starting, waiting, connected, failed(String) }

    /// JPEG quality for the lower screen. Lower = less delay on weak Wi-Fi, more blur.
    static let jpegQuality = 0.7
    static let maxWaiting = 4
    static let maxPageConnections = 8
    static let helloTimeout = 5.0
    /// A phone that answers no ping for this long is gone (Wi-Fi lost: no close arrives).
    /// Its touch must release. The page connects again by itself.
    static let silenceLimit = 4.0

    /// Called on the main queue.
    var onStateChange: ((State) -> Void)?
    /// Called on the main queue when a device reached the live port but the secure session did
    /// not start. The usual cause: the iPhone does not trust this Mac's certificate.
    var onTrustProblem: (() -> Void)?
    /// Called on the server queue. Nil = finger up, or the phone is gone.
    var onTouch: (((u: Double, v: Double)?) -> Void)?
    /// Called on the server queue with one line for the log, when a port is used for this session only.
    /// It never holds the secret or the link.
    var onNote: ((String) -> Void)?

    private let pairingFile: URL
    private let legacy: [UserDefaults]      // the old places of the pairing; Forget Phone clears them too
    private let queue = DispatchQueue(label: "nasty3ds.phone")
    private let lock = NSLock()
    private var _pairing: Pairing
    private var _roundTripMs: Double?
    private var _wakeReport: String?
    private var _activePagePort: UInt16 = 0, _activeLivePort: UInt16 = 0     // 0 while stopped

    private var pageListener: NWListener?
    private var liveListener: NWListener?
    private var pageReady = false, liveReady = false
    private var waiting: [ObjectIdentifier: NWConnection] = [:]
    private var sessions: [ObjectIdentifier: PhoneSession] = [:]
    private var phone: NWConnection?
    private var pageConnections: [NWConnection] = []      // oldest first
    private var waitingOrder: [NWConnection] = []         // oldest first
    /// How many connections the server holds now (page requests, waiting, the phone). For checks.
    var connectionCount: Int { queue.sync { pageConnections.count + waiting.count + (phone == nil ? 0 : 1) } }
    /// How many times a phone said a correct hello. For checks.
    var helloCount: Int { queue.sync { hellos } }
    private var hellos = 0
    /// For check-page only: true = no pings, no frames and no silence limit, like a link that
    /// died with no close. The page must find that by itself.
    var muteForCheck: Bool {
        get { lock.withLock { _mute } }
        set { lock.withLock { _mute = newValue } }
    }
    private var _mute = false
    private var gate = FrameGate<CGImage>()
    private var state = State.stopped
    /// One more on each stop(). A port walk or a listener of an older start sees it and ends.
    private var generation = 0
    /// The generation whose port walks started. One start per generation: no second walk while
    /// one runs or after one gave up. stop() begins a new generation.
    private var startedGeneration = -1
    private var pingTimer: DispatchSourceTimer?
    private var pingSent: [Int: CFAbsoluteTime] = [:]
    private var pingID = 0
    private var lastPong = CFAbsoluteTimeGetCurrent()
    private var lastTrustReport = 0.0
    private var lastSilentClose = 0.0
    private var secured = Set<ObjectIdentifier>()     // live connections with a finished TLS handshake

    /// `legacy`: the old UserDefaults places of the pairing, read only when the file is not there yet.
    init(pairingFile: URL, legacy: [UserDefaults] = []) {
        self.pairingFile = pairingFile
        self.legacy = legacy
        _pairing = Pairing.load(file: pairingFile, legacy: legacy)
    }

    var pairing: Pairing { lock.withLock { _pairing } }
    var url: String { pairing.url(host: LocalAddress.host(), port: activePorts.page) }
    /// The ports the listeners use now (0 = not listening). For the page and the checks.
    var activePorts: (page: UInt16, live: UInt16) { lock.withLock { (_activePagePort, _activeLivePort) } }
    /// True when a link saved on the phone works now: the saved page port, and the saved or the backup live port.
    var stablePorts: Bool {
        lock.withLock {
            _activePagePort != 0 && _activePagePort == _pairing.pagePort
                && _activeLivePort != 0 && (_activeLivePort == _pairing.livePort || _activeLivePort == _pairing.backupLivePort)
        }
    }
    var roundTripMs: Double? { lock.withLock { _roundTripMs } }
    /// What the page last said about its display lock: "held", "no:<reason>", or nil.
    var wakeReport: String? { lock.withLock { _wakeReport } }

    private func updatePairing(_ change: (inout Pairing) -> Void) {
        // The save is inside the lock: a start and a Forget Phone can overlap, and the older one must not win.
        lock.withLock { change(&_pairing); _pairing.save(file: pairingFile) }
    }

    func setUsesPhone(_ on: Bool, game: String) { updatePairing { $0.setUsesPhone(on, game: game) } }

    /// A new secret. The phone that is connected now is dropped.
    func forget() {
        updatePairing { $0.forget() }
        Pairing.forgetLegacy(legacy)            // the forgotten secret must not come back from there
        queue.async { [self] in
            phone?.cancel()
            waiting.values.forEach { $0.cancel() }
        }
    }

    // MARK: start and stop

    func start() {
        queue.async { [self] in
            guard pageListener == nil, liveListener == nil else { return }
            guard state != .starting, startedGeneration != generation else { return }    // a port walk runs or gave up
            startedGeneration = generation
            set(.starting)
            pageReady = false; liveReady = false
            if pairing.backupLivePort == nil {
                let taken = [pairing.pagePort, pairing.livePort]
                var backup = UInt16.random(in: PortChoice.range)
                while taken.contains(backup) { backup = UInt16.random(in: PortChoice.range) }
                updatePairing { $0.backupLivePort = backup }
            }
            listen(live: false, attempt: 0, generation: generation)
            listen(live: true, attempt: 0, generation: generation)
        }
    }

    func stop() {
        queue.async { [self] in
            // Everything ends now, in this one block, so a start() right after begins clean.
            // Only the old phone connection lives a moment longer, to let "closed" leave.
            generation += 1
            lock.withLock { _activePagePort = 0; _activeLivePort = 0 }
            let oldPhone = phone
            if let oldPhone { sendText(PhoneMessage.state("closed"), to: oldPhone) }
            phone = nil
            pingTimer?.cancel(); pingTimer = nil
            waiting.values.forEach { $0.cancel() }
            waiting = [:]; sessions = [:]; waitingOrder = []; secured = []
            pageConnections.forEach { $0.cancel() }
            pageConnections = []
            pageListener?.cancel(); liveListener?.cancel()
            pageListener = nil; liveListener = nil
            pageReady = false; liveReady = false
            gate.reset()
            lock.withLock { _roundTripMs = nil }
            onTouch?(nil)
            set(.stopped)
            if let oldPhone { queue.asyncAfter(deadline: .now() + 0.1) { oldPhone.cancel() } }
        }
    }

    private func set(_ new: State) {
        guard new != state else { return }
        state = new
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(new) }
    }

    /// Walks `PortChoice.step` until a listener is ready. A busy port means "next step". Only a
    /// step with `remember` writes the port: the saved link must not change by accident.
    private func listen(live: Bool, attempt: Int, generation started: Int) {
        guard started == generation else { return }         // stop() came: this walk ends
        let saved = pairing
        let remembered = live ? saved.livePort : saved.pagePort
        guard let step = PortChoice.step(remembered: remembered, backup: live ? saved.backupLivePort : nil, attempt: attempt) else {
            set(.failed("The phone server did not start."))
            return
        }
        guard step.wait == 0 else {
            queue.asyncAfter(deadline: .now() + step.wait) { [weak self] in self?.open(live: live, step: step, attempt: attempt, generation: started) }
            return
        }
        open(live: live, step: step, attempt: attempt, generation: started)
    }

    private func open(live: Bool, step: PortChoice.Step, attempt: Int, generation started: Int) {
        guard started == generation else { return }
        guard let tls = try? PhoneTLS.tlsOptions() else {
            set(.failed("The phone certificate could not be made."))
            return
        }
        let parameters = NWParameters(tls: tls)
        if live {
            let options = NWProtocolWebSocket.Options()
            options.autoReplyPing = true
            options.maximumMessageSize = PhoneMessage.maxLength
            parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        }
        guard let port = NWEndpoint.Port(rawValue: step.port), let listener = try? NWListener(using: parameters, on: port) else {
            listen(live: live, attempt: attempt + 1, generation: started)
            return
        }
        // A replaced listener is cancelled first: it must not keep its port.
        if live { liveListener?.cancel(); liveListener = listener } else { pageListener?.cancel(); pageListener = listener }
        listener.newConnectionHandler = { [weak self] connection in
            if live { self?.acceptLive(connection) } else { self?.acceptPage(connection) }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] newState in
            guard let self, let listener, started == self.generation,
                  listener === (live ? self.liveListener : self.pageListener) else { return }
            switch newState {
            case .ready:
                self.lock.withLock { if live { self._activeLivePort = step.port } else { self._activePagePort = step.port } }
                if step.remember {
                    self.updatePairing { if live { $0.livePort = step.port } else { $0.pagePort = step.port } }
                } else {
                    let saved = self.pairing
                    let wanted = live ? saved.livePort : saved.pagePort
                    let kind = step.port == saved.backupLivePort ? "the backup port" : "\(step.port) (the saved link works again next time)"
                    self.onNote?("phone: \(live ? "live" : "page") port \(wanted) is busy; this session uses \(kind)")
                }
                if live { self.liveReady = true } else { self.pageReady = true }
                if self.pageReady, self.liveReady, self.phone == nil { self.set(.waiting) }
            case .failed:
                listener.cancel()
                if live { self.liveListener = nil; self.liveReady = false } else { self.pageListener = nil; self.pageReady = false }
                self.lock.withLock { if live { self._activeLivePort = 0 } else { self._activePagePort = 0 } }
                self.listen(live: live, attempt: attempt + 1, generation: started)
            default:
                break
            }
        }
        listener.start(queue: queue)
    }

    // MARK: the page

    // ponytail: one receive call. A request line split across two packets gets a 404.
    private func acceptPage(_ connection: NWConnection) {
        // A cap, so many silent connections cannot use up the app's file descriptors. When it is
        // full, the oldest one goes: a real request is short, a silent one is the one that waits.
        if pageConnections.count >= Self.maxPageConnections { pageConnections.removeFirst().cancel() }
        pageConnections.append(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] newState in
            switch newState {
            case .failed, .cancelled: self?.pageConnections.removeAll { $0 === connection }
            default: break
            }
        }
        connection.start(queue: queue)
        // weak: a strong hold here kept each evicted socket open for 5 s
        queue.asyncAfter(deadline: .now() + Self.helloTimeout) { [weak connection] in connection?.cancel() }
        connection.receive(minimumIncompleteLength: 1, maximumLength: PageRequest.maxLength) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            let pairing = self.pairing
            let kind = data.map { PageRequest.kind($0, pairing: pairing) } ?? .denied
            let host = LocalAddress.host()
            let livePorts = PhonePage.livePorts(active: self.activePorts.live, remembered: pairing.livePort, backup: pairing.backupLivePort)
            let body: Data, status: String
            switch kind {
            case .page:
                body = Data(PhonePage.html(livePorts: livePorts, stable: self.stablePorts).utf8)
                // 'self': the page puts itself in the phone's copy (cache.add).
                let policy = "default-src 'none'; img-src blob:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; worker-src 'self'; "
                    + "connect-src 'self' " + livePorts.map { "wss://\(host):\($0)" }.joined(separator: " ")
                    + "; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
                status = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\n"
                    + "Referrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\n"
                    + "Strict-Transport-Security: max-age=0\r\nContent-Security-Policy: \(policy)\r\n"
            case .worker:
                body = Data(PhonePage.worker.utf8)
                status = "HTTP/1.1 200 OK\r\nContent-Type: text/javascript; charset=utf-8\r\nCache-Control: no-store\r\n"
                    + "X-Content-Type-Options: nosniff\r\n"
            case .denied:
                body = Data()
                status = "HTTP/1.1 404 Not Found\r\n"
            }
            let head = status + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    // MARK: the live connection

    /// TLS failures that mean "the client did not accept our certificate". A client that only
    /// drops the session with no alert (URLSession and Safari do this) counts too. Plain http
    /// and random bytes give other codes and do not count.
    static func isTrustFailure(_ code: OSStatus) -> Bool {
        [errSSLPeerUnknownCA, errSSLPeerBadCert, errSSLPeerCertUnknown, errSSLPeerCertExpired,
         errSSLPeerCertRevoked, errSSLPeerUnsupportedCert, errSSLClosedNoNotify].contains(code)
    }

    /// A close with no alert is also what a port scan or a dropped preconnect looks like. The
    /// phone page tries again each few seconds, so it counts only when it comes twice in 15 s.
    private func confirmsTrustFailure(_ code: OSStatus) -> Bool {
        guard code == errSSLClosedNoNotify else { return true }
        let now = CFAbsoluteTimeGetCurrent()
        defer { lastSilentClose = now }
        return now - lastSilentClose < 15
    }

    /// Reports "the client did not accept our certificate", one time for each connection.
    /// Only a failure before the TLS session is ready counts. Plain http, random bytes or a
    /// connection that drops after the handshake are not a trust problem.
    private func noteTrust(_ error: NWError, on connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        guard waiting[id] != nil, !secured.contains(id),          // dropped() clears both: one call for each connection
              case .tls(let code) = error, Self.isTrustFailure(code), confirmsTrustFailure(code),
              CFAbsoluteTimeGetCurrent() - lastTrustReport > 1 else { return }
        lastTrustReport = CFAbsoluteTimeGetCurrent()
        DispatchQueue.main.async { [weak self] in self?.onTrustProblem?() }
    }

    private func acceptLive(_ connection: NWConnection) {
        // When the waiting slots are full, the oldest silent one goes, so a neighbour that holds
        // silent connections cannot lock the real phone out.
        if waiting.count >= Self.maxWaiting, let oldest = waitingOrder.first {
            waitingOrder.removeFirst()
            waiting[ObjectIdentifier(oldest)] = nil
            sessions[ObjectIdentifier(oldest)] = nil
            oldest.cancel()
        }
        let id = ObjectIdentifier(connection)
        waiting[id] = connection
        waitingOrder.append(connection)
        sessions[id] = PhoneSession(matches: { [weak self] in self?.pairing.matches($0) ?? false })
        connection.stateUpdateHandler = { [weak self, weak connection] newState in
            guard let self, let connection else { return }
            switch newState {
            case .ready:
                self.secured.insert(ObjectIdentifier(connection))
            case .failed(let error):
                self.noteTrust(error, on: connection)
                self.dropped(connection)
            case .cancelled:
                self.dropped(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.helloTimeout) { [weak self, weak connection] in
            guard let self, let connection, self.waiting[ObjectIdentifier(connection)] != nil else { return }
            connection.cancel()
        }
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            // The error can come here before the state handler sees it. Both paths report trust.
            if let self, let error { self.noteTrust(error, on: connection); self.dropped(connection) }
            guard let self, error == nil, let data,
                  let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                      as? NWProtocolWebSocket.Metadata,
                  metadata.opcode == .text, let text = String(data: data, encoding: .utf8)
            else { connection.cancel(); return }     // closed, too long, binary, or not text

            let id = ObjectIdentifier(connection)
            guard var session = self.sessions[id] else { connection.cancel(); return }
            if session.authorized, connection === self.phone, let report = PhoneMessage.wakeReport(text) {
                self.lock.withLock { self._wakeReport = report }
            }
            let action = session.receive(text)
            self.sessions[id] = session
            switch action {
            case .close:
                connection.cancel()
                return
            case .authorized:
                self.promote(connection)
            case .touch(let u, let v):
                if connection === self.phone { self.onTouch?((u, v)) }
            case .release:
                if connection === self.phone { self.onTouch?(nil) }
            case .pong(let pingID):
                self.lastPong = CFAbsoluteTimeGetCurrent()
                if let sent = self.pingSent.removeValue(forKey: pingID) {
                    let ms = (CFAbsoluteTimeGetCurrent() - sent) * 1000
                    self.lock.withLock { self._roundTripMs = ms }
                }
            case .ignore:
                break
            }
            self.receive(on: connection)
        }
    }

    /// A connection that said a correct hello becomes the phone. It replaces an older phone.
    private func promote(_ connection: NWConnection) {
        waiting[ObjectIdentifier(connection)] = nil
        waitingOrder.removeAll { $0 === connection }
        let old = phone
        phone = connection
        hellos += 1
        old?.cancel()
        gate.reset()
        onTouch?(nil)
        sendText(PhoneMessage.state("playing"), to: connection)
        startPing()
        set(.connected)
    }

    private func dropped(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        waiting[id] = nil
        sessions[id] = nil
        secured.remove(id)
        waitingOrder.removeAll { $0 === connection }
        guard connection === phone else { return }
        phone = nil
        gate.reset()
        pingTimer?.cancel(); pingTimer = nil
        lock.withLock { _roundTripMs = nil; _wakeReport = nil }
        onTouch?(nil)                               // a touch must not stay pressed
        if pageListener != nil { set(.waiting) }
    }

    private func sendText(_ text: String, to connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
    }

    private func startPing() {
        pingTimer?.cancel()
        pingSent = [:]
        lastPong = CFAbsoluteTimeGetCurrent()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, let phone = self.phone else { return }
            if self.muteForCheck { self.lastPong = CFAbsoluteTimeGetCurrent(); return }
            if CFAbsoluteTimeGetCurrent() - self.lastPong > Self.silenceLimit {
                phone.cancel()      // dropped() releases the touch and goes back to waiting
                return
            }
            self.pingID += 1
            if self.pingSent.count > 10 { self.pingSent = [:] }     // the phone stopped answering
            self.pingSent[self.pingID] = CFAbsoluteTimeGetCurrent()
            self.sendText(PhoneMessage.ping(id: self.pingID), to: phone)
        }
        timer.resume()
        pingTimer = timer
    }

    // MARK: the picture

    /// Call for each finished frame, from any thread.
    func submit(_ image: CGImage, split: FrameSplit) {
        queue.async { [self] in
            guard phone != nil, !muteForCheck else { return }
            let r = split.lower
            guard let lower = image.cropping(to: CGRect(x: r.x, y: r.y, width: r.width, height: r.height)) else { return }
            if let next = gate.offer(lower) { send(next) }
        }
    }

    private func send(_ image: CGImage) {
        guard let phone, let jpeg = Self.jpeg(image) else {
            gate.reset()
            return
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        phone.send(content: jpeg, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil, phone === self.phone else { return }
            if let next = self.gate.sendFinished() { self.send(next) }
        })
    }

    static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
