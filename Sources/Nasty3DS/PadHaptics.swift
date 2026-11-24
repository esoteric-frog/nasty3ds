import AppKit
import CoreHaptics
import GameController
import Nasty3DSKit

/// Turns the game sound into rumble on the controller. One instance for the life of the app.
/// `feed` and `takeStats` run on the emulation thread. Everything that touches an engine runs on the main thread.
final class PadHaptics {
    /// How an event feels. The values come from the feel test (see the plan, Task 1).
    var shape = HapticShape()
    /// Main thread. Called when the current controller gets or loses rumble motors.
    var onAvailable: ((Bool) -> Void)?
    /// A line for core.log.
    var log: ((String) -> Void)?
    /// Main thread. True when the current controller has rumble motors.
    private(set) var available = false

    // Diagnosis: N3_HAPTIC_TRACE=1 writes one line per event, and the detector runs with no controller too.
    private let trace = ProcessInfo.processInfo.environment["N3_HAPTIC_TRACE"] != nil

    // Under the lock: the emulation thread and the main thread use these.
    private let lock = NSLock()
    private var detector: HapticDetector?
    private var sampleRate = 32728.0
    private var tuning = HapticTuning()
    private var source = HapticSource()
    private var slider = 0
    private var listening = false       // a game runs, the app is in front, and there are motors (or trace is on)
    private var framesFed = 0
    private var thumps = 0, ticks = 0

    // Main thread only.
    private var engines: [GCHapticsLocality: CHHapticEngine] = [:]
    private var gameRuns = false
    private var lastSample = 0.0

    init() {
        let center = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidBecomeCurrent, .GCControllerDidConnect, .GCControllerDidDisconnect] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.attach() }
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.quiet() }
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        attach()
    }

    /// The game's strength, 0...100. 0 = off: the detector does not run.
    var strength: Int {
        get { lock.withLock { slider } }
        set { lock.withLock { slider = max(0, min(100, newValue)) }; refresh() }
    }

    /// Main thread. Call when a game starts, after the emulator knows its sample rate.
    func start(sampleRate: Double, strength: Int, tuning: HapticTuning = HapticTuning()) {
        gameRuns = true
        lock.withLock { self.sampleRate = sampleRate; self.tuning = tuning; source = HapticSource(); slider = max(0, min(100, strength)) }
        refresh()
    }

    /// Main thread. Call when the game ends and when the app quits. No motor stays on.
    func stop() {
        gameRuns = false
        quiet()
    }

    /// Emulation thread. `bufferedSeconds`: the sound in the buffer in front of this block.
    /// `effects`: the block is the sound effects without the music. After the first such block, a full-sound block is ignored.
    func feed(_ samples: UnsafePointer<Int16>, frames: Int, bufferedSeconds: Double, effects: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard source.takes(effects: effects) else { return }
        guard listening, slider > 0, var d = detector else { return }
        detector = nil                      // one owner: the detector's array is not copied
        let blockStart = framesFed, slider = slider, rate = sampleRate, shape = shape
        framesFed += frames
        d.process(samples, frames: frames) { event in
            if event.kind == .thump { thumps += 1 } else { ticks += 1 }
            let plan = HapticMix.plan(event, slider: slider, shape: shape)
            let wait = HapticMix.delay(bufferedSeconds: bufferedSeconds, offsetFrames: event.frame - blockStart, sampleRate: rate, shape: shape)
            if trace { log?(String(format: "[n3] haptic %@ strength=%.2f pan=%+.2f wait=%.0fms", event.kind == .thump ? "thump" : "tick", event.strength, event.pan, wait * 1000)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.play(plan) }
        }
        detector = d
    }

    /// Emulation thread. Text for the stats line in core.log, then the counters start again.
    func takeStats() -> String {
        lock.withLock {
            defer { thumps = 0; ticks = 0 }
            return "thumps=\(thumps) ticks=\(ticks)"
        }
    }

    /// Main thread. One thump at the strength of the slider, for the user to feel while the slider moves.
    func sample() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastSample >= 0.25 else { return }       // at most 4 per second
        lastSample = now
        play(HapticMix.plan(HapticEvent(kind: .thump, strength: 0.8, pan: 0, frame: 0), slider: strength, shape: shape))
    }

    // MARK: main thread

    /// Makes the engines for the current controller. Four motors when the controller has them, else one group.
    private func attach() {
        engines.values.forEach { $0.stop() }
        engines = [:]
        if let haptics = (GCController.current ?? GCController.controllers().first)?.haptics {
            let four: [GCHapticsLocality] = [.leftHandle, .rightHandle, .leftTrigger, .rightTrigger]
            let places = four.allSatisfy(haptics.supportedLocalities.contains) ? four : [.default]
            for place in places {
                guard let engine = haptics.createEngine(withLocality: place) else { continue }
                engine.resetHandler = { [weak engine] in try? engine?.start() }
                engines[place] = engine
            }
        }
        let has = !engines.isEmpty
        if has != available { available = has; onAvailable?(has) }
        refresh()
    }

    /// Decides if the detector runs. A fresh detector each time it starts: old sound must not count.
    private func refresh() {
        let want = gameRuns && NSApp.isActive && (available || trace)
        let (on, strength): (Bool, Int) = lock.withLock {
            let on = want && slider > 0
            if on, detector == nil || !listening { detector = HapticDetector(sampleRate: sampleRate, tuning: tuning); framesFed = 0 }
            if !on { detector = nil }
            listening = on
            return (on, slider)
        }
        if trace { log?("[n3] haptics listening=\(on) game=\(gameRuns) active=\(NSApp.isActive) motors=\(available) strength=\(strength)") }
    }

    /// Stops the detector and all motors now.
    private func quiet() {
        lock.withLock { listening = false; detector = nil }
        engines.values.forEach { $0.stop() }
    }

    private func play(_ plan: MotorPlan) {
        if trace {
            log?(String(format: "[n3] haptic play left=%.2f/%.0fms right=%.2f/%.0fms triggers=%.2f/%.0fms engines=%d game=%d active=%d",
                        plan.leftHandle, plan.leftSeconds * 1000, plan.rightHandle, plan.rightSeconds * 1000,
                        plan.triggers, plan.triggerSeconds * 1000, engines.count, gameRuns ? 1 : 0, NSApp.isActive ? 1 : 0))
        }
        guard gameRuns, NSApp.isActive, !plan.isSilent else { return }
        if let only = engines[.default] {            // a controller with one motor group: thumps only
            run(only, level: plan.leftHandle, seconds: plan.leftSeconds, sharpness: 0.3, fade: shape.fade, transient: false)
            return
        }
        run(engines[.leftHandle], level: plan.leftHandle, seconds: plan.leftSeconds, sharpness: 0.1, fade: shape.fade, transient: false)
        run(engines[.rightHandle], level: plan.rightHandle, seconds: plan.rightSeconds, sharpness: 0.6, fade: shape.fade, transient: false)
        for place in [GCHapticsLocality.leftTrigger, .rightTrigger] {
            run(engines[place], level: plan.triggers, seconds: plan.triggerSeconds, sharpness: 1, fade: false, transient: shape.tickTransient)
        }
    }

    /// One event on one motor. It always has an end: a lost "stop" cannot leave a motor on.
    private func run(_ engine: CHHapticEngine?, level: Float, seconds: Double, sharpness: Float, fade: Bool, transient: Bool) {
        guard let engine, level > 0, seconds > 0 else { return }
        do {
            let parameters = [CHHapticEventParameter(parameterID: .hapticIntensity, value: level),
                              CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)]
            let event = transient
                ? CHHapticEvent(eventType: .hapticTransient, parameters: parameters, relativeTime: 0)
                : CHHapticEvent(eventType: .hapticContinuous, parameters: parameters, relativeTime: 0, duration: seconds)
            var curves: [CHHapticParameterCurve] = []
            if fade, !transient {       // a sharp start and a fast fade
                curves = [CHHapticParameterCurve(parameterID: .hapticIntensityControl, controlPoints: [
                    .init(relativeTime: 0, value: 1), .init(relativeTime: seconds, value: 0)], relativeTime: 0)]
            }
            let pattern = try CHHapticPattern(events: [event], parameterCurves: curves)
            try engine.start()          // no effect when the engine runs; starts it again after a stop
            try engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
        } catch {
            log?("[n3] haptics: \(error.localizedDescription)")
        }
    }
}
