import Testing
@testable import Nasty3DSKit

@Test func theFirstFrameGoesAtOnce() {
    var g = FrameGate<Int>()
    #expect(g.offer(1) == 1)
}

@Test func framesOfferedDuringASendAreReplacedByTheNewest() {
    var g = FrameGate<Int>()
    _ = g.offer(1)
    #expect(g.offer(2) == nil)
    #expect(g.offer(3) == nil)
    #expect(g.offer(4) == nil)
    #expect(g.sendFinished() == 4)      // 2 and 3 are gone: a slow phone gets the newest frame
    #expect(g.sendFinished() == nil)
}

@Test func afterAnIdleFinishTheNextFrameGoesAtOnce() {
    var g = FrameGate<Int>()
    _ = g.offer(1)
    #expect(g.sendFinished() == nil)
    #expect(g.offer(2) == 2)
}

@Test func resetForgetsASendInProgress() {
    var g = FrameGate<Int>()
    _ = g.offer(1); _ = g.offer(2)
    g.reset()                            // the phone disconnected in the middle of a send
    #expect(g.offer(3) == 3)
    #expect(g.sendFinished() == nil)
}
