import AppKit
import Nasty3DSKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var window: NSWindow!
    private let gameView = GameView(frame: NSRect(x: 0, y: 0, width: 800, height: 960))
    private var statusTimer: Timer?
    private var phone: PhoneController!
    private var screens: ScreenWindows!
    private let localPlay = LocalPlay()
    private let homeView = HomeView(frame: NSRect(x: 0, y: 0, width: 800, height: 960))
    private let library = GameLibrary(folder: Emulator.supportDir)
    private var gameRuns = false
    private var audio: AudioOut?
    private let padInput = PadInput()
    private var controllerName: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMenu()
        window = NSWindow(contentRect: gameView.frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Nasty3DS"
        window.contentView = gameView
        screens = ScreenWindows(window: window, gameView: gameView)
        screens.onUsePhone = { [weak self] in self?.usePhone(nil) }
        phone = PhoneController(window: window)
        phone.onLowerOnPhone = { [weak self] in self?.screens.phoneHasLower = $0 }
        window.collectionBehavior = [.fullScreenPrimary]
        window.setFrameAutosaveName("GameWindow")
        screens.restoreShape()
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(gameView)
        NSApp.activate(ignoringOtherApps: true)

        if ProcessInfo.processInfo.environment["N3_RENDERER"] == "Software" { Emulator.shared.renderer = "Software" }
        homeView.onPlay = { [weak self] game in self?.start(game.url.path) }
        homeView.onAdd = { [weak self] in self?.openGame(nil) }
        homeView.onDrop = { [weak self] files in self?.addGames(files) }
        homeView.onShowInFinder = { NSWorkspace.shared.activateFileViewerSelecting([$0.url]) }
        homeView.onTrash = { [weak self] game in self?.trash(game) }
        if CommandLine.arguments.count > 1 {
            start(CommandLine.arguments[1])
        } else {
            showLibrary()
        }
        cycleIfAsked()
    }

    // MARK: the library

    private func showLibrary() {
        window.title = "Nasty3DS"
        window.contentView = homeView
        // The library needs room for the large icon and one row of games.
        window.contentMinSize = NSSize(width: 560, height: 672)
        if let size = window.contentView?.frame.size, size.width < 560 {
            window.setContentSize(NSSize(width: 720, height: 864))
            window.center()
        }
        homeView.show(library.games())
        homeView.snapshotIfAsked()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(closeGame(_:)) || item.action == #selector(usePhone(_:)) { return gameRuns }
        if item.action == #selector(toggleLowerFullScreen(_:)) {
            item.title = screens.lowerIsFullScreen ? "Exit Full Screen for Lower Screen" : "Enter Full Screen for Lower Screen"
            return screens.isSplit
        }
        if item.action == #selector(toggleSplit(_:)) {
            item.state = screens.isSplit ? .on : .off
            return screens.canSplit
        }
        return true
    }

    /// Game > Show Library: ends the game (the engine writes the save) and goes back to the games.
    @objc func closeGame(_ sender: Any?) {
        guard gameRuns else { return }
        gameRuns = false
        statusTimer?.invalidate(); statusTimer = nil
        localPlay.gameStopped()
        phone.gameStopped()
        Emulator.shared.stop()
        audio = nil
        gameView.status = ""
        screens.gameRuns = false
        showLibrary()
    }

    /// Moves each file into the library folder. The original does not stay behind.
    private func addGames(_ files: [URL]) {
        var problems: [String] = [], left: [String] = []
        for file in files {
            do {
                let placed = try library.add(file)
                if placed.path != file.path, FileManager.default.fileExists(atPath: file.path) { left.append(file.path) }
            } catch { problems.append((error as? GameLibrary.Failure)?.message ?? error.localizedDescription) }
        }
        if !gameRuns { homeView.show(library.games()) }
        guard !problems.isEmpty || !left.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = problems.isEmpty ? "The game is in your library" : "Nasty3DS could not add a game"
        alert.informativeText = (problems + left.map { "The original file is still at \($0). You can delete it." }).joined(separator: "\n\n")
        alert.runModal()
    }

    private func trash(_ game: LibraryGame) {
        let alert = NSAlert()
        alert.messageText = "Move “\(game.title)” to the Trash?"
        alert.informativeText = "The game file goes to the Trash. Your save data stays on this Mac."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? FileManager.default.trashItem(at: game.url, resultingItemURL: nil)
        homeView.show(library.games())
    }

    /// Diagnosis aid: N3_CYCLE=1 ends the game after 10 s and starts it again 3 s later. Not in the app bundle.
    private func cycleIfAsked() {
        guard Bundle.main.bundleURL.pathExtension != "app", ProcessInfo.processInfo.environment["N3_CYCLE"] != nil,
              CommandLine.arguments.count > 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [self] in
            closeGame(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in start(CommandLine.arguments[1]) }
        }
    }

    @objc func openGame(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.message = "Select 3DS game files to add. Nasty3DS moves them into its library."
        panel.prompt = "Add"
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = ["3ds", "cci", "cxi", "zcci", "3dsx", "cia"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK { addGames(panel.urls) }
    }

    private func start(_ path: String) {
        let emulator = Emulator.shared
        emulator.view = gameView
        phone.gameStopped()     // a second start ends the old phone session
        localPlay.gameStopped()
        // A copy of the save, before the engine can touch it. Nothing happens when this save has a copy.
        let file = URL(fileURLWithPath: path)
        if let info = GameFile.read(file) {
            library.backUpSave(programID: info.programID, title: info.title ?? file.deletingPathExtension().lastPathComponent)
        }
        do {
            try emulator.start(gamePath: path)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Nasty3DS cannot start this game"
            alert.informativeText = (error as? EmulatorError)?.message ?? error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        gameRuns = true
        library.markPlayed(file)
        window.contentMinSize = NSSize(width: 320, height: 192)
        window.contentView = gameView
        window.makeFirstResponder(gameView)
        screens.gameRuns = true
        audio = try? AudioOut(sampleRate: emulator.sampleRate)
        emulator.onAudio = { [weak self] samples, frames in self?.audio?.enqueue(samples, frames: frames) }
        emulator.audioFill = { [weak self] in self?.audio?.fillFraction ?? 0.5 }
        emulator.audioBufferSeconds = AudioOut.bufferSeconds
        emulator.audioStats = { [weak self] in self?.audio?.takeStats() ?? "" }
        padInput.onChange = { [weak self] snapshot, name in
            Emulator.shared.pad = snapshot
            self?.controllerName = name
        }
        padInput.start()
        window.title = GameFile.read(file)?.title ?? file.deletingPathExtension().lastPathComponent
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let pad = self.controllerName ?? "No controller (keyboard works)"
            let parts = [String(format: "%.0f fps", Emulator.shared.measuredFPS), pad, self.phone.statusText, self.localPlay.statusText].filter { !$0.isEmpty }
            self.gameView.status = parts.joined(separator: " · ")
        }
        phone.gameStarted(path: path)
        localPlay.gameRuns = true
        localPlay.startIfAsked()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        localPlay.gameStopped()
        phone.gameStopped()
        Emulator.shared.stop()
    }

    /// Quit from a signal. An open sheet would refuse a plain terminate, so the phone UI closes first.
    func quitNow() {
        phone.gameStopped()
        NSApp.terminate(nil)
    }

    @objc func openSettings(_ sender: Any?) { phone.showSettings(sender) }
    @objc func usePhone(_ sender: Any?) { phone.usePhone(sender) }
    @objc func toggleSplit(_ sender: Any?) { screens.toggleSplit(sender) }
    @objc func toggleLowerFullScreen(_ sender: Any?) { screens.toggleLowerFullScreen(sender) }

    /// "Local Play" has a submenu that LocalPlay fills each time it opens (rooms come and go).
    private func localPlayItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Local Play", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Local Play")
        menu.delegate = localPlay
        item.submenu = menu
        return item
    }

    private func makeMenu() -> NSMenu {
        let main = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(), menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            main.addItem(item)
        }
        add("Nasty3DS", [
            NSMenuItem(title: "About Nasty3DS", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""),
            .separator(),
            NSMenuItem(title: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ","),
            .separator(),
            NSMenuItem(title: "Hide Nasty3DS", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"),
            NSMenuItem(title: "Quit Nasty3DS", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
        ])
        add("File", [
            NSMenuItem(title: "Add Game…", action: #selector(openGame(_:)), keyEquivalent: "o"),
            NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"),
        ])
        add("Game", [
            NSMenuItem(title: "Show Library", action: #selector(closeGame(_:)), keyEquivalent: "l"),
            .separator(),
            NSMenuItem(title: "Use Phone for Lower Screen", action: #selector(usePhone(_:)), keyEquivalent: "p"),
            NSMenuItem(title: "Show Phone QR Code", action: #selector(usePhone(_:)), keyEquivalent: ""),
            NSMenuItem(title: "Lower Screen in Its Own Window", action: #selector(toggleSplit(_:)), keyEquivalent: "d"),
            .separator(),
            localPlayItem(),
        ])
        let fullScreen = NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        let lowerFullScreen = NSMenuItem(title: "Enter Full Screen for Lower Screen", action: #selector(toggleLowerFullScreen(_:)), keyEquivalent: "f")
        lowerFullScreen.keyEquivalentModifierMask = [.command, .shift]
        add("View", [fullScreen, lowerFullScreen])
        add("Window", [
            NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"),
        ])
        NSApp.windowsMenu = main.items.last?.submenu     // the system adds "Move to <display>" here
        return main
    }
}
