import Foundation

/// What the library shows for one game. `icon` is 48 x 48 pixels, RGBA, rows from the top.
public struct GameInfo: Sendable {
    public let programID: UInt64
    public let title: String?
    public let icon: [UInt8]?
}

/// Reads the name, the ID and the icon out of a 3DS game file (.3ds, .cci, .cxi).
/// It reads headers only (some kilobytes). It does not decrypt: an encrypted game gives the ID only.
/// Every offset comes from the file, so every read is checked against the file's length.
public enum GameFile {
    public static let extensions = ["3ds", "cci", "cxi", "zcci", "3dsx", "cia", "app"]
    public static let iconSide = 48

    public static func read(_ url: URL) -> GameInfo? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return parse { offset, count in
            guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.read(upToCount: count),
                  data.count == count else { return nil }
            return data
        }
    }

    /// `read(offset, count)` gives exactly `count` bytes, or nil when the file is too short.
    public static func parse(read: (UInt64, Int) -> Data?) -> GameInfo? {
        func u32(_ d: Data, _ o: Int) -> UInt64 { (0..<4).reduce(UInt64(0)) { $0 | UInt64(d[d.startIndex + o + $1]) << (8 * UInt64($1)) } }
        func magic(_ d: Data, _ o: Int, _ text: String) -> Bool { d.subdata(in: d.startIndex + o..<d.startIndex + o + 4) == Data(text.utf8) }

        guard let first = read(0, 0x200) else { return nil }
        var base: UInt64 = 0                                   // where the game header (NCCH) starts
        if magic(first, 0x100, "NCSD") { base = u32(first, 0x120) * 0x200 }
        guard let header = base == 0 ? first : read(base, 0x200), magic(header, 0x100, "NCCH") else { return nil }

        let programID = (0..<8).reduce(UInt64(0)) { $0 | UInt64(header[header.startIndex + 0x118 + $1]) << (8 * UInt64($1)) }
        let noInfo = GameInfo(programID: programID, title: nil, icon: nil)
        let flags = header.subdata(in: header.startIndex + 0x188..<header.startIndex + 0x190)
        guard flags[flags.startIndex + 7] & 0x4 != 0, flags[flags.startIndex + 6] < 8 else { return noInfo }     // encrypted
        let unit = UInt64(0x200) << UInt64(flags[flags.startIndex + 6])
        let table = base + u32(header, 0x1A0) * unit            // the file table (ExeFS); u32 * unit cannot overflow UInt64
        guard u32(header, 0x1A0) > 0, let entries = read(table, 0x200) else { return noInfo }

        for i in 0..<10 {
            let o = i * 16
            let name = entries.subdata(in: entries.startIndex + o..<entries.startIndex + o + 8)
            guard name == Data("icon".utf8) + Data(count: 4) else { continue }
            let size = u32(entries, o + 12)
            guard size >= 0x36C0, let smdh = read(table + 0x200 + u32(entries, o + 8), 0x36C0), magic(smdh, 0, "SMDH") else { break }
            return GameInfo(programID: programID, title: title(smdh), icon: icon(smdh))
        }
        return noInfo
    }

    /// The short English title; the Japanese one when the English one is empty.
    private static func title(_ smdh: Data) -> String? {
        for language in [1, 0] {
            let start = smdh.startIndex + 8 + language * 0x200
            var units: [UInt16] = []
            for i in 0..<0x40 {
                let u = UInt16(smdh[start + i * 2]) | UInt16(smdh[start + i * 2 + 1]) << 8
                if u == 0 { break }
                units.append(u)
            }
            let text = String(decoding: units, as: UTF16.self).split(whereSeparator: \.isNewline).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { return text }
        }
        return nil
    }

    /// The large icon: 48 x 48, 16-bit colour, stored as 8 x 8 tiles with the pixels of a tile in Z order.
    private static func icon(_ smdh: Data) -> [UInt8] {
        let side = iconSide
        var out = [UInt8](repeating: 255, count: side * side * 4)
        var i = smdh.startIndex + 0x24C0
        for tileY in stride(from: 0, to: side, by: 8) {
            for tileX in stride(from: 0, to: side, by: 8) {
                for z in 0..<64 {
                    let x = tileX + ((z & 1) | (z >> 1 & 2) | (z >> 2 & 4))
                    let y = tileY + ((z >> 1 & 1) | (z >> 2 & 2) | (z >> 3 & 4))
                    let c = Int(smdh[i]) | Int(smdh[i + 1]) << 8
                    i += 2
                    let p = (y * side + x) * 4
                    out[p] = UInt8((c >> 11 & 0x1F) * 255 / 31)
                    out[p + 1] = UInt8((c >> 5 & 0x3F) * 255 / 63)
                    out[p + 2] = UInt8((c & 0x1F) * 255 / 31)
                }
            }
        }
        return out
    }

    /// Where the engine keeps this game's save, below its SD card folder.
    public static func saveFolderName(programID: UInt64) -> String {
        "title/" + hex8(UInt32(programID >> 32)) + "/" + hex8(UInt32(programID & 0xFFFF_FFFF))
    }
    private static func hex8(_ v: UInt32) -> String {
        let s = String(v, radix: 16)
        return String(repeating: "0", count: 8 - s.count) + s
    }
}
