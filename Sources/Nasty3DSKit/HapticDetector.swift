import Foundation

/// One haptic moment that the detector found in the game sound.
public struct HapticEvent: Equatable, Sendable {
    public enum Kind: Sendable { case thump, tick }
    public let kind: Kind
    public let strength: Float   // 0...1, before the game's strength slider
    public let pan: Float        // -1 = left, +1 = right
    public let frame: Int        // sample frame where the sound starts, counted from the start of the game

    public init(kind: Kind, strength: Float, pan: Float, frame: Int) {
        self.kind = kind; self.strength = strength; self.pan = pan; self.frame = frame
    }
}

/// Every number the detector uses. Tuned on recordings of real play (Pokemon X, 2026-11-19).
/// In that game the music is loud in every pitch all the time, and a hit sound does not stand out from it.
/// So the owner chose: each big sudden sound counts, and a drum in the music counts too.
public struct HapticTuning: Sendable {
    public var lowCutHz = 300.0            // sound below this is "deep" (thumps). 150 Hz missed the body of bump sounds
    public var highCutHz = 2000.0          // sound above this is "sharp" (ticks)
    public var windowSeconds = 0.010       // energy is measured in windows of this length; shorter = bass ripple gives false hits
    public var attackSeconds = 0.015       // how fast the average rises; a sound that grows slower than this is not "sudden"
    public var releaseSeconds = 0.300      // how fast the average falls; longer = more rest after a loud sound
    public var thumpRatio: Float = 3       // a window must have this many times the average energy. 4 gave 3 thumps a minute in play
    public var tickRatio: Float = 4
    public var thumpFloor: Float = 0.001   // mean-square energy; under this a deep sound is too quiet to count
    public var tickFloor: Float = 0.0002
    public var thumpFullScale: Float = 0.20  // RMS level in the low band that gives strength 1
    public var tickFullScale: Float = 0.15
    public var strengthCurve: Float = 0.6  // under 1 lifts quiet hits
    public var thumpGapSeconds = 0.250     // no second thump sooner than this: a thump lasts about 0.2 s on the motors
    public var softenSeconds = 0.350       // a thump this soon after another one is softer
    public var softenFactor: Float = 0.6
    public var maxThumpsPerSecond = 3
    public var tickQuietSeconds = 0.400    // a tick plays only when no other sharp sound started in this time
    public init() {}

    /// For the sound effects without the music (an engine that gives them). Not tuned yet: the same numbers.
    public static var effects: HapticTuning { HapticTuning() }
}

/// Finds sudden deep sounds (thumps) and sudden sharp sounds (ticks) in stereo game sound.
/// Pure: no Apple frameworks, and `process` allocates nothing.
/// Chooses the sound for the detector: the sound effects when the engine gives them, else the full sound.
/// An engine can have the effects output and give nothing (a game with its sound on the old CSND path):
/// then the full sound stays in use.
public struct HapticSource: Sendable {
    private var effectsSeen = false
    public init() {}
    /// True when the detector must get this block. `effects`: the block is from the effects output.
    public mutating func takes(effects: Bool) -> Bool {
        if effects { effectsSeen = true }
        return effects || !effectsSeen
    }
}

public struct HapticDetector {
    private struct Band {
        var slow: Float = 0     // the average energy; rises fast, falls slowly
        var armed = true
        /// True on the first window of a sudden rise. Compare first, then learn the window.
        mutating func onset(_ e: Float, floor: Float, ratio: Float, attack: Float, release: Float) -> Bool {
            let hit = e > floor && e > slow * ratio
            let fire = hit && armed
            armed = !hit
            slow += (e > slow ? attack : release) * (e - slow)
            return fire
        }
    }

    public let tuning: HapticTuning
    private let sampleRate: Double
    private let window: Int                 // frames in one energy window
    private let lowA: Float, highA: Float   // one-pole filter coefficients
    private let attack: Float, release: Float
    private let gapFrames: Int, softenFrames: Int, secondFrames: Int, quietWindows: Int

    // filter memory: two poles for each channel and band
    private var lowL1: Float = 0, lowL2: Float = 0, lowR1: Float = 0, lowR2: Float = 0
    private var highL1: Float = 0, highL2: Float = 0, highR1: Float = 0, highR2: Float = 0
    private var sumLowL: Float = 0, sumLowR: Float = 0, sumHighL: Float = 0, sumHighR: Float = 0
    private var filled = 0                  // frames in the window so far
    private var frame = 0                   // frames seen since the start
    private var windowIndex = 0
    private var low = Band(), high = Band()
    private var lastThumpFrame = Int.min / 2
    private var recent: [Int]               // frames of the last thumps, as a ring
    private var recentNext = 0
    private var lastLowWindow = Int.min / 2, lastHighWindow = Int.min / 2
    private var pendingTick: HapticEvent?   // waits one window: a thump at the same moment cancels it

    public init(sampleRate: Double, tuning: HapticTuning = HapticTuning()) {
        self.tuning = tuning
        self.sampleRate = sampleRate
        window = max(1, Int(sampleRate * tuning.windowSeconds))
        lowA = Float(1 - exp(-2 * Double.pi * tuning.lowCutHz / sampleRate))
        highA = Float(1 - exp(-2 * Double.pi * tuning.highCutHz / sampleRate))
        attack = Float(1 - exp(-tuning.windowSeconds / tuning.attackSeconds))
        release = Float(1 - exp(-tuning.windowSeconds / tuning.releaseSeconds))
        gapFrames = Int(sampleRate * tuning.thumpGapSeconds)
        softenFrames = Int(sampleRate * tuning.softenSeconds)
        secondFrames = Int(sampleRate)
        quietWindows = Int((tuning.tickQuietSeconds / tuning.windowSeconds).rounded())
        recent = [Int](repeating: Int.min / 2, count: max(1, tuning.maxThumpsPerSecond))
    }

    /// `samples` is interleaved stereo (left, right), 16 bit. `emit` gets each event; it does not escape.
    public mutating func process(_ samples: UnsafePointer<Int16>, frames: Int, emit: (HapticEvent) -> Void) {
        for i in 0..<frames {
            let l = Float(samples[i * 2]) / 32768, r = Float(samples[i * 2 + 1]) / 32768
            lowL1 += lowA * (l - lowL1); lowL2 += lowA * (lowL1 - lowL2)
            lowR1 += lowA * (r - lowR1); lowR2 += lowA * (lowR1 - lowR2)
            sumLowL += lowL2 * lowL2; sumLowR += lowR2 * lowR2
            // high-pass = the signal less its low-pass, two times
            highL1 += highA * (l - highL1); let hl = l - highL1
            highL2 += highA * (hl - highL2); let hl2 = hl - highL2
            highR1 += highA * (r - highR1); let hr = r - highR1
            highR2 += highA * (hr - highR2); let hr2 = hr - highR2
            sumHighL += hl2 * hl2; sumHighR += hr2 * hr2
            filled += 1; frame += 1
            if filled == window { closeWindow(emit) }
        }
    }

    private mutating func closeWindow(_ emit: (HapticEvent) -> Void) {
        let n = Float(window), start = frame - window
        let lowL = sumLowL / n, lowR = sumLowR / n, highL = sumHighL / n, highR = sumHighR / n
        sumLowL = 0; sumLowR = 0; sumHighL = 0; sumHighR = 0; filled = 0
        let t = tuning
        let lowE = (lowL + lowR) / 2, highE = (highL + highR) / 2

        if low.onset(lowE, floor: t.thumpFloor, ratio: t.thumpRatio, attack: attack, release: release) {
            lastLowWindow = windowIndex
            pendingTick = nil                                   // a thump and a tick together: the thump only
            let oldest = recent[recentNext]                     // the thump that was maxThumpsPerSecond thumps before this one
            if start - lastThumpFrame >= gapFrames, start - oldest >= secondFrames {
                var s = Self.strength(lowE, fullScale: t.thumpFullScale, curve: t.strengthCurve)
                if start - lastThumpFrame < softenFrames { s *= t.softenFactor }
                emit(HapticEvent(kind: .thump, strength: s, pan: Self.pan(lowL, lowR), frame: start))
                lastThumpFrame = start
                recent[recentNext] = start
                recentNext = (recentNext + 1) % recent.count
            }
        }
        if let tick = pendingTick { emit(tick); pendingTick = nil }
        if high.onset(highE, floor: t.tickFloor, ratio: t.tickRatio, attack: attack, release: release) {
            let alone = windowIndex - lastHighWindow >= quietWindows     // the first sharp sound of a run only
            lastHighWindow = windowIndex
            if alone, windowIndex - lastLowWindow > 1 {
                pendingTick = HapticEvent(kind: .tick, strength: Self.strength(highE, fullScale: t.tickFullScale, curve: t.strengthCurve),
                                          pan: Self.pan(highL, highR), frame: start)
            }
        }
        windowIndex += 1
    }

    // ponytail: strength comes from the first window only, so a sound that starts late in its window reads softer.
    // Upgrade: wait one more window and take the larger energy (costs 10 ms of lead time).
    private static func strength(_ energy: Float, fullScale: Float, curve: Float) -> Float {
        min(1, pow(energy.squareRoot() / fullScale, curve))
    }

    private static func pan(_ left: Float, _ right: Float) -> Float {
        left + right > 0 ? (right - left) / (right + left) : 0
    }
}
