import Testing
@testable import Nasty3DSKit

private func write(_ rb: RingBuffer, _ a: [Int16]) -> Int { a.withUnsafeBufferPointer { rb.write($0.baseAddress!, count: a.count) } }
private func read(_ rb: RingBuffer, _ n: Int) -> (got: Int, data: [Int16]) {
    var out = [Int16](repeating: 99, count: n)
    let got = out.withUnsafeMutableBufferPointer { rb.read(into: $0.baseAddress!, count: n) }
    return (got, out)
}

@Test func readsWhatWasWritten() {
    let rb = RingBuffer(capacity: 8)
    #expect(write(rb, [1, 2, 3]) == 3)
    #expect(rb.available == 3)
    let r = read(rb, 3)
    #expect(r.got == 3 && r.data == [1, 2, 3])
}

@Test func wrapsAcrossTheEnd() {
    let rb = RingBuffer(capacity: 4)
    _ = write(rb, [1, 2, 3]); _ = read(rb, 3)
    #expect(write(rb, [4, 5, 6]) == 3)        // crosses the wrap point
    #expect(read(rb, 3).data == [4, 5, 6])
}

@Test func underrunGivesSilence() {
    let rb = RingBuffer(capacity: 8)
    _ = write(rb, [7, 8])
    let r = read(rb, 5)
    #expect(r.got == 2 && r.data == [7, 8, 0, 0, 0])
    #expect(read(rb, 2).data == [0, 0])        // empty buffer
}

@Test func overrunDropsTheExtraSamples() {
    let rb = RingBuffer(capacity: 4)
    #expect(write(rb, [1, 2, 3, 4, 5, 6]) == 4)
    #expect(write(rb, [9]) == 0)
    #expect(read(rb, 4).data == [1, 2, 3, 4])
}
