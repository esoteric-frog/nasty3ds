import Foundation

/// How one event feels on the motors. The values come from the feel test with the real controller
/// (Xbox Wireless Controller over Bluetooth, 2026-11-19). The motors are spinning weights: an event
/// under about 0.12 s is not felt at all, so a weak hit is weaker, never shorter.
public struct HapticShape: Sendable {
    public var thumpSeconds = 0.20      // heavy motor (left handle), for the weakest hit. The owner's pick ("boom")
    public var bodySeconds = 0.14       // light motor (right handle), for the weakest hit. Alone it is felt from 0.12 s
    public var thumpGrow = 0.3          // a hit at full strength is this much longer
    public var bodyLevel: Float = 0.6   // light motor level against the heavy motor
    public var fade = true              // the level falls to zero over the event (a drum hit), or stays flat
    public var tickSeconds = 0.16       // trigger motors. Felt from 0.12 s at full level; 0.08 s is not felt
    public var tickLevel: Float = 1
    public var tickTransient = false    // play ticks as Core Haptics "transient" events (not felt in the feel test)
    public var motorFloor: Float = 0.3  // the lowest level that is felt with a fade at 0.20 s (0.2 is not); weaker hits start here
    public var panDepth: Float = 0.4    // how much a sound on one side lowers the other hand; under 1 = never to zero
    public var leadSeconds = 0.08       // time a motor needs to spin up: an event starts this much before its sound
    public init() {}
}

/// What each motor does for one event. Levels are 0...1. A level of 0 = that motor does nothing.
public struct MotorPlan: Equatable, Sendable {
    public var leftHandle: Float = 0, rightHandle: Float = 0, triggers: Float = 0
    public var leftSeconds = 0.0, rightSeconds = 0.0, triggerSeconds = 0.0
    public var isSilent: Bool { leftHandle <= 0 && rightHandle <= 0 && triggers <= 0 }
    public init() {}
}

public enum HapticMix {
    /// `slider` is the game's strength, 0...100. At 0 the plan is silent.
    public static func plan(_ event: HapticEvent, slider: Int, shape: HapticShape = HapticShape()) -> MotorPlan {
        var plan = MotorPlan()
        let gain = Float(max(0, min(100, slider))) / 100
        let strength = event.strength.isFinite ? max(0, min(1, event.strength)) : 0
        guard gain > 0, strength > 0 else { return plan }
        func level(_ x: Float) -> Float { min(1, shape.motorFloor + (1 - shape.motorFloor) * x) }
        switch event.kind {
        case .thump:
            let pan = event.pan.isFinite ? max(-1, min(1, event.pan)) : 0
            plan.leftHandle = level(strength * gain * (1 - shape.panDepth * max(0, pan)))
            plan.rightHandle = level(strength * gain * shape.bodyLevel * (1 - shape.panDepth * max(0, -pan)))
            let length = 1 + shape.thumpGrow * Double(strength)      // a stronger hit is a little longer
            plan.leftSeconds = shape.thumpSeconds * length
            plan.rightSeconds = shape.bodySeconds * length
        case .tick:
            plan.triggers = level(strength * gain * shape.tickLevel)
            plan.triggerSeconds = shape.tickSeconds
        }
        return plan
    }

    /// Seconds to wait before the motors start, so the event lands with its sound.
    /// `bufferedSeconds`: the sound that waits in the buffer in front of this block.
    /// `offsetFrames`: where the event starts, counted from the start of this block. It can be
    /// negative: the detector reports a window after the window ends.
    public static func delay(bufferedSeconds: Double, offsetFrames: Int, sampleRate: Double, shape: HapticShape = HapticShape()) -> Double {
        guard bufferedSeconds.isFinite, sampleRate > 0 else { return 0 }
        return max(0, min(0.5, bufferedSeconds + Double(offsetFrames) / sampleRate - shape.leadSeconds))
    }
}

/// The strength slider value of each game, 0...100. 0 = off.
public enum HapticStrength {
    public static let standard = 60

    public static func key(programID: UInt64?, fileName: String) -> String {
        guard let programID else { return "haptics.strength.file." + fileName }
        let hex = String(programID, radix: 16)
        return "haptics.strength." + String(repeating: "0", count: 16 - hex.count) + hex
    }

    public static func load(_ key: String, from defaults: UserDefaults = .standard) -> Int {
        guard let stored = defaults.object(forKey: key) as? Int else { return standard }    // 0 is a real value: off
        return max(0, min(100, stored))
    }

    public static func save(_ value: Int, key: String, to defaults: UserDefaults = .standard) {
        defaults.set(max(0, min(100, value)), forKey: key)
    }
}
