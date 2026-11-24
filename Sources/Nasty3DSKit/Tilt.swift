/// What the tilt sensor of the 3DS reads, in g. The axes are the engine's (motion_emu.cpp, hid.cpp):
/// x = left and right, y = out of the lower screen, z = from the player to the hinge.
public struct Tilt: Equatable, Sendable {
    public var x, y, z: Float

    public init(x: Float, y: Float, z: Float) { self.x = x; self.y = y; self.z = z }

    /// The console lies flat on a table: the engine's own value for a console at rest.
    public static let upright = Tilt(x: 0, y: -1, z: 0)

    /// The console is upside down in the player's hands: gravity pulls to the hinge and out of the
    /// lower screen (30 degrees past vertical). Citra players get the same turn with a 90 degree
    /// tilt to the hinge (0, 0, 1). The value a game needs is not in any document: N3_FLIP_ACCEL
    /// tries another one.
    public static let upsideDown = Tilt(x: 0, y: 0.5, z: 0.866)

    /// Diagnosis: "x,y,z" in g, each from -2 to 2. Nil for any other text.
    public init?(text: String) {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
            .map { Float($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 3, let x = parts[0], let y = parts[1], let z = parts[2],
              [x, y, z].allSatisfy({ $0.isFinite && abs($0) <= 2 }) else { return nil }
        self.init(x: x, y: y, z: z)
    }
}
