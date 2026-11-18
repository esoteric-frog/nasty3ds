import AppKit
import Nasty3DSKit

/// The game windows: which screen shows where, and the controls that show only while the pointer moves.
/// The windows have no visible title bar: the game picture fills them.
final class ScreenWindows: NSObject, NSWindowDelegate, NSToolbarDelegate {
    private static let splitKey = "splitScreens"
    private static let splitItem = NSToolbarItem.Identifier("split")
    private static let phoneItem = NSToolbarItem.Identifier("usePhone")

    private let window: NSWindow
    private let gameView: GameView
    private let lowerView = GameView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
    private var lowerWindow: NSWindow?
    private var toolbar: NSToolbar?       // on the window only while a game runs: the library has its own buttons
    private(set) var layout = ScreenLayout.oneWindow
    private var fullScreenCheckRan = false

    var onUsePhone: (() -> Void)?
    var gameRuns = false { didSet { apply() } }
    /// The phone shows the lower screen: the Mac shows the top screen only, and no second window.
    var phoneHasLower = false { didSet { apply() } }
    var canSplit: Bool { gameRuns && !phoneHasLower }
    var isSplit: Bool { layout == .twoWindows }

    init(window: NSWindow, gameView: GameView) {
        self.window = window
        self.gameView = gameView
        super.init()
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.delegate = self
        let toolbar = NSToolbar(identifier: "game")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        self.toolbar = toolbar
        window.toolbarStyle = .unified
        lowerView.mode = .lowerOnly
        gameView.companion = lowerView
        gameView.hoverHold = Self.titleBar(of: window)
        gameView.onHover = { [weak self] _ in self?.showChrome() }
    }

    /// The view that holds the window buttons and the toolbar. AppKit has no public name for it.
    private static func titleBar(of window: NSWindow) -> NSView? {
        window.standardWindowButton(.closeButton)?.superview?.superview
    }

    /// Diagnosis aid: N3_SHOW_CONTROLS=1 keeps the controls on screen, for a picture with no pointer. Not in the app bundle.
    private static let controlsStay = Bundle.main.bundleURL.pathExtension != "app"
        && ProcessInfo.processInfo.environment["N3_SHOW_CONTROLS"] != nil

    /// In a game, the window buttons and the toolbar show only while the pointer moves. The library shows them always.
    private func showChrome() {
        GameView.fade([Self.titleBar(of: window)], visible: !gameRuns || gameView.hovering || Self.controlsStay)
    }

    @objc func toggleSplit(_ sender: Any?) {
        guard canSplit else { return }
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: Self.splitKey), forKey: Self.splitKey)
        apply()
    }

    @objc private func usePhone(_ sender: Any?) { onUsePhone?() }

    private func apply() {
        let old = layout
        layout = ScreenLayout.resolve(gameRuns: gameRuns, phoneHasLower: phoneHasLower,
                                      wantsSplit: UserDefaults.standard.bool(forKey: Self.splitKey))
        if (window.toolbar != nil) != gameRuns { window.toolbar = gameRuns ? toolbar : nil }
        showChrome()
        if layout != old { gameView.releaseTouch(); lowerView.releaseTouch() }      // a touch must not stay down on a screen that moves
        setMainMode(layout == .oneWindow ? .both : .topOnly)
        if layout == .twoWindows { showLower() } else { hideLower() }
        if let item = window.toolbar?.items.first(where: { $0.itemIdentifier == Self.splitItem }) { style(item) }
    }

    /// Call after the saved window frame is back. A window that closed with only the top screen
    /// opens again with room for the two screens, at the same width.
    func restoreShape() { shape(.both, animate: false) }

    /// Keeps the window width; the height follows the screens that show.
    private func setMainMode(_ mode: GameView.Mode) {
        guard gameView.mode != mode else { return }
        gameView.mode = mode
        shape(mode, animate: true)
    }

    private func shape(_ mode: GameView.Mode, animate: Bool) {
        let ratio: CGFloat = mode == .topOnly ? 240.0 / 400.0 : 480.0 / 400.0
        window.contentAspectRatio = NSSize(width: 400, height: 400 * ratio)
        guard !window.styleMask.contains(.fullScreen) else { return }
        var content = window.contentRect(forFrameRect: window.frame)
        let top = content.maxY
        content.size.height = content.width * ratio
        content.origin.y = top - content.height
        window.setFrame(window.frameRect(forContentRect: content), display: true, animate: animate)
    }

    // MARK: the window for the lower screen

    private func showLower() {
        if lowerWindow == nil {
            let w = NSWindow(contentRect: lowerView.frame, styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Lower Screen"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.backgroundColor = .black
            w.isReleasedWhenClosed = false
            w.delegate = self
            // No title bar and no button: each touch on the lower screen must reach the game.
            // The button in the main window, Command-D or Command-W puts the screens back in one window.
            Self.titleBar(of: w)?.isHidden = true
            w.contentView = lowerView
            w.contentAspectRatio = NSSize(width: 320, height: 240)
            w.contentMinSize = NSSize(width: 320, height: 240)
            w.collectionBehavior = [.fullScreenPrimary]
            if !w.setFrameUsingName("LowerWindow") {       // first time: directly below the top screen
                let main = window.frame, size = NSSize(width: main.width * 0.8, height: main.width * 0.6)
                let origin = NSPoint(x: main.midX - size.width / 2, y: main.minY - size.height - 8)
                if let visible = window.screen?.visibleFrame, origin.y >= visible.minY {
                    w.setFrame(NSRect(origin: origin, size: size), display: false)
                } else { w.center() }
            }
            w.setFrameAutosaveName("LowerWindow")
            lowerWindow = w
        }
        guard let lowerWindow, !lowerWindow.isVisible else { return }
        lowerWindow.orderFront(nil)        // the main window stays the key window
        lowerWindow.makeFirstResponder(lowerView)
        // Diagnosis aid: N3_FULLSCREEN_LOWER=1 puts the lower window in full screen after 4 s. Not in the app bundle.
        if Bundle.main.bundleURL.pathExtension != "app", !fullScreenCheckRan, ProcessInfo.processInfo.environment["N3_FULLSCREEN_LOWER"] != nil {
            fullScreenCheckRan = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [self] in
                toggleLowerFullScreen(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    print("[n3] lower window: fullScreen=\(lowerWindow.styleMask.contains(.fullScreen)) frame=\(lowerWindow.frame) screen=\(lowerWindow.screen?.frame ?? .zero) ")
                    self.toggleSplit(nil)        // join the screens from full screen
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        print("[n3] lower window after join: fullScreen=\(lowerWindow.styleMask.contains(.fullScreen)) visible=\(lowerWindow.isVisible) layout=\(self.layout)")
                        self.toggleSplit(nil)    // leave the stored choice as it was
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                            print("[n3] lower window after second split: fullScreen=\(lowerWindow.styleMask.contains(.fullScreen)) visible=\(lowerWindow.isVisible) frame=\(lowerWindow.frame)")
                        }
                    }
                }
            }
        }
    }

    /// A window in full screen has its own Space. It leaves full screen first, then it hides
    /// (windowDidExitFullScreen): a hidden full-screen window would leave an empty Space behind.
    private func hideLower() {
        guard let lowerWindow else { return }
        if lowerWindow.styleMask.contains(.fullScreen) { lowerWindow.toggleFullScreen(nil) } else { lowerWindow.orderOut(nil) }
    }

    var lowerIsFullScreen: Bool { lowerWindow?.styleMask.contains(.fullScreen) ?? false }

    /// The lower window has no green button, so the View menu has this command.
    @objc func toggleLowerFullScreen(_ sender: Any?) {
        guard isSplit else { return }
        lowerWindow?.toggleFullScreen(nil)
    }

    /// The top screen goes to full screen: the lower screen does the same when it is on another display.
    func windowDidEnterFullScreen(_ notification: Notification) {
        guard notification.object as? NSWindow === window, isSplit, let lowerWindow,
              lowerWindow.screen != window.screen, !lowerIsFullScreen else { return }
        lowerWindow.toggleFullScreen(nil)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard let lowerWindow else { return }
        if notification.object as? NSWindow === lowerWindow {
            if layout != .twoWindows { lowerWindow.orderOut(nil) }
        } else if lowerIsFullScreen, lowerWindow.screen != window.screen {
            lowerWindow.toggleFullScreen(nil)
        }
    }

    // MARK: window delegate

    /// Close on the lower window puts the screens back in one window. The game continues.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === lowerWindow else { return true }
        toggleSplit(nil)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === window { lowerWindow?.orderOut(nil) }    // the app quits with its last window
    }

    // MARK: toolbar (it floats on the game picture, with no bar behind it)

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, Self.splitItem, Self.phoneItem] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, Self.splitItem, Self.phoneItem] }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.isBordered = true
        item.target = self
        item.autovalidates = false
        switch identifier {
        case Self.splitItem:
            item.action = #selector(toggleSplit(_:))
            style(item)
        case Self.phoneItem:
            item.label = "Use Phone"
            item.toolTip = "Use Phone for Lower Screen"
            item.image = NSImage(systemSymbolName: "iphone", accessibilityDescription: "Use Phone for Lower Screen")
            item.action = #selector(usePhone(_:))
        default: return nil
        }
        return item
    }

    private func style(_ item: NSToolbarItem) {
        let text = phoneHasLower ? "The Lower Screen Is on the Phone"
            : isSplit ? "Show Both Screens in One Window" : "Show the Lower Screen in Its Own Window"
        item.label = isSplit ? "Join Screens" : "Split Screens"
        item.toolTip = text
        item.image = NSImage(systemSymbolName: isSplit ? "rectangle.split.1x2" : "macwindow.on.rectangle", accessibilityDescription: text)
        item.isEnabled = canSplit
    }
}
