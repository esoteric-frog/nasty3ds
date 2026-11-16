/// Words for local play (the 3DS "local wireless" between two Nasty3DS apps).
public enum LocalPlayText {
    /// The name the other player sees. The room accepts only 4 to 20 of: letters, digits,
    /// space, dot, underscore, hyphen. The suffix keeps two Macs with the same name apart.
    public static func nickname(from computerName: String, suffix: Int) -> String {
        let allowed = computerName.unicodeScalars.filter {
            $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || " ._-".unicodeScalars.contains($0))
        }
        let words = String(String.UnicodeScalarView(allowed)).split(separator: " ").joined(separator: " ")
        let base = String(words.prefix(17)).split(separator: " ").joined(separator: " ")
        let tail = String(abs(suffix) % 100)
        return (base.isEmpty ? "Player" : base) + " " + (tail.count < 2 ? "0" + tail : tail)
    }

    /// `state` is the engine's room state: 0 none, 1 joining, 2 joined, below 0 a failed join.
    public static func status(state: Int, hosting: Bool, players: Int) -> String {
        switch state {
        case 0: return ""
        case 1: return "Local play: joining…"
        case 2:
            if hosting { return players < 2 ? "Local play: hosting, no other player yet" : "Local play: hosting, \(players) players" }
            return "Local play: joined, \(players) players"
        case -1: return "Local play: the connection was lost"
        case -4: return "Local play: that player name is in use"
        case -6: return "Local play: the two Macs have the same console data"
        case -7: return "Local play: the other Mac has a different version"
        case -9: return "Local play: the other Mac did not answer"
        case -10: return "Local play: the room is full"
        default: return state < 0 ? "Local play: could not join" : ""
        }
    }

    /// True for an IPv4 address on a local network (private, link-local or this Mac).
    public static func isLocalAddress(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map { UInt8($0) }
        guard parts.count == 4, let a = parts[0], let b = parts[1], parts[2] != nil, parts[3] != nil else { return false }
        switch (a, b) {
        case (10, _), (127, _), (192, 168), (169, 254), (172, 16...31): return true
        default: return false
        }
    }
}
