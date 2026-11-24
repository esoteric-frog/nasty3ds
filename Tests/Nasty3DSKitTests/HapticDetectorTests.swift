import Foundation
import Testing
@testable import Nasty3DSKit

private let rate = 32728.0

/// Stereo test sound: a tone at `hz`, with the level from `amp` (a function of time) and a gain for each channel.
private func sound(seconds: Double, hz: Double, left: Float = 1, right: Float = 1, _ amp: (Double) -> Double) -> [Int16] {
    let n = Int(seconds * rate)
    var out = [Int16](repeating: 0, count: n * 2)
    for i in 0..<n {
        let t = Double(i) / rate
        let v = amp(t) * sin(2 * .pi * hz * t)
        out[i * 2] = Int16(max(-1, min(1, v * Double(left))) * 32767)
        out[i * 2 + 1] = Int16(max(-1, min(1, v * Double(right))) * 32767)
    }
    return out
}

/// The level is `level[i]` (or 0.8) inside burst i and 0 outside. `starts` in seconds.
/// Use starts and lengths that are whole waves of the tone: a burst cut in the middle of a wave makes a click.
private func bursts(_ starts: [Double], length: Double, level: [Double]? = nil) -> (Double) -> Double {
    { t in
        for (i, s) in starts.enumerated() where t >= s && t < s + length { return level?[i] ?? 0.8 }
        return 0
    }
}

private func run(_ s: [Int16], tuning: HapticTuning = HapticTuning(), block: Int = 548) -> [HapticEvent] {
    var d = HapticDetector(sampleRate: rate, tuning: tuning)
    var events: [HapticEvent] = []
    let frames = s.count / 2
    var at = 0
    s.withUnsafeBufferPointer { p in
        while at < frames {
            let n = min(block, frames - at)
            d.process(p.baseAddress! + at * 2, frames: n) { events.append($0) }
            at += n
        }
    }
    return events
}

private func seconds(_ e: HapticEvent) -> Double { Double(e.frame) / rate }
private let twoWaves = 2.0 / 60     // two waves of 60 Hz

@Test func silenceGivesNothing() {
    #expect(run([Int16](repeating: 0, count: Int(rate) * 2)).isEmpty)
    #expect(run([]).isEmpty)
}

@Test func oneDeepBurstGivesOneThumpAtItsStart() {
    let e = run(sound(seconds: 1, hz: 60, bursts([0.3], length: 0.1)))
    #expect(e.count == 1)
    #expect(e.first?.kind == .thump)
    #expect(abs(seconds(e[0]) - 0.3) < 0.025)
    #expect(abs(e[0].pan) < 0.05)
}

@Test(arguments: [40.0, 60.0, 90.0]) func aSteadyDeepToneGivesOneThumpAtItsStartOnly(hz: Double) {
    let e = run(sound(seconds: 3, hz: hz, { $0 >= 0.2 ? 0.8 : 0 }))
    #expect(e.count == 1)
    #expect(abs(seconds(e[0]) - 0.2) < 0.025)
}

@Test func bassThatRisesAndFallsSlowlyGivesNothing() {
    #expect(run(sound(seconds: 4, hz: 60, { 0.8 * pow(sin(.pi * $0 / 1.0), 2) })).isEmpty)
}

@Test func aVeryQuietBurstGivesNothing() {
    #expect(run(sound(seconds: 1, hz: 60, bursts([0.3], length: 0.1, level: [0.02]))).isEmpty)
}

@Test func oneSharpClickGivesOneTick() {
    let e = run(sound(seconds: 1, hz: 3000, bursts([0.5], length: 0.02, level: [0.4])))
    #expect(e.map(\.kind) == [.tick])
}

@Test func tenBeepsInARowGiveOneTick() {
    let starts = (0..<10).map { 0.3 + Double($0) / 12 }      // 12 beeps per second, like dialogue text
    let e = run(sound(seconds: 2, hz: 3000, bursts(starts, length: 0.03, level: Array(repeating: 0.4, count: 10))))
    #expect(e.map(\.kind) == [.tick])
    #expect(abs(seconds(e[0]) - 0.3) < 0.025)
}

@Test func aRunOfSharpSoundsGivesOneTickWhenTheAverageGivesNoRest() {
    var tuning = HapticTuning()
    tuning.releaseSeconds = 0.01        // the average forgets each beep at once: only the run rule can stop a tick
    let starts = (0..<10).map { 0.3 + Double($0) / 12 }
    let e = run(sound(seconds: 2, hz: 3000, bursts(starts, length: 0.03, level: Array(repeating: 0.4, count: 10))), tuning: tuning)
    #expect(e.map(\.kind) == [.tick])
}

@Test func twoClicksFarApartGiveTwoTicks() {
    let e = run(sound(seconds: 3, hz: 3000, bursts([0.3, 1.5], length: 0.03, level: [0.4, 0.4])))
    #expect(e.map(\.kind) == [.tick, .tick])
}

@Test func aBurstOnOneSidePansToThatSide() {
    let left = run(sound(seconds: 1, hz: 60, left: 1, right: 0, bursts([0.3], length: 0.1)))
    let right = run(sound(seconds: 1, hz: 60, left: 0, right: 1, bursts([0.3], length: 0.1)))
    #expect(left.count == 1 && left[0].pan < -0.9)
    #expect(right.count == 1 && right[0].pan > 0.9)
}

@Test func aLouderBurstIsStronger() {
    let quiet = run(sound(seconds: 1, hz: 60, bursts([0.3], length: 0.1, level: [0.15])))
    let loud = run(sound(seconds: 1, hz: 60, bursts([0.3], length: 0.1, level: [0.8])))
    #expect(quiet.count == 1 && loud.count == 1)
    #expect(quiet[0].strength > 0 && quiet[0].strength < loud[0].strength && loud[0].strength <= 1)
}

@Test func aSecondThumpInsideTheGapIsDropped() {
    // the second burst is much louder, so only the gap rule can stop it
    let e = run(sound(seconds: 1, hz: 60, bursts([0.3, 0.35], length: twoWaves, level: [0.15, 0.9])))
    #expect(e.count == 1)
}

@Test func aSecondThumpWhileTheFirstStillPlaysIsDropped() {
    // Feel test 2026-11-19: a thump must last about 0.2 s to be felt. A second one 0.2 s later would make a buzz.
    let e = run(sound(seconds: 1.5, hz: 60, bursts([0.3, 0.5], length: twoWaves, level: [0.1, 0.9])))
    #expect(e.count == 1)
}

@Test func aThumpSoonAfterAnotherIsSofter() {
    // 0.3 s apart: after the gap (0.25 s), inside the soften time (0.35 s)
    let after = run(sound(seconds: 1.5, hz: 60, bursts([0.3, 0.6], length: twoWaves, level: [0.1, 0.9])))
    let alone = run(sound(seconds: 1.5, hz: 60, bursts([0.6], length: twoWaves, level: [0.9])))
    #expect(after.count == 2 && alone.count == 1)
    #expect(after[1].strength < alone[0].strength)
}

@Test func equalThumpsInAFastRowGetRest() {
    let e = run(sound(seconds: 2, hz: 60, bursts([0.3, 0.4, 0.5, 0.6], length: twoWaves)))
    #expect(e.count >= 1 && e.count < 4)
}

@Test func noMoreThanSixThumpsInOneSecond() {
    var tuning = HapticTuning()
    tuning.releaseSeconds = 0.01        // no rest from the average: only the limit can stop a thump
    tuning.softenSeconds = 0
    tuning.thumpGapSeconds = 0.05       // and no help from the gap rule
    tuning.maxThumpsPerSecond = 6
    let starts = (0..<10).map { 0.1 + Double($0) * 0.1 }
    #expect(run(sound(seconds: 1.3, hz: 60, bursts(starts, length: twoWaves)), tuning: tuning).count == 6)
}

@Test func aThumpAndAClickTogetherGiveTheThumpOnly() {
    var both = sound(seconds: 1, hz: 60, bursts([0.3], length: 0.1))
    let click = sound(seconds: 1, hz: 3000, bursts([0.3], length: 0.02, level: [0.3]))
    for i in both.indices { both[i] = Int16(max(-32767, min(32767, Int(both[i]) / 2 + Int(click[i])))) }
    #expect(run(both).map(\.kind) == [.thump])
}

@Test func aClickJustBeforeAThumpIsDropped() {
    // The click starts 10 ms before the deep burst: its tick waits one window, and the thump cancels it.
    var both = sound(seconds: 1, hz: 60, { $0 >= 0.302 && $0 < 0.402 ? 0.8 : 0 })
    let click = sound(seconds: 1, hz: 3000, bursts([0.292], length: 0.006, level: [0.3]))
    for i in both.indices { both[i] = Int16(max(-32767, min(32767, Int(both[i]) / 2 + Int(click[i])))) }
    #expect(run(both).map(\.kind) == [.thump])
}

@Test func aBurstCutInTheMiddleOfAWaveGivesAThumpThenATick() {
    // 0.0375 s = 2.25 waves of 60 Hz: the sound stops at its top, and that step is a click
    #expect(run(sound(seconds: 1, hz: 60, bursts([0.3], length: 0.0375))).map(\.kind) == [.thump, .tick])
}

@Test func theBlockSizeDoesNotChangeTheEvents() {
    let s = sound(seconds: 2, hz: 60, bursts([0.3, 1.2], length: 0.1))
    let normal = run(s, block: 548)
    #expect(normal.count == 2)
    #expect(run(s, block: 1) == normal)
    #expect(run(s, block: 5000) == normal)
}

@Test func loudNoiseGivesOnlyValuesInRange() {
    var noise = [Int16](repeating: 0, count: Int(rate) * 2)
    var seed: UInt64 = 1
    for i in noise.indices {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        noise[i] = Int16(truncatingIfNeeded: Int(seed >> 33))
    }
    let e = run(noise)
    #expect(!e.isEmpty)
    for event in e {
        #expect(event.strength > 0 && event.strength <= 1)
        #expect(event.pan >= -1 && event.pan <= 1)
    }
}

@Test func anEngineThatGivesNoEffectsKeepsTheFullSound() {
    // A game with its sound on the old path: the engine has the effects output, but nothing comes out of it.
    var source = HapticSource()
    let taken = [false, false].map { source.takes(effects: $0) }
    #expect(taken == [true, true])
}

@Test func afterTheFirstEffectsBlockTheFullSoundIsNotUsed() {
    var source = HapticSource()
    // full (before the sound chip starts), effects, full (else the music gives rumble again), effects
    let taken = [false, true, false, true].map { source.takes(effects: $0) }
    #expect(taken == [true, true, false, true])
}
