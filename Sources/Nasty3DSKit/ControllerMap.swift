/// A physical control on an Xbox-style pad, named as Apple's GameController names them.
public enum PadElement: String, CaseIterable, Codable, Sendable {
    case buttonA, buttonB, buttonX, buttonY
    case leftShoulder, rightShoulder, leftTrigger, rightTrigger
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case menu, options
}

/// A digital control on a 3DS.
public enum N3DSControl: String, CaseIterable, Codable, Sendable {
    case a, b, x, y, l, r, zl, zr, up, down, left, right, start, select

    /// RETRO_DEVICE_ID_JOYPAD_* from libretro.h. The Azahar core reads these.
    public var retroID: UInt32 {
        switch self {
        case .b: 0
        case .y: 1
        case .select: 2
        case .start: 3
        case .up: 4
        case .down: 5
        case .left: 6
        case .right: 7
        case .a: 8
        case .x: 9
        case .l: 10
        case .r: 11
        case .zl: 12
        case .zr: 13
        }
    }
}

public struct PadSnapshot: Sendable {
    public var pressed: Set<PadElement>
    public var lx: Float, ly: Float, rx: Float, ry: Float
    public init(pressed: Set<PadElement> = [], lx: Float = 0, ly: Float = 0, rx: Float = 0, ry: Float = 0) {
        self.pressed = pressed; self.lx = lx; self.ly = ly; self.rx = rx; self.ry = ry
    }
}

public struct ControllerMap: Codable, Sendable {
    public var table: [N3DSControl: PadElement]
    public init(table: [N3DSControl: PadElement]) { self.table = table }

    /// Face buttons map by position: the 3DS A is on the right, the Xbox B is on the right.
    public static let automatic = ControllerMap(table: [
        .a: .buttonB, .b: .buttonA, .x: .buttonY, .y: .buttonX,
        .l: .leftShoulder, .r: .rightShoulder, .zl: .leftTrigger, .zr: .rightTrigger,
        .up: .dpadUp, .down: .dpadDown, .left: .dpadLeft, .right: .dpadRight,
        .start: .menu, .select: .options,
    ])

    public func joypad(id: UInt32, pad: PadSnapshot) -> Int16 {
        for (control, element) in table where control.retroID == id {
            return pad.pressed.contains(element) ? 1 : 0
        }
        return 0
    }

    /// index 0 = left stick (circle pad), 1 = right stick (C-stick). id 0 = X, 1 = Y.
    public func analog(index: UInt32, id: UInt32, pad: PadSnapshot) -> Int16 {
        let v: Float
        switch (index, id) {
        case (0, 0): v = pad.lx
        case (0, 1): v = -pad.ly
        case (1, 0): v = pad.rx
        case (1, 1): v = -pad.ry
        default: return 0
        }
        guard !v.isNaN else { return 0 }
        return Int16((max(-1, min(1, v)) * 32767).rounded(.towardZero))
    }
}
