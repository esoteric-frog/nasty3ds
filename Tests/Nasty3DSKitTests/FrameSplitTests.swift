import Testing
@testable import Nasty3DSKit

/// The exact conversion in Azahar's src/citra_libretro/input/mouse_tracker.cpp.
private func corePixel(_ p: Int16, _ size: Int) -> Int {
    Int(Float(Int(p) + 0x7fff) / Float(0x7fff * 2) * Float(size))
}

@Test func rectsAt1x() {
    let s = FrameSplit(frameWidth: 400, frameHeight: 480)
    #expect(s.top == PixelRect(x: 0, y: 0, width: 400, height: 240))
    #expect(s.lower == PixelRect(x: 40, y: 240, width: 320, height: 240))
}

@Test func rectsAt3x() {
    let s = FrameSplit(frameWidth: 1200, frameHeight: 1440)
    #expect(s.top == PixelRect(x: 0, y: 0, width: 1200, height: 720))
    #expect(s.lower == PixelRect(x: 120, y: 720, width: 960, height: 720))
}

@Test func unitRectOfLower() {
    let u = FrameSplit(frameWidth: 400, frameHeight: 480).unitRect(PixelRect(x: 40, y: 240, width: 320, height: 240))
    #expect(u.x == 0.1 && u.y == 0.5 && u.width == 0.8 && u.height == 0.5)
}

@Test(arguments: [(400, 480), (1200, 1440)])
func cornersAndCenterRoundTripInsideTheLowerScreen(w: Int, h: Int) {
    let s = FrameSplit(frameWidth: w, frameHeight: h)
    let points: [(Double, Double)] = [(0, 0), (1, 0), (0, 1), (1, 1), (0.5, 0.5)]
    for (u, v) in points {
        let p = s.pointer(u: u, v: v)
        let px = corePixel(p.x, w), py = corePixel(p.y, h)
        #expect(px >= s.lower.x && px < s.lower.x + s.lower.width, "u=\(u) px=\(px)")
        #expect(py >= s.lower.y && py < s.lower.y + s.lower.height, "v=\(v) py=\(py)")
    }
    // corners land on the first and last pixel
    #expect(corePixel(s.pointer(u: 0, v: 0).x, w) == s.lower.x)
    #expect(corePixel(s.pointer(u: 1, v: 1).x, w) == s.lower.x + s.lower.width - 1)
    #expect(corePixel(s.pointer(u: 1, v: 1).y, h) == s.lower.y + s.lower.height - 1)
}

@Test func outOfRangeInputIsClamped() {
    let s = FrameSplit(frameWidth: 400, frameHeight: 480)
    #expect(s.pointer(u: -3, v: 7).x == s.pointer(u: 0, v: 1).x)
    #expect(s.pointer(u: -3, v: 7).y == s.pointer(u: 0, v: 1).y)
}

@Test func pointerIsNeverExactlyZeroZero() {
    // The core ignores a pointer at exactly (0, 0).
    let s = FrameSplit(frameWidth: 400, frameHeight: 480)
    for u in stride(from: 0.0, through: 1.0, by: 0.01) {
        let p = s.pointer(u: u, v: 0)
        #expect(!(p.x == 0 && p.y == 0))
    }
}
