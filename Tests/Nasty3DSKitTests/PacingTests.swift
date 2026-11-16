import Testing
@testable import Nasty3DSKit

private let base = 1.0 / 60.0

@Test func bufferAtTargetKeepsTheBaseFrameTime() {
    #expect(Pacing.frameTime(base: base, fill: 0.5) == base)
}

@Test func fullBufferSlowsTheEmulatorDown() {
    // The emulator makes sound faster than the sound card plays it: frames must take longer.
    #expect(abs(Pacing.frameTime(base: base, fill: 1.0) - base * 1.02) < 1e-12)
    #expect(Pacing.frameTime(base: base, fill: 0.75) > base)
}

@Test func emptyBufferSpeedsTheEmulatorUp() {
    #expect(abs(Pacing.frameTime(base: base, fill: 0.0) - base * 0.98) < 1e-12)
    #expect(Pacing.frameTime(base: base, fill: 0.25) < base)
}

@Test func theAdjustmentCoversTheMeasuredDrift() {
    // Measured: the buffer gains about 0.27% of the sample rate at 60.0 fps.
    #expect(Pacing.frameTime(base: base, fill: 1.0) / base - 1 > 0.0027)
}

@Test func outOfRangeAndBadFillAreSafe() {
    #expect(Pacing.frameTime(base: base, fill: 7) == Pacing.frameTime(base: base, fill: 1))
    #expect(Pacing.frameTime(base: base, fill: -7) == Pacing.frameTime(base: base, fill: 0))
    #expect(Pacing.frameTime(base: base, fill: .nan) == base)
}
