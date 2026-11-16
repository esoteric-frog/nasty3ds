/// Latest frame wins. One frame is on its way at a time; a newer frame replaces any frame that waits.
public struct FrameGate<Frame> {
    private var sending = false
    private var waiting: Frame?

    public init() {}

    /// The frame to send now, or nil when a send is in progress.
    public mutating func offer(_ frame: Frame) -> Frame? {
        if sending {
            waiting = frame
            return nil
        }
        sending = true
        return frame
    }

    /// Call when a send ends. Returns the next frame to send, or nil.
    public mutating func sendFinished() -> Frame? {
        if let next = waiting {
            waiting = nil
            return next
        }
        sending = false
        return nil
    }

    public mutating func reset() {
        sending = false
        waiting = nil
    }
}
