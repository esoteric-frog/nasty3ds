/// Which port a listener tries, and whether the server may remember it.
/// The saved home screen icon holds the page port, so the remembered ports change only when there
/// are none yet (or on "Forget Phone"). A busy port gets a port for this session only.
public enum PortChoice {
    public static let retries = 20              // tries of the remembered port after the first
    public static let retryDelay = 0.1          // seconds; a cancelled listener frees its port in about 60 ms
    public static let freshTries = 20
    /// Below the system's outbound range (49152 and up): no other program gets these by chance.
    public static let range: ClosedRange<UInt16> = 20000...45000

    public struct Step: Equatable, Sendable {
        public let port: UInt16
        public let remember: Bool
        public let wait: Double
        public init(port: UInt16, remember: Bool, wait: Double) { self.port = port; self.remember = remember; self.wait = wait }
    }

    /// `attempt` counts from 0. Nil = give up.
    /// remembered == 0: a random port in `range`, remember: true, for `freshTries` attempts.
    /// remembered != 0: the remembered port for attempts 0...retries (wait 0, then retryDelay),
    ///   then the `backup` port the same way (the live listener has one; the page knows it too),
    ///   then a random port in `range` with remember: false (this session only) for `freshTries` attempts.
    public static func step(remembered: UInt16, backup: UInt16?, attempt: Int,
                            random: () -> UInt16 = { .random(in: range) }) -> Step? {
        guard attempt >= 0 else { return nil }
        if remembered == 0 { return attempt < freshTries ? Step(port: random(), remember: true, wait: 0) : nil }
        var k = attempt
        if k <= retries { return Step(port: remembered, remember: true, wait: k == 0 ? 0 : retryDelay) }
        k -= retries + 1
        if let backup, backup != 0, backup != remembered {
            if k <= retries { return Step(port: backup, remember: false, wait: k == 0 ? 0 : retryDelay) }
            k -= retries + 1
        }
        return k < freshTries ? Step(port: random(), remember: false, wait: 0) : nil
    }
}
