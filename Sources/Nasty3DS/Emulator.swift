import AppKit
import CN3Host
import Nasty3DSKit

struct EmulatorError: Error { let message: String }

// libretro device ids, from libretro.h
private let deviceJoypad: UInt32 = 1, deviceAnalog: UInt32 = 5, devicePointer: UInt32 = 6
private let pointerX: UInt32 = 0, pointerY: UInt32 = 1, pointerPressed: UInt32 = 2

final class Emulator {
    static let shared = Emulator()

    /// "Software" in Task 6. "Vulkan" from Task 8.
    var renderer = "Vulkan"
    var map = ControllerMap.automatic
    weak var view: GameView?
    var onAudio: ((UnsafePointer<Int16>, Int) -> Void)?
    /// The game's sound effects without the music, after each frame on the emulation thread. Same format as onAudio.
    var onEffects: ((UnsafePointer<Int16>, Int) -> Void)?
    /// True when the loaded engine gives the sound effects without the music.
    var hasEffects: Bool { n3_has_effects() != 0 }
    /// Called on the emulation thread for each finished frame.
    var onFrame: ((CGImage, FrameSplit) -> Void)?
    /// The game's tilt sensor reads "the console is upside down" (some Pokemon evolve only then).
    /// Each game starts with false. Main thread.
    var upsideDown = false {
        didSet {
            let tilt = upsideDown ? Self.flipTilt : Tilt.upright
            n3_set_accel(tilt.x, tilt.y, tilt.z)
            if upsideDown != oldValue { log("[n3] upside down = \(upsideDown) tilt \(tilt.x) \(tilt.y) \(tilt.z)") }
        }
    }
    /// Diagnosis aid: N3_FLIP_ACCEL=x,y,z (in g) is the upside-down reading for this run.
    private static let flipTilt = ProcessInfo.processInfo.environment["N3_FLIP_ACCEL"].flatMap(Tilt.init(text:)) ?? .upsideDown
    private(set) var sampleRate = 32728.0
    private(set) var measuredFPS = 0.0

    private let lock = NSLock()
    private var _pad = PadSnapshot()
    private var _keyboard: Set<PadElement> = []
    private var _touch: (u: Double, v: Double)?
    private var split = FrameSplit(frameWidth: 400, frameHeight: 480)
    private var fpsLogCountdown = 5
    private var slowFrames = 0, lateWakes = 0, worstFrame = 0.0
    /// Diagnosis: a short text about the audio buffer for the stats line in core.log.
    var audioStats: (() -> String)?
    /// Diagnosis: a short text about the phone connection for the stats line.
    var phoneStats: (() -> String)?
    /// How full the audio buffer is, 0...1. Nil = no audio: pace by the clock only.
    var audioFill: (() -> Double)?
    var audioBufferSeconds = 0.1      // the length of the sound buffer that audioFill measures
    private var thread: Thread?
    private var running = false
    private var logFile: FileHandle?

    var pad: PadSnapshot {
        get { lock.withLock { _pad } }
        set { lock.withLock { _pad = newValue } }
    }
    var keyboard: Set<PadElement> {
        get { lock.withLock { _keyboard } }
        set { lock.withLock { _keyboard = newValue } }
    }
    var touch: (u: Double, v: Double)? {
        get { lock.withLock { _touch } }
        set { lock.withLock { _touch = newValue } }
    }

    static var supportDir: URL {
        // N3_PROFILE=/folder: a scratch profile for checks and for a second player on one Mac.
        // It keeps test runs away from the real save data.
        if let profile = ProcessInfo.processInfo.environment["N3_PROFILE"], profile.hasPrefix("/") {
            return URL(fileURLWithPath: profile)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nasty3DS")
    }

    /// The core dylib: next to the executable (app bundle later), or vendor/core in the repo.
    static var corePath: String {
        let name = "azahar_libretro.dylib"
        let places = [Bundle.main.privateFrameworksURL?.appendingPathComponent(name).path,      // Nasty3DS.app/Contents/Frameworks
                      Bundle.main.bundleURL.appendingPathComponent(name).path].compactMap { $0 }
        if let found = places.first(where: { FileManager.default.fileExists(atPath: $0) }) { return found }
        return FileManager.default.currentDirectoryPath + "/vendor/core/" + name
    }

    func start(gamePath: String) throws {
        stop()   // File > Open while a game runs: the old game must end before the core loads again
        let fm = FileManager.default
        let saves = Self.supportDir.appendingPathComponent("saves")
        let system = Self.supportDir.appendingPathComponent("system")
        try fm.createDirectory(at: saves, withIntermediateDirectories: true)
        try fm.createDirectory(at: system, withIntermediateDirectories: true)

        let logURL = Self.supportDir.appendingPathComponent("core.log")
        fm.createFile(atPath: logURL.path, contents: nil)
        logFile = try FileHandle(forWritingTo: logURL)
        upsideDown = false

        // The core keeps these pointers. They are never freed: one game per process in Part 1.
        let options: [(String, String)] = [
            ("citra_graphics_api", renderer),
            ("citra_layout_option", "default"),
            ("citra_resolution_factor", "1"),
            ("citra_enable_touch_touchscreen", "enabled"),
            ("citra_enable_mouse_touchscreen", "disabled"),
        ]
        let cOptions = UnsafeMutablePointer<n3_option>.allocate(capacity: options.count)
        for (i, o) in options.enumerated() {
            cOptions[i] = n3_option(key: UnsafePointer(strdup(o.0)), value: UnsafePointer(strdup(o.1)))
        }

        var config = n3_config()
        config.save_dir = UnsafePointer(strdup(saves.path))
        config.system_dir = UnsafePointer(strdup(system.path))
        config.options = UnsafePointer(cOptions)
        config.option_count = options.count
        config.video = { pixels, width, height, pitch in
            Emulator.shared.frame(pixels!, Int(width), Int(height), pitch)
        }
        config.audio = { samples, frames in
            Emulator.shared.onAudio?(samples!, frames)
            return frames
        }
        config.effects = { samples, frames in
            Emulator.shared.onEffects?(samples!, frames)
            return frames
        }
        config.input = { port, device, index, id in
            port == 0 ? Emulator.shared.input(device, index, id) : 0
        }
        // level 0 is the core's debug chatter: it made core.log grow by megabytes each session
        config.log = { level, line in if level > 0, let line { Emulator.shared.log(String(cString: line)) } }

        var err = [CChar](repeating: 0, count: 1024)
        guard n3_load_core(Self.corePath, &config, &err, err.count) == 0 else {
            throw EmulatorError(message: "The engine did not load.\n\(Self.corePath)\n\(String(cString: err))")
        }
        guard n3_load_game(gamePath, &err, err.count) == 0 else {
            n3_unload()
            throw EmulatorError(message: "This file did not start.\n\(gamePath)\nSee \(logURL.path)")
        }

        var w: UInt32 = 0, h: UInt32 = 0, fps = 0.0
        n3_av_info(&w, &h, &fps, &sampleRate)
        if fps < 1 { fps = 59.83 }
        log("[n3] av info \(w)x\(h) fps=\(fps) rate=\(sampleRate)")

        running = true
        let t = Thread { [self] in loop(fps: fps) }
        t.name = "emulation"
        t.qualityOfService = .userInteractive
        t.start()
        thread = t
    }

    func stop() {
        guard running else { return }
        running = false
        while thread?.isFinished == false { usleep(1000) }
        thread = nil
        n3_unload()   // the core writes its save data here
        try? logFile?.close()
        logFile = nil
    }

    // Pacing: sleep to a deadline. The frame time follows the audio buffer level (Pacing.frameTime),
    // so the emulator and the sound card stay in step. After a short stall the loop runs frames
    // back to back to catch up; after a long stall (over maxCatchUp) it starts from "now".
    static let maxCatchUp = 0.1
    private func loop(fps: Double) {
        let baseStep = 1.0 / fps
        var next = CFAbsoluteTimeGetCurrent()
        var windowStart = next, frames = 0
        while running {
            let step = Pacing.frameTime(base: baseStep, fill: audioFill?() ?? 0.5)
            let runStart = CFAbsoluteTimeGetCurrent()
            n3_run()
            let runTime = CFAbsoluteTimeGetCurrent() - runStart
            if runTime > step * 1.5 { slowFrames += 1; worstFrame = max(worstFrame, runTime) }
            frames += 1
            next += step
            let now = CFAbsoluteTimeGetCurrent()
            if now - windowStart >= 1 {
                measuredFPS = Double(frames) / (now - windowStart)
                fpsLogCountdown -= 1
                if fpsLogCountdown <= 0 {
                    fpsLogCountdown = 5
                    // slow = frames where the core took over 1.5 frame times; late = wake-ups over 3 ms late
                    log(String(format: "[n3] fps %.1f slow=%d worst=%.0fms late=%d %@ %@ touch=%d", measuredFPS, slowFrames,
                               worstFrame * 1000, lateWakes, audioStats?() ?? "", phoneStats?() ?? "", touch == nil ? 0 : 1))
                    slowFrames = 0; worstFrame = 0; lateWakes = 0
                }
                windowStart = now; frames = 0
            }
            if next > now {
                Thread.sleep(forTimeInterval: next - now)
                if CFAbsoluteTimeGetCurrent() - next > 0.003 { lateWakes += 1 }
            } else if now - next > Self.maxCatchUp { next = now }
            else {
                // Catch up only as far as the sound buffer has room: more would drop samples.
                next = now - Pacing.catchUpDebt(behind: now - next, fill: audioFill?() ?? 0.5,
                                                bufferSeconds: audioBufferSeconds, base: baseStep)
            }
        }
    }

    private func frame(_ pixels: UnsafeRawPointer, _ width: Int, _ height: Int, _ pitch: Int) {
        let data = Data(bytes: pixels, count: pitch * height)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pitch,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                         | CGImageAlphaInfo.noneSkipFirst.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return }
        dumpIfAsked(image)
        let s = FrameSplit(frameWidth: width, frameHeight: height)
        lock.withLock { split = s }
        onFrame?(image, s)
        DispatchQueue.main.async { [weak view] in view?.show(image, split: s) }
    }

    /// Diagnosis aid: N3_DUMP_FRAME=/path/out.png writes every 120th frame there as a PNG.
    private var frameCount = 0
    private let dumpPath = ProcessInfo.processInfo.environment["N3_DUMP_FRAME"]
    private func dumpIfAsked(_ image: CGImage) {
        frameCount += 1
        guard let dumpPath, frameCount % 120 == 0,
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: dumpPath) as CFURL, "public.png" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    private func input(_ device: UInt32, _ index: UInt32, _ id: UInt32) -> Int16 {
        let (pad, keys, touch, split) = lock.withLock { (_pad, _keyboard, _touch, self.split) }
        switch device {
        case deviceJoypad:
            var merged = pad
            merged.pressed.formUnion(keys)
            return map.joypad(id: id, pad: merged)
        case deviceAnalog:
            return map.analog(index: index, id: id, pad: pad)
        case devicePointer:
            guard let touch else { return 0 }
            let p = split.pointer(u: touch.u, v: touch.v)
            switch id {
            case pointerX: return p.x
            case pointerY: return p.y
            case pointerPressed: return 1
            default: return 0
            }
        default:
            return 0
        }
    }

    func log(_ line: String) {
        let data = Data((line.hasSuffix("\n") ? line : line + "\n").utf8)
        if let logFile { logFile.write(data); return }
        // No game runs (the updater, for one): add the line to the end of the last log.
        let url = Self.supportDir.appendingPathComponent("core.log")
        guard let handle = try? FileHandle(forWritingTo: url) else { try? data.write(to: url); return }
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    }
}
