import Foundation

/// Int16 sample queue between the emulation thread (write) and the audio thread (read).
// ponytail: one NSLock, held for a short copy. Change to a lock-free SPSC queue only if
// audio glitches are traced to this lock.
public final class RingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let storage: UnsafeMutablePointer<Int16>
    private let capacity: Int
    private var head = 0      // next read index
    private var count = 0

    public init(capacity: Int) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit { storage.deallocate() }

    public var available: Int { lock.withLock { count } }

    public func write(_ p: UnsafePointer<Int16>, count n: Int) -> Int {
        lock.withLock {
            guard n > 0, capacity > 0 else { return 0 }
            var take = min(n, capacity - count)
            if take < n { take &= ~1 }      // a cut write keeps whole stereo frames (left + right)
            var tail = (head + count) % capacity
            for i in 0..<take {
                storage[tail] = p[i]
                tail = (tail + 1) % capacity
            }
            count += take
            return take
        }
    }

    public func read(into p: UnsafeMutablePointer<Int16>, count n: Int) -> Int {
        lock.withLock {
            guard n > 0 else { return 0 }
            let take = min(n, count)
            for i in 0..<take {
                p[i] = storage[head]
                head = (head + 1) % capacity
            }
            for i in take..<n { p[i] = 0 }
            count -= take
            return take
        }
    }
}
