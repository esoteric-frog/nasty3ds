import AppKit
import CN3Host
import Nasty3DSKit

/// Local play: the 3DS "local wireless" between Nasty3DS apps on one network (a trade, a battle).
/// One player hosts a room. The others find it by Bonjour and join it: no address to type.
///
/// Threat model: while a room is open, any device on the local network can connect to its UDP
/// port and send game packets. So the room is open only after the user selects "Host a Room",
/// the status line says that it is open, and it closes with the game. Nothing is open by default.
// ponytail: NetService is deprecated but it resolves a service to an address in a few lines.
// Change to NWBrowser + NWConnection if Apple removes it.
final class LocalPlay: NSObject, NSMenuDelegate, NetServiceBrowserDelegate, NetServiceDelegate {
    static let serviceType = "_nasty3ds._udp."
    static let firstPort: UInt16 = 24872       // the engine's usual room port
    static let maxPlayers: UInt32 = 4

    let nickname = LocalPlayText.nickname(from: Host.current().localizedName ?? "", suffix: Int.random(in: 0...99))
    var gameRuns = false { didSet { if !gameRuns { closeAdvert() } } }

    private var advert: NetService?
    private var browser: NetServiceBrowser?
    private var found: [NetService] = []
    private var resolving: NetService?
    private var hosting = false
    private let work = DispatchQueue(label: "local-play")     // room calls that can wait on the network
    private var joining = false        // a join is in progress on the work queue; the engine is busy, do not ask it
    private var inRoom = false         // the user asked for a room; the engine's state says how it goes

    // MARK: actions

    @objc func host(_ sender: Any?) {
        guard gameRuns, !joining else { return }
        for port in Self.firstPort..<(Self.firstPort + 8) {
            let result = n3_room_host(nickname, port, Self.maxPlayers)
            if result == 3 { continue }       // the port is in use: try the next one
            guard result == 0 else { return fail(result) }
            advert?.stop()       // a second Host after a lost room: the old advert goes
            hosting = true; inRoom = true
            let service = NetService(domain: "", type: Self.serviceType, name: nickname, port: Int32(port))
            service.publish()
            advert = service
            Emulator.shared.log("[n3] local play: hosting on port \(port)")
            return
        }
        fail(3)
    }

    @objc func join(_ sender: NSMenuItem) {
        guard gameRuns, !joining, let service = sender.representedObject as? NetService else { return }
        let old = resolving; resolving = nil; old?.stop()     // nil first: stop() calls netServiceDidStop at once
        resolving = service
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    @objc func leave(_ sender: Any?) {
        n3_room_leave()
        closeAdvert()
        inRoom = false
    }

    /// Call before the game stops: the engine closes the room with the game.
    func gameStopped() {
        let old = resolving; resolving = nil; old?.stop()      // a late answer must not join a room in the next game
        work.sync {}                            // a join that is in progress ends before the engine unloads
        if gameRuns { n3_room_leave() }
        gameRuns = false
        inRoom = false
    }

    private func closeAdvert() {
        advert?.stop(); advert = nil
        hosting = false
    }

    /// For the status line under the game. Empty when no room is in use.
    var statusText: String {
        guard gameRuns, inRoom else { return "" }
        if joining { return LocalPlayText.status(state: 1, hosting: false, players: 0) }
        if hosting, n3_room_state() <= 0 {      // the host lost its own place: the room must not stay open with no sign
            leave(nil)
            return "Local play: the room closed"
        }
        return LocalPlayText.status(state: Int(n3_room_state()), hosting: hosting, players: Int(n3_room_members(nil, 0)))
    }

    /// Diagnosis aid, for a check with two apps on one Mac and no clicks:
    /// N3_ROOM=host, or N3_ROOM=join:<IPv4 address>:<port>. It starts 5 s after the game.
    func startIfAsked() {
        // Not in the app bundle: a room must never open with no click in an app that people use.
        guard Bundle.main.bundleURL.pathExtension != "app",
              let order = ProcessInfo.processInfo.environment["N3_ROOM"] else { return }
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [self] _ in
            guard gameRuns else { return }
            var names = [CChar](repeating: 0, count: 512)
            let count = n3_room_members(&names, UInt(names.count))
            Emulator.shared.log("[n3] local play state=\(n3_room_state()) players=\(count) [\(String(cString: names).replacingOccurrences(of: "\n", with: "|"))]")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [self] in
            let parts = order.split(separator: ":").map(String.init)
            if order == "host" { host(nil) }
            else if parts.count == 3, parts[0] == "join", let port = UInt16(parts[2]) {
                inRoom = true
                Emulator.shared.log("[n3] local play: join result \(n3_room_join(nickname, parts[1], port))")
            }
        }
    }

    private func fail(_ code: Int32) {
        let alert = NSAlert()
        alert.messageText = "Local play did not start"
        alert.informativeText = switch code {
        case -1: "This copy of the engine has no local play."
        case 2: "Start a game first."
        case 3: "The network ports for local play are in use. Close other 3DS emulators, then try again."
        default: "The network did not start."
        }
        alert.runModal()
    }

    // MARK: finding other players

    private func startBrowsing() {
        guard browser == nil else { return }
        let b = NetServiceBrowser()
        b.delegate = self
        b.searchForServices(ofType: Self.serviceType, inDomain: "")
        browser = b
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        if !found.contains(service) { found.append(service) }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        found.removeAll { $0 == service }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard sender === resolving else { return }
        // The engine's network code speaks IPv4 only. This call can come more than one time as
        // addresses arrive: wait for an IPv4 address, or for the 5 s limit (didNotResolve).
        // Only an address on the local network: an advert must not send this Mac to the internet.
        guard let address = sender.addresses?.lazy.compactMap(Self.ipv4).first(where: LocalPlayText.isLocalAddress),
              (1...65535).contains(sender.port) else { return }
        resolving = nil        // before stop(): it calls netServiceDidStop at once
        sender.stop()
        n3_room_leave()        // a room that this Mac hosts closes first: it must not stay open with no sign
        closeAdvert()
        inRoom = true
        let nickname = nickname, port = UInt16(sender.port)
        // The join waits up to 5 s for a Mac that does not answer. Not on the main thread.
        joining = true
        work.async {
            let result = n3_room_join(nickname, address, port)
            DispatchQueue.main.async { [self] in
                joining = false
                guard gameRuns else { return }       // the game stopped in the meantime: say nothing
                Emulator.shared.log("[n3] local play: joining a room, result \(result)")
                if result != 0 { inRoom = false; fail(result) }
            }
        }
    }

    /// The 5 s limit ended with no IPv4 address.
    func netServiceDidStop(_ sender: NetService) {
        guard sender === resolving else { return }
        resolving = nil
        couldNotReach(sender.name)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        guard sender === resolving else { return }
        resolving = nil
        couldNotReach(sender.name)
    }

    private func couldNotReach(_ name: String) {
        let alert = NSAlert()
        alert.messageText = "Nasty3DS cannot reach \(name)"
        alert.informativeText = "Make sure the two Macs are on the same Wi-Fi network, then try again."
        alert.runModal()
    }

    /// "192.168.1.20" from a socket address, or nil when it is not IPv4.
    static func ipv4(_ data: Data) -> String? {
        data.withUnsafeBytes { raw -> String? in
            guard raw.count >= MemoryLayout<sockaddr_in>.size,
                  raw.load(as: sockaddr.self).sa_family == sa_family_t(AF_INET) else { return nil }
            var address = raw.load(as: sockaddr_in.self).sin_addr
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &address, &text, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
            return String(cString: text)
        }
    }

    // MARK: the menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        startBrowsing()
        menu.removeAllItems()
        menu.autoenablesItems = false
        func item(_ title: String, _ action: Selector?, enabled: Bool = true) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            i.isEnabled = enabled && action != nil
            return i
        }
        guard gameRuns else {
            menu.addItem(item("Start a game first", nil))
            return
        }
        if joining {
            menu.addItem(item("Joining…", nil))
            return
        }
        let state = n3_room_state()
        if !inRoom || state <= 0 {
            menu.addItem(item("Host a Room", #selector(host(_:))))
            menu.addItem(.separator())
            let others = found.filter { $0.name != nickname }
            if others.isEmpty { menu.addItem(item("No rooms found on this network", nil)) }
            for service in others {
                let i = item("Join \(service.name)", #selector(join(_:)))
                i.representedObject = service
                menu.addItem(i)
            }
        } else {
            var names = [CChar](repeating: 0, count: 512)
            let count = n3_room_members(&names, UInt(names.count))
            menu.addItem(item(LocalPlayText.status(state: Int(state), hosting: hosting, players: Int(count))
                .replacingOccurrences(of: "Local play: ", with: "").capitalizedFirst, nil))
            for name in String(cString: names).split(separator: "\n") { menu.addItem(item("  \(name)", nil)) }
            menu.addItem(.separator())
            menu.addItem(item(hosting ? "Close Room" : "Leave Room", #selector(leave(_:))))
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
