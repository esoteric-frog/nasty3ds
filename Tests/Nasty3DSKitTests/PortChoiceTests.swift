import Testing
@testable import Nasty3DSKit

private let r = PortChoice.retries, fresh = PortChoice.freshTries

@Test func aFreshPairingTakesRandomPortsAndRemembersThem() {
    var n: UInt16 = 30000
    for attempt in 0..<fresh {
        let step = PortChoice.step(remembered: 0, backup: nil, attempt: attempt) { n += 1; return n }
        #expect(step == PortChoice.Step(port: n, remember: true, wait: 0))
    }
    #expect(PortChoice.step(remembered: 0, backup: nil, attempt: fresh) == nil)
}

@Test func theRememberedPortIsTriedAgainBeforeASessionPort() {
    let waits = (0...r).map { PortChoice.step(remembered: 61141, backup: nil, attempt: $0, random: { 1 }) }
    #expect(waits.allSatisfy { $0?.port == 61141 && $0?.remember == true })
    #expect(waits.map { $0?.wait } == [0] + Array(repeating: PortChoice.retryDelay, count: r))
    for k in 0..<fresh {
        let step = PortChoice.step(remembered: 61141, backup: nil, attempt: r + 1 + k, random: { 23456 })
        #expect(step == PortChoice.Step(port: 23456, remember: false, wait: 0))
    }
    #expect(PortChoice.step(remembered: 61141, backup: nil, attempt: r + 1 + fresh) == nil)
}

@Test func theLiveListenerTriesItsBackupPortBeforeASessionPort() {
    for k in 0...r {
        let step = PortChoice.step(remembered: 61141, backup: 31000, attempt: r + 1 + k, random: { 1 })
        #expect(step == PortChoice.Step(port: 31000, remember: false, wait: k == 0 ? 0 : PortChoice.retryDelay))
    }
    let session = PortChoice.step(remembered: 61141, backup: 31000, attempt: 2 * (r + 1), random: { 23456 })
    #expect(session == PortChoice.Step(port: 23456, remember: false, wait: 0))
    #expect(PortChoice.step(remembered: 61141, backup: 31000, attempt: 2 * (r + 1) + fresh) == nil)
    // A backup equal to the remembered port is no backup.
    #expect(PortChoice.step(remembered: 61141, backup: 61141, attempt: r + 1, random: { 23456 })?.port == 23456)
}

@Test func randomPortsAreBelowTheSystemsOutboundRange() {
    for _ in 0..<500 {
        let port = PortChoice.step(remembered: 0, backup: nil, attempt: 0)!.port
        #expect(PortChoice.range.contains(port) && port < 49152)
    }
}
