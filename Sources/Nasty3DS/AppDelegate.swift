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
    private let haptics = PadHaptics()
    private var rumbleKey = ""
    private var audioDump: FileHandle?
    private var effectsDump: FileHandle?
    private var soundAhead = 0.0        // emulation thread: the sound in the buffer in front of the newest block
    private var controllerName: String?
    let updater = Updater()
    private let environment = ProcessInfo.processInfo.environment

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMenu()
        window = NSWindow(contentRect: gameView.frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Nasty3DS"
        window.contentView = gameView
        screens = ScreenWindows(window: window, gameView: gameView)
        screens.onUsePhone = { [weak self] in self?.usePhone(nil) }
        haptics.log = { Emulator.shared.log($0) }
        haptics.onAvailable = { [weak self] in self?.screens.rumbleAvailable = $0 }
        screens.rumbleAvailable = haptics.available
        screens.onRumbleChange = { [weak self] value in
            guard let self else { return }
            HapticStrength.save(value, key: self.rumbleKey)
            self.haptics.strength = value
            self.haptics.sample()       // the user feels the new strength while the slider moves
        }
        phone = PhoneController(window: window)
        phone.onLowerOnPhone = { [weak self] in self?.screens.phoneHasLower = $0 }
        updater.prepareToInstall = { [weak self] in self?.closeGame(nil) }
        updater.quit = { [weak self] in self?.quitNow() }
        updater.tryStartForCheck = { [weak self] in
            if let path = ProcessInfo.processInfo.environment["N3_START_DURING_INSTALL"] { self?.start(path) }
        }
        phone.updatesSection = makeUpdatesSection()
        window.collectionBehavior = [.fullScreenPrimary]
        // A scratch profile (a check) must not write the real window place.
        if environment["N3_PROFILE"] == nil { window.setFrameAutosaveName("GameWindow") }
        screens.restoreShape()
        window.center()
        // Diagnosis aid: N3_BACKGROUND=1 starts behind the other apps and takes no keyboard focus.
        if environment["N3_BACKGROUND"] == "1" {
            window.orderBack(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeFirstResponder(gameView)

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
        // Diagnosis aid: N3_SHOW_SETTINGS=1 opens Settings at launch (for a picture with N3_SNAPSHOT_DIR). Not in the app bundle.
        if Bundle.main.bundleURL.pathExtension != "app", environment["N3_SHOW_SETTINGS"] == "1" { phone.showSettings(nil) }
        // Diagnosis aid: N3_UPDATE_NOW=1 checks and installs at launch with no alerts (see Updater).
        if environment["N3_UPDATE_NOW"] == "1" { updater.check(userAsked: false, window: nil) }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        // From the Settings button, the alerts belong to the Settings window.
        updater.check(userAsked: true, window: (sender as? NSView)?.window ?? window)
    }

    /// Settings > Updates: the version, or what the updater does now, and one button.
    private func makeUpdatesSection() -> NSView {
        let version = updater.currentVersion == "0" ? "Nasty3DS test build" : "Nasty3DS \(updater.currentVersion)"
        let status = NSTextField(labelWithString: version)
        status.font = .preferredFont(forTextStyle: .body)
        let button = NSButton(title: "Check for Updates…", target: self, action: #selector(checkForUpdates(_:)))
        button.setAccessibilityHelp("Looks for a new version of Nasty3DS. Your games and saves stay as they are.")
        updater.onStatus = { state in
            switch state {
            case .idle, .failed: status.stringValue = version
            case .checking: status.stringValue = "Checking…"
            case .downloading(let new): status.stringValue = "Downloading Nasty3DS \(new)…"
            case .installing(let new): status.stringValue = "Installing Nasty3DS \(new)…"
            }
            button.isEnabled = state == .idle || { if case .failed = state { return true }; return false }()
        }
        let title = NSTextField(labelWithString: "Updates")
        title.font = .preferredFont(forTextStyle: .title2)
        let stack = NSStackView(views: [title, status, button])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        return stack
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
        if item.action == #selector(showRumble(_:)) { return gameRuns && haptics.available }
        if item.action == #selector(toggleFlip(_:)) {
            item.state = screens.isFlipped ? .on : .off
            return gameRuns
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
        haptics.stop()
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
        // The update closed the game and now copies the saves and swaps the app: no game may start.
        guard !updater.installing else { Emulator.shared.log("update: game start refused during install"); return }
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
        audio?.log = { Emulator.shared.log($0) }
        // Diagnosis aid: N3_DUMP_AUDIO=/path/out.raw gets the game sound (16-bit stereo; the rate is in core.log).
        // A recording of real play is how the haptic detector is tuned: replay it through HapticDetector.
        audioDump = nil
        if let path = ProcessInfo.processInfo.environment["N3_DUMP_AUDIO"] {
            FileManager.default.createFile(atPath: path, contents: nil)
            audioDump = FileHandle(forWritingAtPath: path)
        }
        rumbleKey = HapticStrength.key(programID: GameFile.read(file)?.programID, fileName: file.lastPathComponent)
        let strength = HapticStrength.load(rumbleKey)
        screens.rumbleValue = strength
        // The rumble listens to the sound effects only when the engine gives them: the music has drums,
        // and a drum is not an event in the game. An engine without that output: the full sound, as before.
        let effects = emulator.hasEffects
        effectsDump = nil
        if effects, let path = ProcessInfo.processInfo.environment["N3_DUMP_EFFECTS"] {   // diagnosis, as N3_DUMP_AUDIO
            FileManager.default.createFile(atPath: path, contents: nil)
            effectsDump = FileHandle(forWritingAtPath: path)
        }
        haptics.start(sampleRate: emulator.sampleRate, strength: strength, tuning: effects ? .effects : HapticTuning())
        emulator.onAudio = { [weak self] samples, frames in
            guard let self else { return }
            // The sound in front of this block, measured before the block goes in: a haptic event lands on its sound.
            let buffered = (self.audio?.fillFraction ?? 0) * AudioOut.bufferSeconds
            self.soundAhead = buffered
            self.audio?.enqueue(samples, frames: frames)
            self.audioDump?.write(Data(bytes: samples, count: frames * 4))
            self.haptics.feed(samples, frames: frames, bufferedSeconds: buffered, effects: false)   // ignored after the first effects block
        }
        emulator.onEffects = !effects ? nil : { [weak self] samples, frames in
            guard let self else { return }
            self.effectsDump?.write(Data(bytes: samples, count: frames * 4))
            self.haptics.feed(samples, frames: frames, bufferedSeconds: self.soundAhead, effects: true)
        }
        emulator.audioFill = { [weak self] in self?.audio?.fillFraction ?? 0.5 }
        emulator.audioBufferSeconds = AudioOut.bufferSeconds
        emulator.audioStats = { [weak self] in
            guard let self else { return "" }
            return (self.audio?.takeStats() ?? "") + " " + self.haptics.takeStats()
        }
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
        haptics.stop()
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
    @objc func showRumble(_ sender: Any?) { screens.showRumble(sender) }
    @objc func toggleFlip(_ sender: Any?) { screens.toggleFlip(sender) }

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
            NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: ""),
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
            NSMenuItem(title: "Rumble…", action: #selector(showRumble(_:)), keyEquivalent: ""),
            NSMenuItem(title: "Flip Upside Down", action: #selector(toggleFlip(_:)), keyEquivalent: ""),
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
