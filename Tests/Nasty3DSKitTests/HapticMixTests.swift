import Foundation
import Testing
@testable import Nasty3DSKit

private func thump(_ strength: Float = 1, pan: Float = 0) -> HapticEvent { HapticEvent(kind: .thump, strength: strength, pan: pan, frame: 0) }
private func tick(_ strength: Float = 1) -> HapticEvent { HapticEvent(kind: .tick, strength: strength, pan: 0, frame: 0) }
private func scratchDefaults() -> UserDefaults {
    let name = "haptic-tests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

@Test func sliderAtZeroIsSilent() {
    #expect(HapticMix.plan(thump(), slider: 0).isSilent)
    #expect(HapticMix.plan(tick(), slider: 0).isSilent)
    var floor = HapticShape(); floor.motorFloor = 0.3
    #expect(HapticMix.plan(thump(), slider: 0, shape: floor).isSilent)     // the floor must not turn "off" into rumble
}

@Test func aThumpUsesTheHandlesAndATickUsesTheTriggers() {
    let t = HapticMix.plan(thump(), slider: 100)
    #expect(t.leftHandle == 1 && t.rightHandle > 0 && t.rightHandle < t.leftHandle && t.triggers == 0)
    #expect(t.leftSeconds > t.rightSeconds && t.rightSeconds > 0)
    let k = HapticMix.plan(tick(), slider: 100)
    #expect(k.triggers > 0 && k.triggerSeconds > 0 && k.leftHandle == 0 && k.rightHandle == 0)
}

@Test func moreSliderIsMoreLevel() {
    let low = HapticMix.plan(thump(), slider: 30), high = HapticMix.plan(thump(), slider: 90)
    #expect(low.leftHandle < high.leftHandle && low.rightHandle < high.rightHandle)
    #expect(low.leftSeconds == high.leftSeconds)        // the slider changes the strength, not the length
}

@Test func aStrongerHitIsLonger() {
    #expect(HapticMix.plan(thump(0.2), slider: 100).leftSeconds < HapticMix.plan(thump(1), slider: 100).leftSeconds)
}

@Test func aWeakHitIsNeverShorterThanTheShape() {
    // Feel test 2026-11-19: an event under about 0.12 s is not felt. A weak hit is weaker, not shorter.
    let shape = HapticShape()
    for strength: Float in [0.01, 0.2, 0.5] {
        let p = HapticMix.plan(thump(strength), slider: 1, shape: shape)
        #expect(p.leftSeconds >= shape.thumpSeconds && p.rightSeconds >= shape.bodySeconds)
    }
}

@Test func panLowersOneHandButNeverToZero() {
    var shape = HapticShape(); shape.motorFloor = 0        // no floor: only the pan rule can keep a hand above zero
    let centre = HapticMix.plan(thump(), slider: 100, shape: shape)
    let right = HapticMix.plan(thump(pan: 1), slider: 100, shape: shape), left = HapticMix.plan(thump(pan: -1), slider: 100, shape: shape)
    #expect(right.leftHandle < centre.leftHandle && right.leftHandle > 0.3 && right.rightHandle == centre.rightHandle)
    #expect(left.rightHandle < centre.rightHandle && left.rightHandle > 0.15 && left.leftHandle == centre.leftHandle)
}

@Test func theMotorFloorLiftsWeakHits() {
    var shape = HapticShape(); shape.motorFloor = 0.3
    let weak = HapticMix.plan(thump(0.05), slider: 10, shape: shape)
    #expect(weak.leftHandle >= 0.3 && weak.leftHandle < 0.35)
    #expect(HapticMix.plan(thump(1), slider: 100, shape: shape).leftHandle == 1)
}

@Test func badNumbersGiveSafeLevels() {
    for event in [thump(.nan), thump(.infinity), thump(-3), thump(7, pan: .nan), thump(1, pan: 99), tick(.nan)] {
        for slider in [-50, 0, 100, 9000] {
            let p = HapticMix.plan(event, slider: slider)
            for v in [p.leftHandle, p.rightHandle, p.triggers] { #expect(v >= 0 && v <= 1) }
            for s in [p.leftSeconds, p.rightSeconds, p.triggerSeconds] { #expect(s >= 0 && s < 1) }
        }
    }
    #expect(HapticMix.plan(thump(.nan), slider: 100).isSilent)
    #expect(HapticMix.plan(thump(), slider: 9000) == HapticMix.plan(thump(), slider: 100))
}

@Test func theDelayPutsTheEventOnItsSound() {
    var shape = HapticShape(); shape.leadSeconds = 0.03
    // 50 ms of sound waits in the buffer, the event is 327 frames (10 ms) into the block: 60 ms less the lead time
    #expect(abs(HapticMix.delay(bufferedSeconds: 0.05, offsetFrames: 327, sampleRate: 32700, shape: shape) - 0.03) < 0.0001)
    // the event started before this block
    #expect(abs(HapticMix.delay(bufferedSeconds: 0.05, offsetFrames: -327, sampleRate: 32700, shape: shape) - 0.01) < 0.0001)
}

@Test func theDelayIsNeverNegativeOrLong() {
    #expect(HapticMix.delay(bufferedSeconds: 0, offsetFrames: -5000, sampleRate: 32728) == 0)
    #expect(HapticMix.delay(bufferedSeconds: .nan, offsetFrames: 0, sampleRate: 32728) == 0)
    #expect(HapticMix.delay(bufferedSeconds: 0.05, offsetFrames: 0, sampleRate: 0) == 0)
    #expect(HapticMix.delay(bufferedSeconds: 60, offsetFrames: 0, sampleRate: 32728) == 0.5)
}

@Test func theKeyHasSixteenHexDigits() {
    #expect(HapticStrength.key(programID: 0x0004_0000_0005_5D00, fileName: "x.cci") == "haptics.strength.0004000000055d00")
    #expect(HapticStrength.key(programID: 1, fileName: "x.cci") == "haptics.strength.0000000000000001")
    #expect(HapticStrength.key(programID: .max, fileName: "x.cci") == "haptics.strength.ffffffffffffffff")
    #expect(HapticStrength.key(programID: nil, fileName: "Home Brew.3dsx") == "haptics.strength.file.Home Brew.3dsx")
}

@Test func aNewGameStartsAtSixty() {
    #expect(HapticStrength.load("haptics.strength.0000000000000001", from: scratchDefaults()) == 60)
}

@Test func offStaysOff() {
    let d = scratchDefaults()
    HapticStrength.save(0, key: "k", to: d)
    #expect(HapticStrength.load("k", from: d) == 0)        // 0 is a choice, not "no value"
}

@Test func eachGameKeepsItsOwnValue() {
    let d = scratchDefaults()
    HapticStrength.save(25, key: "a", to: d)
    HapticStrength.save(90, key: "b", to: d)
    #expect(HapticStrength.load("a", from: d) == 25 && HapticStrength.load("b", from: d) == 90)
}

@Test func storedValuesOutOfRangeAreClamped() {
    let d = scratchDefaults()
    HapticStrength.save(500, key: "k", to: d)
    #expect(HapticStrength.load("k", from: d) == 100)
    d.set(-7, forKey: "k")
    #expect(HapticStrength.load("k", from: d) == 0)
    d.set("loud", forKey: "k")
    #expect(HapticStrength.load("k", from: d) == 60)       // not a number: the standard value
}
