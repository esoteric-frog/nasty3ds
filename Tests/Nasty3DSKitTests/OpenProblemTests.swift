import Testing
@testable import Nasty3DSKit

// Findings from the Part 1 reviews, each pinned by a test.

@Test func aPartialWriteNeverSplitsAStereoFrame() {
    // capacity 8, 3 samples free: a 4-sample write must store 2 (one frame), not 3.
    let rb = RingBuffer(capacity: 8)
    let ten: [Int16] = [1, -1, 2, -2, 3, -3, 4, -4, 5, -5]
    _ = ten.withUnsafeBufferPointer { rb.write($0.baseAddress!, count: 10) }
    var out = [Int16](repeating: 0, count: 3)
    _ = out.withUnsafeMutableBufferPointer { rb.read(into: $0.baseAddress!, count: 3) }
    let four: [Int16] = [6, -6, 7, -7]
    let stored = four.withUnsafeBufferPointer { rb.write($0.baseAddress!, count: 4) }
    #expect(stored == 2)
    #expect(rb.available % 2 == 1)      // 5 left from before + 2: the odd read is the caller's, the write stays whole
}

@Test func ringBufferEdgeSizesDoNotTrap() {
    let empty = RingBuffer(capacity: 0)
    let one: [Int16] = [1, 2]
    #expect(one.withUnsafeBufferPointer { empty.write($0.baseAddress!, count: 2) } == 0)
    var out: [Int16] = [9, 9]
    #expect(out.withUnsafeMutableBufferPointer { empty.read(into: $0.baseAddress!, count: 2) } == 0)
    #expect(out == [0, 0])
    let rb = RingBuffer(capacity: 4)
    #expect(one.withUnsafeBufferPointer { rb.write($0.baseAddress!, count: -5) } == 0)
    #expect(out.withUnsafeMutableBufferPointer { rb.read(into: $0.baseAddress!, count: -5) } == 0)
}

@Test func aStickThatIsNotANumberReadsAsCentre() {
    let m = ControllerMap.automatic
    #expect(m.analog(index: 0, id: 0, pad: PadSnapshot(pressed: [], lx: .nan)) == 0)
    #expect(m.analog(index: 1, id: 1, pad: PadSnapshot(pressed: [], ry: .nan)) == 0)
    #expect(m.analog(index: 0, id: 0, pad: PadSnapshot(pressed: [], lx: .infinity)) == 32767)
}

@Test func aControllerMapCanBeMadeOutsideTheModule() {
    let m = ControllerMap(table: [.a: .buttonA])
    #expect(m.joypad(id: N3DSControl.a.retroID, pad: PadSnapshot(pressed: [.buttonA])) == 1)
}

/// The exact conversion in Azahar's mouse_tracker.cpp.
private func corePixel(_ p: Int16, _ size: Int) -> Int { Int(Float(Int(p) + 0x7fff) / Float(0x7fff * 2) * Float(size)) }

@Test(arguments: [(400, 480), (1200, 1440), (401, 481)])
func aTouchLandsOnThePixelUnderTheFinger(w: Int, h: Int) {
    // Every sample point across the lower screen, edges of pixels included: floor(t * size).
    let s = FrameSplit(frameWidth: w, frameHeight: h)
    var wrong = 0
    for i in 0...(s.lower.width * 4) {
        let u = Double(i) / Double(s.lower.width * 4)
        let want = min(s.lower.width - 1, Int(u * Double(s.lower.width)))
        if corePixel(s.pointer(u: u, v: 0.5).x, w) - s.lower.x != want { wrong += 1 }
    }
    for i in 0...(s.lower.height * 4) {
        let v = Double(i) / Double(s.lower.height * 4)
        let want = min(s.lower.height - 1, Int(v * Double(s.lower.height)))
        if corePixel(s.pointer(u: 0.5, v: v).y, h) - s.lower.y != want { wrong += 1 }
    }
    #expect(wrong == 0)
}

@Test func aTinyFrameDoesNotTrap() {
    for (w, h) in [(0, 0), (1, 1), (2, 2), (3, 5)] {
        let s = FrameSplit(frameWidth: w, frameHeight: h)
        _ = s.pointer(u: 0.5, v: 0.5)
        _ = s.pointer(u: 1, v: 1)
    }
}

@Test func catchUpNeverPushesMoreSoundThanTheBufferHasRoomFor() {
    let base = 1.0 / 60
    // 95 ms behind, buffer empty (fill 0), buffer holds 100 ms: catch up at most the room in the buffer.
    let allowed = Pacing.catchUpDebt(behind: 0.095, fill: 0, bufferSeconds: 0.1, base: base)
    #expect(allowed <= 0.1 - base && allowed > 0.05)
    // buffer already 90% full: almost no catch-up
    #expect(Pacing.catchUpDebt(behind: 0.095, fill: 0.9, bufferSeconds: 0.1, base: base) <= 0.011)
    // a small debt stays as it is
    #expect(Pacing.catchUpDebt(behind: 0.02, fill: 0.2, bufferSeconds: 0.1, base: base) == 0.02)
    // never negative, and bad input is safe
    #expect(Pacing.catchUpDebt(behind: 0.5, fill: 1.5, bufferSeconds: 0.1, base: base) == 0)
    #expect(Pacing.catchUpDebt(behind: 0.05, fill: .nan, bufferSeconds: 0.1, base: base) == 0)
    #expect(Pacing.catchUpDebt(behind: -1, fill: 0, bufferSeconds: 0.1, base: base) == 0)
}

@Test func pacingGainIsLinearNearTheTarget() {
    let base = 1.0 / 60
    #expect(abs(Pacing.frameTime(base: base, fill: 0.75) - base * 1.01) < 1e-12)     // a cubic gain would fail this
    #expect(Pacing.frameTime(base: base, fill: 0.7, target: 0) == base)
    #expect(Pacing.frameTime(base: base, fill: .infinity) == base)
}
