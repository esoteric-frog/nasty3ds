import Foundation

/// A message from the phone page to the app. Text, JSON, at most `maxLength` bytes.
public enum PhoneMessage: Equatable, Sendable {
    case hello(secret: String)
    case down(u: Double, v: Double)
    case move(u: Double, v: Double)
    case up
    case pong(id: Int)

    public static let maxLength = 256

    /// Nil for anything that is not exactly one of the known messages. `u` and `v` are clamped to 0...1.
    public static func parse(_ text: String) -> PhoneMessage? {
        guard text.utf8.count <= maxLength,
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = object["t"] as? String
        else { return nil }

        func unit(_ key: String) -> Double? {
            // `as? Double` also accepts a JSON string in some bridges; require a real number.
            guard let number = object[key] as? NSNumber, !(object[key] is String),
                  CFGetTypeID(number) != CFBooleanGetTypeID()
            else { return nil }
            let value = number.doubleValue
            guard value.isFinite else { return nil }
            return max(0, min(1, value))
        }

        switch type {
        case "hello":
            guard let secret = object["k"] as? String else { return nil }
            return .hello(secret: secret)
        case "down":
            guard let u = unit("u"), let v = unit("v") else { return nil }
            return .down(u: u, v: v)
        case "move":
            guard let u = unit("u"), let v = unit("v") else { return nil }
            return .move(u: u, v: v)
        case "up":
            return .up
        case "pong":
            guard let id = object["id"] as? Int, !(object["id"] is String) else { return nil }
            return .pong(id: id)
        default:
            return nil
        }
    }

    /// The display-lock report inside a pong: "held", or "no:<reason>" with letters and digits
    /// only (at most 24), so text from the page cannot put anything odd into a log line.
    public static func wakeReport(_ text: String) -> String? {
        guard text.utf8.count <= maxLength,
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              object["t"] as? String == "pong", let held = object["w"] as? Int
        else { return nil }
        if held == 1 { return "held" }
        let reason = (object["e"] as? String ?? "").unicodeScalars
            .filter { ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
        return "no:" + String(String.UnicodeScalarView(reason.prefix(24)))
    }

    public static func ping(id: Int) -> String { #"{"t":"ping","id":\#(id)}"# }
    /// `s` is one of "playing", "paused", "closed".
    public static func state(_ s: String) -> String { #"{"t":"state","s":"\#(s)"}"# }
}

/// The rules for one live connection: nothing counts before a correct hello.
public struct PhoneSession {
    public enum Action: Equatable {
        case close, authorized, touch(u: Double, v: Double), release, pong(id: Int), ignore
    }

    public private(set) var authorized = false
    private let matches: (String) -> Bool

    public init(matches: @escaping (String) -> Bool) { self.matches = matches }

    public mutating func receive(_ text: String) -> Action {
        let message = PhoneMessage.parse(text)
        guard authorized else {
            if case .hello(let secret)? = message, matches(secret) {
                authorized = true
                return .authorized
            }
            return .close
        }
        switch message {
        case .down(let u, let v)?, .move(let u, let v)?: return .touch(u: u, v: v)
        case .up?: return .release
        case .pong(let id)?: return .pong(id: id)
        case .hello?, nil: return .ignore
        }
    }
}
