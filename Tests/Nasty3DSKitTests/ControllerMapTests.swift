import Testing
@testable import Nasty3DSKit

// libretro joypad ids, from libretro.h
private let B: UInt32 = 0, Y: UInt32 = 1, SELECT: UInt32 = 2, START: UInt32 = 3
private let UP: UInt32 = 4, DOWN: UInt32 = 5, LEFT: UInt32 = 6, RIGHT: UInt32 = 7
private let A: UInt32 = 8, X: UInt32 = 9, L: UInt32 = 10, R: UInt32 = 11, L2: UInt32 = 12, R2: UInt32 = 13

private func pad(_ e: PadElement...) -> PadSnapshot { PadSnapshot(pressed: Set(e)) }

@Test func faceButtonsMapByPosition() {
    let m = ControllerMap.automatic
    // Xbox B is the right button. The 3DS A is the right button. libretro A is id 8.
    #expect(m.joypad(id: A, pad: pad(.buttonB)) == 1)
    #expect(m.joypad(id: B, pad: pad(.buttonA)) == 1)
    #expect(m.joypad(id: X, pad: pad(.buttonY)) == 1)
    #expect(m.joypad(id: Y, pad: pad(.buttonX)) == 1)
    #expect(m.joypad(id: A, pad: pad(.buttonA)) == 0)
}

@Test func everyControlHasOneElement() {
    let m = ControllerMap.automatic
    #expect(Set(m.table.keys) == Set(N3DSControl.allCases))
    #expect(Set(m.table.values).count == N3DSControl.allCases.count)
}

@Test func shouldersTriggersDpadStartSelect() {
    let m = ControllerMap.automatic
    let cases: [(UInt32, PadElement)] = [
        (L, .leftShoulder), (R, .rightShoulder), (L2, .leftTrigger), (R2, .rightTrigger),
        (UP, .dpadUp), (DOWN, .dpadDown), (LEFT, .dpadLeft), (RIGHT, .dpadRight),
        (START, .menu), (SELECT, .options),
    ]
    for (id, element) in cases {
        #expect(m.joypad(id: id, pad: pad(element)) == 1, "id \(id)")
    }
}

@Test func emptySnapshotIsAllZero() {
    let m = ControllerMap.automatic
    for id in UInt32(0)..<16 { #expect(m.joypad(id: id, pad: PadSnapshot()) == 0) }
    #expect(m.analog(index: 0, id: 0, pad: PadSnapshot()) == 0)
}

@Test func sticksScaleAndFlipY() {
    let m = ControllerMap.automatic
    let p = PadSnapshot(pressed: [], lx: 1, ly: 1, rx: -1, ry: -0.5)
    #expect(m.analog(index: 0, id: 0, pad: p) == 32767)    // left X, full right
    #expect(m.analog(index: 0, id: 1, pad: p) == -32767)   // libretro Y is positive down
    #expect(m.analog(index: 1, id: 0, pad: p) == -32767)
    #expect(m.analog(index: 1, id: 1, pad: p) == 16383)
    #expect(m.analog(index: 0, id: 0, pad: PadSnapshot(pressed: [], lx: 9)) == 32767) // clamp
}

@Test func aChangedMapIsUsed() {
    var m = ControllerMap.automatic
    m.table[.a] = .buttonA
    #expect(m.joypad(id: A, pad: pad(.buttonA)) == 1)
}
