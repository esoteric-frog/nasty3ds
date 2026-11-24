import AppKit
import Nasty3DSKit

/// Gets a new version from GitHub, checks its signature, puts it in place of this app, starts it again.
/// It never touches the games or the saves. It copies all saves first.
/// The game ends only when the new app is downloaded and checked: a stop before that changes nothing.
final class Updater {
    enum Status: Equatable { case idle, checking, downloading(String), installing(String), failed(String) }

    var onStatus: ((Status) -> Void)?            // main queue
    var prepareToInstall: (() -> Void)?          // main queue: the owner ends a running game (the engine writes the save)
    var quit: (() -> Void)?                      // main queue: the owner closes its sheets and quits
    /// True from the moment the game closes for the install: no game may start then (main queue).
    private(set) var installing = false
    /// Diagnosis aid for check-update.sh only (N3_UPDATE_NOW=1 with N3_START_DURING_INSTALL): tries a game start mid-install.
    var tryStartForCheck: (() -> Void)?
    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    /// The update check puts a throw-away key here in its scratch copy, so the real key never signs
    /// a test build. Whoever can edit this file can replace the app anyway.
    private let publicKey = Bundle.main.object(forInfoDictionaryKey: "N3UpdatePublicKey") as? String ?? UpdateFeed.publicKey

    private struct Stop: Error { let reason: String }
    private let environment = ProcessInfo.processInfo.environment
    /// Diagnosis aid: N3_UPDATE_NOW=1 checks and installs at launch with no alerts. The outcome is a log line.
    private var quiet: Bool { environment["N3_UPDATE_NOW"] == "1" }
    private var busy = false                     // main queue
    private let fm = FileManager.default
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 600
        configuration.httpAdditionalHeaders = ["User-Agent": "Nasty3DS", "Accept": "application/vnd.github+json"]
        return URLSession(configuration: configuration, delegate: RedirectGuard(), delegateQueue: nil)
    }()
    private static let checkFailed = "The update check failed. Check the internet connection, then try again."
    private static let notSigned = "The update file is not from the Nasty3DS maker. Nothing was installed."

    /// Call on the main queue. `window`: the parent of the alerts (nil = a free alert window).
    func check(userAsked: Bool, window: NSWindow?) {
        guard !busy else { return }
        busy = true
        set(.checking)
        Task.detached { [self] in await run(userAsked: userAsked, window: window) }
    }

    private func run(userAsked: Bool, window: NSWindow?) async {
        var unpackFolder: URL?
        defer { if let unpackFolder { try? fm.removeItem(at: unpackFolder) } }
        do {
            // 1. The feed.
            let feed = environment["N3_UPDATE_FEED"].map { URL(string: $0) } ?? UpdateFeed.latest
            guard let feed, UpdateFeed.allowed(feed) else { throw Stop(reason: "The update address is not allowed.") }
            let (data, code) = try await read(feed, limit: 1024 * 1024, tooLarge: Self.checkFailed)
            // 2. The offer. 404 = no release yet. A 200 that is no release (a Wi-Fi sign-in page) is a failure.
            guard code == 200 || code == 404 else { throw Stop(reason: "GitHub answered with code \(code). Try again later.") }
            guard code == 404 || UpdateFeed.isFeed(json: data) else { throw Stop(reason: Self.checkFailed) }
            guard code == 200, let offer = UpdateFeed.offer(json: data, current: currentVersion) else {
                log("update: up to date (\(currentVersion))")
                if userAsked { await alert("Nasty3DS is up to date", "Version \(currentVersion) is the newest version.", window: window) }
                return finish(.idle)
            }
            // 3. Ask.
            let install = await alert("Nasty3DS \(offer.version) is available",
                                      "You have \(currentVersion). Your games and saves stay as they are. Nasty3DS closes the game and starts again.",
                                      buttons: ["Install and Restart", "Later"], window: window)
            guard install else { return finish(.idle) }
            // 4. The place of this app.
            let target = Bundle.main.bundleURL
            guard target.pathExtension == "app" else { throw Stop(reason: "Updates work in the Nasty3DS app only.") }
            guard !target.path.contains("/AppTranslocation/") else {
                throw Stop(reason: "Move Nasty3DS to your Applications folder first, then open it from there.")
            }
            let parent = target.deletingLastPathComponent()
            guard fm.isWritableFile(atPath: parent.path) else {
                throw Stop(reason: "Nasty3DS cannot write to the folder it is in. Move it to your Applications folder, then try again.")
            }
            // 5. Download, signature, unpack, and checks of the new app. The game still runs.
            set(.downloading(offer.version))
            let folder = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
            unpackFolder = folder
            let zip = folder.appendingPathComponent("Nasty3DS.zip")
            let (zipData, zipCode) = try await read(offer.zip, limit: UpdateFeed.maxZipBytes,
                                                    tooLarge: "The update file is too large. Nothing was installed.")
            let (signature, signatureCode) = try await read(offer.signature, limit: 1024, tooLarge: Self.notSigned)
            guard zipCode == 200, signatureCode == 200 else { throw Stop(reason: "The update file could not be downloaded. Try again later.") }
            guard UpdateFeed.isSigned(zipData, signature: signature, publicKey: publicKey) else { throw Stop(reason: Self.notSigned) }
            try zipData.write(to: zip)
            guard Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path]) else { throw Stop(reason: "The update file could not be unpacked.") }
            let newApp = folder.appendingPathComponent("Nasty3DS.app")
            let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist"))
            guard info?["CFBundleIdentifier"] as? String == "app.nasty3ds" else { throw Stop(reason: "The update file does not hold Nasty3DS.") }
            // An old signed file sold as new must not install.
            guard let newVersion = info?["CFBundleShortVersionString"] as? String, UpdateFeed.isNewer(newVersion, than: currentVersion) else {
                throw Stop(reason: "The update file holds an older version. Nothing was installed.")
            }
            guard Self.codesignOK(newApp) else { throw Stop(reason: "The new app is damaged. Nothing was installed.") }
            // 6. Now, back to back: end the game, copy the saves, swap, start again.
            set(.installing(offer.version))
            await MainActor.run {
                self.installing = true
                self.prepareToInstall?()
                if self.quiet, self.environment["N3_START_DURING_INSTALL"] != nil { self.tryStartForCheck?() }
            }
            log("update: game closed")
            do { _ = try GameLibrary(folder: Emulator.supportDir).backUpAllSaves() } catch {
                throw Stop(reason: "The saves could not be copied. The update did not start.")
            }
            try swap(newApp, into: target)
            log("update: installed \(newVersion)")
            try? fm.removeItem(at: folder)          // the defer does not run after the app quits
            unpackFolder = nil
            await MainActor.run { self.restart(target) }
        } catch let stop as Stop {
            stopped(stop.reason, window: window)
        } catch {
            stopped("The update failed: \(error.localizedDescription)", window: window)
        }
    }

    /// The running app goes aside, the new one takes its place. Any failure puts the old one back.
    private func swap(_ newApp: URL, into target: URL) throws {
        let old = target.deletingLastPathComponent().appendingPathComponent(".Nasty3DS-old.app")
        try? fm.removeItem(at: old)
        do { try fm.moveItem(at: target, to: old) } catch {
            throw Stop(reason: "macOS did not let Nasty3DS replace itself. Open System Settings > Privacy & Security > App Management and allow Nasty3DS, then try again.")
        }
        do {
            try fm.moveItem(at: newApp, to: target)
            guard Self.codesignOK(target) else { throw Stop(reason: "") }
        } catch {
            try? fm.removeItem(at: target)
            try? fm.moveItem(at: old, to: target)
            throw Stop(reason: "The update failed. The old version is back in place.")
        }
        try? fm.removeItem(at: old)
    }

    /// Opens the app at `target` again once this process has ended, with the same N3_* settings.
    private func restart(_ target: URL) {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The new app must not check again at its start.
        open.environment = environment.filter { $0.key != "N3_UPDATE_NOW" }
        // Values go in as arguments, never as text inside the script.
        let settings = environment.filter { $0.key.hasPrefix("N3_") && $0.key != "N3_UPDATE_NOW" }
            .sorted { $0.key < $1.key }.flatMap { ["--env", "\($0.key)=\($0.value)"] }
        open.arguments = ["-c", #"pid=$1; shift; while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open "$@""#,
                          "sh", String(getpid()), environment["N3_BACKGROUND"] == "1" ? "-gn" : "-n"] + settings + [target.path]
        do { try open.run() } catch {
            stopped("The new version is installed. Open Nasty3DS again to use it.", window: nil)
            return
        }
        // An open sheet makes a plain terminate return: the owner closes it first (AppDelegate.quitNow).
        if let quit { quit() } else { NSApp.terminate(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }      // still here: something refused to quit
    }

    // MARK: helpers

    /// Reads at most `limit` bytes; a longer answer stops with `tooLarge`, before the body when
    /// the server says its length. Returns the body and the HTTP status.
    private func read(_ url: URL, limit: Int, tooLarge: String) async throws -> (Data, Int) {
        let (bytes, response) = try await fetch { try await self.session.bytes(from: url) }
        guard response.expectedContentLength <= Int64(limit) else { bytes.task.cancel(); throw Stop(reason: tooLarge) }
        var data = Data()
        data.reserveCapacity(max(0, Int(response.expectedContentLength)))
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit { bytes.task.cancel(); throw Stop(reason: tooLarge) }
            }
        } catch let stop as Stop { throw stop } catch { throw Stop(reason: Self.checkFailed) }
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// A network error becomes one plain sentence.
    private func fetch<T>(_ work: () async throws -> T) async throws -> T {
        do { return try await work() } catch {
            throw Stop(reason: "Nasty3DS could not reach the update server. Check the internet connection, then try again.")
        }
    }

    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static func codesignOK(_ app: URL) -> Bool { run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) }

    private func log(_ line: String) { Emulator.shared.log(line) }

    private func set(_ status: Status) {
        DispatchQueue.main.async { [weak self] in self?.onStatus?(status) }
    }

    private func finish(_ status: Status) {
        DispatchQueue.main.async { [weak self] in self?.busy = false; self?.installing = false; self?.onStatus?(status) }
    }

    private func stopped(_ reason: String, window: NSWindow?) {
        log("update: stopped: \(reason)")
        finish(.failed(reason))
        Task { await alert("The update did not finish", reason, window: window) }
    }

    /// True = the first button. With N3_UPDATE_NOW no alert shows and the answer is yes.
    @discardableResult @MainActor
    private func alert(_ title: String, _ text: String, buttons: [String] = ["OK"], window: NSWindow?) async -> Bool {
        if quiet { return true }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        buttons.forEach { alert.addButton(withTitle: $0) }
        guard let window, window.isVisible else { return alert.runModal() == .alertFirstButtonReturn }
        return await withCheckedContinuation { done in
            alert.beginSheetModal(for: window) { done.resume(returning: $0 == .alertFirstButtonReturn) }
        }
    }
}

/// Refuses a redirect to an address that `UpdateFeed.allowed` refuses (plain http, another scheme).
private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        request.url.map(UpdateFeed.allowed) == true ? request : nil
    }
}
