import AppKit
import CoreImage
import Nasty3DSKit

/// The Mac UI for the phone screen: toolbar button, pairing sheet, window shape, Settings window.
final class PhoneController: NSObject, NSToolbarDelegate {
    private static let toolbarItem = NSToolbarItem.Identifier("usePhone")
    /// The fingerprint of the certificate that the user put on the iPhone. A new certificate
    /// (the Mac got a new name) has another fingerprint, so the setup shows again, also after a restart.
    private static let setupDoneKey = "phoneCertificateFingerprint"

    let server = PhoneServer()
    private let window: NSWindow
    private let gameView: GameView
    private var gamePath: String?
    private var state = PhoneServer.State.stopped

    private var sheet: NSWindow?
    private var setupView: NSView?
    private var pairView: NSView?
    private var sendButton: NSButton?
    private var trustNote: NSTextField?
    private var pairTrustNote: NSTextField?

    private static func makeTrustNote(_ text: String) -> NSTextField {
        let note = label(text, style: .body)
        note.textColor = .systemOrange
        note.isHidden = true
        return note
    }
    private var qrView: NSImageView?
    private var settingsWindow: NSWindow?
    private var settingsText: NSTextField?

    init(window: NSWindow, gameView: GameView) {
        self.window = window
        self.gameView = gameView
        super.init()
        let toolbar = NSToolbar(identifier: "game")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        server.onStateChange = { [weak self] in self?.stateChanged($0) }
        server.onTouch = { Emulator.shared.touch = $0 }
        server.onTrustProblem = { [weak self] in self?.trustProblem() }
        Emulator.shared.onFrame = { [server] image, split in server.submit(image, split: split) }
        Emulator.shared.phoneStats = { [server] in
            (server.roundTripMs.map { String(format: "phone=%.0fms", $0) } ?? "phone=off") + " wake=" + (server.wakeReport ?? "-")
        }
    }

    var statusText: String {
        switch state {
        case .connected: return server.roundTripMs.map { String(format: "Phone connected · %.0f ms", $0) } ?? "Phone connected"
        case .waiting, .starting: return "Phone not connected"
        case .stopped, .failed: return ""
        }
    }

    /// The iPhone needs the certificate one time, and again after the Mac made a new one.
    private var needsSetup: Bool {
        guard let current = PhoneTLS.fingerprint() else { return true }
        return UserDefaults.standard.string(forKey: Self.setupDoneKey) != current
    }

    private func markSetupDone() { UserDefaults.standard.set(PhoneTLS.fingerprint(), forKey: Self.setupDoneKey) }

    // MARK: game life cycle

    func gameStarted(path: String) {
        gamePath = path
        // The sheet opens by itself for a game that uses the phone. N3_USE_PHONE=1 does the same for a check.
        if server.pairing.usesPhone(game: path) || ProcessInfo.processInfo.environment["N3_USE_PHONE"] == "1" { usePhone(nil) }
    }

    func gameStopped() {
        gamePath = nil
        closeSheet()
        server.stop()
    }

    // MARK: commands

    @objc func usePhone(_ sender: Any?) {
        guard gamePath != nil else { return }
        server.start()
        if state != .connected { showSheet() }
    }

    @objc private func playWithoutPhone(_ sender: Any?) {
        if let gamePath { server.setUsesPhone(false, game: gamePath) }
        closeSheet()
        server.stop()
    }

    @objc private func cancelSheet(_ sender: Any?) {
        closeSheet()
        if state != .connected { server.stop() }
    }

    @objc func sendCertificate(_ sender: Any?) {
        guard FileManager.default.fileExists(atPath: PhoneTLS.caFile.path),
              let airDrop = NSSharingService(named: .sendViaAirDrop) else { return }
        airDrop.perform(withItems: [PhoneTLS.caFile])
    }

    @objc private func setupDone(_ sender: Any?) {
        markSetupDone()
        refreshSheet()
    }

    @objc private func setupAgain(_ sender: Any?) {
        UserDefaults.standard.removeObject(forKey: Self.setupDoneKey)
        refreshSheet()
    }

    /// The iPhone reached this Mac but did not accept its certificate: say so in the sheet.
    /// It changes no stored setting: any device on the Wi-Fi can cause this report.
    private func trustProblem() {
        guard sheet != nil, state != .connected else { return }
        for note in [trustNote, pairTrustNote] { note?.isHidden = false }
        refreshSheet()
    }

    // MARK: state

    private func stateChanged(_ new: PhoneServer.State) {
        state = new
        switch new {
        case .waiting:
            setMode(.both)
            refreshSheet()
        case .connected:
            if let gamePath { server.setUsesPhone(true, game: gamePath) }
            markSetupDone()     // a connection proves the setup
            closeSheet()
            setMode(.topOnly)
        case .stopped:
            setMode(.both)
        case .failed(let message):
            closeSheet()
            setMode(.both)
            let alert = NSAlert()
            alert.messageText = "The phone screen cannot start"
            alert.informativeText = message + "\nThe game continues with both screens on this Mac."
            alert.beginSheetModal(for: window)
        case .starting:
            break
        }
        refreshSettings()
    }

    /// Keeps the window width; the height follows the screens that show.
    private func setMode(_ mode: GameView.Mode) {
        guard gameView.mode != mode else { return }
        gameView.mode = mode
        let ratio: CGFloat = mode == .topOnly ? 240.0 / 400.0 : 480.0 / 400.0
        window.contentAspectRatio = NSSize(width: 400, height: 400 * ratio)
        guard !window.styleMask.contains(.fullScreen) else { return }
        var content = window.contentRect(forFrameRect: window.frame)
        let top = content.maxY
        content.size.height = content.width * ratio
        content.origin.y = top - content.height
        window.setFrame(window.frameRect(forContentRect: content), display: true, animate: true)
    }

    // MARK: pairing sheet

    private static func label(_ text: String, style: NSFont.TextStyle, secondary: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .preferredFont(forTextStyle: style)
        if secondary { label.textColor = .secondaryLabelColor }
        label.preferredMaxLayoutWidth = 320
        return label
    }

    private static func column(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    private func makeSetupView() -> NSView {
        let send = NSButton(title: "Send Certificate to iPhone…", target: self, action: #selector(sendCertificate(_:)))
        send.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
        send.imagePosition = .imageLeading
        send.controlSize = .large
        sendButton = send
        let steps = [
            "1. Click “Send Certificate to iPhone…” below and select your iPhone in AirDrop. On the iPhone, tap Accept.",
            "2. On the iPhone, open Settings. Tap “Profile Downloaded” near the top, then tap Install and type your passcode.",
            "3. In Settings, go to General > About. Scroll to the end and tap Certificate Trust Settings. Turn on “Nasty3DS Local”.",
            "4. Come back to this Mac and click “Done, Show QR Code”.",
        ].map { Self.label($0, style: .body) }
        let older = Self.label("If the iPhone has an older “Nasty3DS Local” profile, remove it first: Settings > General > VPN & Device Management.", style: .footnote, secondary: true)
        let done = NSButton(title: "Done, Show QR Code", target: self, action: #selector(setupDone(_:)))
        done.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelSheet(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cancel, done])
        let note = Self.makeTrustNote("Your iPhone reached this Mac but did not accept its certificate. Do the steps again, and turn on trust for the newest “Nasty3DS Local” entry. If Safari shows a warning page, do not continue past it.")
        trustNote = note
        return Self.column([
            Self.label("Set up your iPhone", style: .title2),
            note,
            Self.label("You do this one time. It lets the iPhone connect to this Mac safely and keep its display on.", style: .body, secondary: true),
            Self.column(steps, spacing: 10), older, send, buttons,
        ], spacing: 16)
    }

    private func makePairView() -> NSView {
        let qr = NSImageView()
        qr.imageScaling = .scaleProportionallyUpOrDown
        qr.wantsLayer = true
        qr.layer?.cornerRadius = 12
        qr.layer?.cornerCurve = .continuous
        qr.layer?.masksToBounds = true
        qr.setAccessibilityLabel("QR code for the phone screen")
        qrView = qr
        let pairNote = Self.makeTrustNote("Your iPhone reached this Mac but did not accept its certificate. Click “Set Up iPhone Again…”.")
        pairTrustNote = pairNote
        let again = NSButton(title: "Set Up iPhone Again…", target: self, action: #selector(setupAgain(_:)))
        again.isBordered = false
        again.contentTintColor = .linkColor
        let without = NSButton(title: "Play Without Phone", target: self, action: #selector(playWithoutPhone(_:)))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelSheet(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [again, NSView(), without, cancel])
        let stack = Self.column([
            Self.label("Point your iPhone camera at this code", style: .title2),
            Self.label("The lower screen moves to the iPhone. This sheet closes by itself.", style: .body, secondary: true),
            qr, pairNote,
            Self.label("For full screen on the iPhone with no Safari bars: in Safari, tap Share, then Add to Home Screen. Open the game from that icon the next time. You do not scan again.", style: .footnote, secondary: true),
            Self.label("No Wi-Fi? On the iPhone, turn on Personal Hotspot. Then join that network from this Mac, or connect the iPhone with a cable.", style: .footnote, secondary: true),
            buttons,
        ], spacing: 16)
        NSLayoutConstraint.activate([
            qr.widthAnchor.constraint(equalToConstant: 232), qr.heightAnchor.constraint(equalToConstant: 232),
            qr.centerXAnchor.constraint(equalTo: stack.centerXAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return stack
    }

    private func showSheet() {
        guard sheet == nil else { refreshSheet(); return }
        let setup = makeSetupView(), pair = makePairView()
        let container = NSStackView(views: [setup, pair])
        container.orientation = .vertical
        container.alignment = .leading
        container.edgeInsets = NSEdgeInsets(top: 28, left: 28, bottom: 22, right: 28)
        container.detachesHiddenViews = true
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        panel.contentView = container
        sheet = panel; setupView = setup; pairView = pair
        refreshSheet()
        window.beginSheet(panel)
    }

    private func refreshSheet() {
        guard let sheet else { return }
        let ready = state == .waiting
        let setup = needsSetup
        setupView?.isHidden = !setup
        pairView?.isHidden = setup
        sendButton?.isEnabled = ready
        // The address holds the secret. It shows only as this code, never as text or in a log.
        qrView?.image = ready && !setup ? Self.qrCode(server.url) : nil
        sheet.contentView?.layoutSubtreeIfNeeded()
        if let size = sheet.contentView?.fittingSize { sheet.setContentSize(size) }
        snapshotIfAsked(sheet.contentView, name: setup ? "sheet-setup" : (ready ? "sheet-qr" : "sheet-starting"))
    }

    /// Diagnosis aid: N3_SNAPSHOT_DIR=/folder writes a PNG of the sheet and the Settings window there.
    private func snapshotIfAsked(_ view: NSView?, name: String) {
        // Not in the app bundle: the picture holds the QR code with the pairing secret.
        guard Bundle.main.bundleURL.pathExtension != "app",
              let folder = ProcessInfo.processInfo.environment["N3_SNAPSHOT_DIR"], let view else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
    }

    private func closeSheet() {
        guard let panel = sheet else { return }
        window.endSheet(panel)
        sheet = nil; setupView = nil; pairView = nil; sendButton = nil; qrView = nil; trustNote = nil; pairTrustNote = nil
    }

    static func qrCode(_ text: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let code = filter.outputImage else { return nil }
        // A white margin (the quiet zone) so the camera reads the code in dark mode too.
        let quiet = code.extent.insetBy(dx: -4, dy: -4)
        let output = code.composited(over: CIImage(color: .white).cropped(to: quiet))
            .transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, Self.toolbarItem] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, Self.toolbarItem] }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard identifier == Self.toolbarItem else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Use Phone"
        item.toolTip = "Use Phone for Lower Screen"
        item.image = NSImage(systemSymbolName: "iphone", accessibilityDescription: "Use Phone for Lower Screen")
        item.isBordered = true
        item.target = self
        item.action = #selector(usePhone(_:))
        return item
    }

    // MARK: Settings window

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let text = Self.label("", style: .body)
            text.isSelectable = true
            let send = NSButton(title: "Send Certificate to iPhone…", target: self, action: #selector(sendCertificate(_:)))
            let forget = NSButton(title: "Forget Phone…", target: self, action: #selector(forgetPhone(_:)))
            let stack = Self.column([Self.label("Phone", style: .title2), text, NSStackView(views: [send, forget])], spacing: 14)
            stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 200),
                                 styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "Settings"
            panel.contentView = stack
            panel.isReleasedWhenClosed = false
            panel.center()
            settingsWindow = panel; settingsText = text
        }
        refreshSettings()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func refreshSettings() {
        guard let settingsText else { return }
        let line = statusText.isEmpty ? "The phone screen is off." : statusText + "."
        var lines = [line, "Games that use the phone: \(server.pairing.phoneGames.count)."]
        if let fingerprint = PhoneTLS.fingerprint() {
            lines.append("Certificate fingerprint (SHA-256):\n\(fingerprint)")
        }
        settingsText.stringValue = lines.joined(separator: "\n")
        if let panel = settingsWindow, let size = panel.contentView?.fittingSize { panel.setContentSize(size) }
        snapshotIfAsked(settingsWindow?.contentView, name: "settings")
    }

    @objc private func forgetPhone(_ sender: Any?) {
        guard let settingsWindow else { return }
        let alert = NSAlert()
        alert.messageText = "Forget this phone?"
        alert.informativeText = "The page saved on the phone stops working. You scan a new QR code the next time."
        alert.addButton(withTitle: "Forget Phone")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: settingsWindow) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.server.forget()
            self?.refreshSettings()
        }
    }
}
