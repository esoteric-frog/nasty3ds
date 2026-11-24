import Foundation
import Testing
@testable import Nasty3DSKit

/// A tiny game file with the real layout: card header, game header, file table, icon file.
private func gameFile(programID: UInt64 = 0x0004_0000_0005_5D00, title: String = "Pokémon X", card: Bool = true,
                      encrypted: Bool = false, iconName: String = "icon") -> Data {
    var d = Data(count: 0x10000)
    func put(_ bytes: [UInt8], at o: Int) { d.replaceSubrange(o..<o + bytes.count, with: bytes) }
    func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
    let base = card ? 0x4000 : 0
    if card { put(Array("NCSD".utf8), at: 0x100); put(le32(0x20) + le32(0x60), at: 0x120) }
    put(Array("NCCH".utf8), at: base + 0x100)
    put((0..<8).map { UInt8((programID >> (8 * $0)) & 0xFF) }, at: base + 0x118)
    put([encrypted ? 0 : 4], at: base + 0x188 + 7)
    put(le32(2) + le32(0x40), at: base + 0x1A0)                    // file table at +0x400
    let table = base + 0x400
    put(Array(iconName.utf8), at: table); put(le32(0) + le32(0x36C0), at: table + 8)
    let smdh = table + 0x200
    put(Array("SMDH".utf8), at: smdh)
    put(Array(title.utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }, at: smdh + 8 + 0x200)   // English
    // large icon: first pixel pure red, second pixel (x=1,y=0) pure green, third in Morton order (x=0,y=1) pure blue
    put([0x00, 0xF8, 0xE0, 0x07, 0x1F, 0x00], at: smdh + 0x24C0)
    return d
}
private func reader(_ d: Data) -> (UInt64, Int) -> Data? {
    { offset, count in offset + UInt64(count) <= UInt64(d.count) ? d.subdata(in: Int(offset)..<Int(offset) + count) : nil }
}

@Test func aGameFileGivesItsTitleIDAndIcon() throws {
    let info = try #require(GameFile.parse(read: reader(gameFile())))
    #expect(info.programID == 0x0004_0000_0005_5D00)
    #expect(info.title == "Pokémon X")
    let icon = try #require(info.icon)
    #expect(icon.count == 48 * 48 * 4)
    #expect(Array(icon[0..<4]) == [255, 0, 0, 255])                 // (0,0) red
    #expect(Array(icon[4..<8]) == [0, 255, 0, 255])                 // (1,0) green
    #expect(Array(icon[48 * 4..<48 * 4 + 4]) == [0, 0, 255, 255])   // (0,1) blue
}

@Test func aGameFileWithNoCardHeaderIsReadToo() {
    #expect(GameFile.parse(read: reader(gameFile(card: false)))?.title == "Pokémon X")
}

@Test func anEncryptedGameGivesTheIDButNoTitleOrIcon() throws {
    let info = try #require(GameFile.parse(read: reader(gameFile(encrypted: true))))
    #expect(info.programID == 0x0004_0000_0005_5D00)
    #expect(info.title == nil && info.icon == nil)
}

@Test func aFileThatIsNotAGameGivesNothingAndNeverTraps() {
    #expect(GameFile.parse(read: reader(Data())) == nil)
    #expect(GameFile.parse(read: reader(Data(count: 0x300))) == nil)
    #expect(GameFile.parse(read: reader(Data((0..<0x5000).map { UInt8(truncatingIfNeeded: $0 &* 31) }))) == nil)
    // every header field at its largest value: offsets point far outside the file
    var bad = gameFile()
    for o in [0x120, 0x124, 0x41A0, 0x41A4, 0x4408, 0x440C] { bad.replaceSubrange(o..<o + 4, with: [0xFF, 0xFF, 0xFF, 0xFF]) }
    #expect(GameFile.parse(read: reader(bad))?.icon == nil)
    // a file cut at each of several lengths
    let good = gameFile()
    for length in stride(from: 0, to: good.count, by: 0x333) { _ = GameFile.parse(read: reader(good.prefix(length))) }
    #expect(GameFile.parse(read: reader(gameFile(iconName: "logo")))?.icon == nil)
}

@Test func theSaveFolderComesFromTheGameID() {
    #expect(GameFile.saveFolderName(programID: 0x0004_0000_0005_5D00) == "title/00040000/00055d00")
}

private func scratch() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("n3-lib-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

@Test func addingAGameMovesItIntoTheLibrary() throws {
    let root = scratch(), elsewhere = scratch()
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: elsewhere) }
    let source = elsewhere.appendingPathComponent("My Game.cci")
    try gameFile().write(to: source)
    let library = GameLibrary(folder: root)
    let placed = try library.add(source)
    #expect(placed.path == root.appendingPathComponent("games/My Game.cci").path)
    #expect(FileManager.default.fileExists(atPath: placed.path))
    #expect(!FileManager.default.fileExists(atPath: source.path))          // the original is gone
    #expect(try Data(contentsOf: placed) == gameFile())
    let games = library.games()
    #expect(games.count == 1 && games[0].title == "Pokémon X" && games[0].lastPlayed == nil)
}

@Test func addingNeverLosesOrOverwritesAGame() throws {
    let root = scratch(), elsewhere = scratch()
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: elsewhere) }
    let library = GameLibrary(folder: root)
    let first = elsewhere.appendingPathComponent("Game.cci")
    try gameFile().write(to: first)
    _ = try library.add(first)
    // a different game with the same file name gets a new name
    try gameFile(title: "Other").write(to: first)
    let second = try library.add(first)
    #expect(second.lastPathComponent == "Game 2.cci")
    #expect(library.games().count == 2)
    // the same file again: nothing is added, and the user's copy stays where it is
    try gameFile().write(to: first)
    let again = try library.add(first)
    #expect(again.lastPathComponent == "Game.cci")
    #expect(FileManager.default.fileExists(atPath: first.path))
    #expect(library.games().count == 2)
    // a game that is already in the library folder stays there
    #expect(try library.add(again).path == again.path)
    #expect(FileManager.default.fileExists(atPath: again.path))
    // not a game file, a folder, a missing file: refused, and nothing moves
    let text = elsewhere.appendingPathComponent("notes.txt")
    try Data("hi".utf8).write(to: text)
    #expect(throws: GameLibrary.Failure.self) { try library.add(text) }
    #expect(FileManager.default.fileExists(atPath: text.path))
    #expect(throws: GameLibrary.Failure.self) { try library.add(elsewhere.appendingPathComponent("missing.cci")) }
    let folder = elsewhere.appendingPathComponent("Folder.cci")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    #expect(throws: GameLibrary.Failure.self) { try library.add(folder) }
}

@Test func theGameYouPlayedLastComesFirst() throws {
    let root = scratch(), elsewhere = scratch()
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: elsewhere) }
    let library = GameLibrary(folder: root)
    for name in ["A", "B", "C"] {
        let f = elsewhere.appendingPathComponent("\(name).cci")
        try gameFile(title: name).write(to: f)
        _ = try library.add(f)
    }
    library.markPlayed(root.appendingPathComponent("games/B.cci"), at: Date(timeIntervalSince1970: 1000))
    library.markPlayed(root.appendingPathComponent("games/C.cci"), at: Date(timeIntervalSince1970: 2000))
    #expect(library.games().map(\.title) == ["C", "B", "A"])
    #expect(GameLibrary(folder: root).games().map(\.title) == ["C", "B", "A"])      // kept after a restart
    try Data("{ broken".utf8).write(to: root.appendingPathComponent("library.json"))
    #expect(GameLibrary(folder: root).games().count == 3)                           // a bad file loses dates, not games
}

@Test func theSaveIsCopiedBeforeAGameStarts() throws {
    let root = scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = GameLibrary(folder: root)
    let id: UInt64 = 0x0004_0000_0005_5D00
    #expect(library.backUpSave(programID: id, title: "Pokémon X") == nil)             // no save yet: nothing to do
    let save = library.saveFolder(programID: id).appendingPathComponent("data/00000001")
    try FileManager.default.createDirectory(at: save, withIntermediateDirectories: true)
    try Data("progress 1".utf8).write(to: save.appendingPathComponent("main"))
    let first = try #require(library.backUpSave(programID: id, title: "Pokémon X"))
    #expect(try Data(contentsOf: first.appendingPathComponent("data/00000001/main")) == Data("progress 1".utf8))
    #expect(first.path.contains("save-backups/Pokémon X 0004000000055d00/"))
    #expect(library.backUpSave(programID: id, title: "Pokémon X") == nil)             // no change: no second copy
    // new progress gives a new copy, and the old copy keeps the old progress
    try Data("progress 2".utf8).write(to: save.appendingPathComponent("main"))
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: save.appendingPathComponent("main").path)
    let second = try #require(library.backUpSave(programID: id, title: "Pokémon X"))
    #expect(second.path != first.path)
    #expect(try Data(contentsOf: first.appendingPathComponent("data/00000001/main")) == Data("progress 1".utf8))
    // only the newest copies stay
    for i in 0..<14 {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(Double(100 + i * 10))], ofItemAtPath: save.appendingPathComponent("main").path)
        _ = library.backUpSave(programID: id, title: "Pokémon X")
    }
    let kept = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("save-backups/Pokémon X 0004000000055d00").path).filter { !$0.hasPrefix(".") }
    #expect(kept.count == GameLibrary.backupsKept)
    // a title with a path in it cannot leave the backup folder
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(900)], ofItemAtPath: save.appendingPathComponent("main").path)
    let odd = try #require(library.backUpSave(programID: id, title: "../../evil/"))
    #expect(odd.path.hasPrefix(root.appendingPathComponent("save-backups").path + "/"))
}

private func makeSave(_ lib: GameLibrary, _ id: UInt64, _ text: String, _ mtime: Date) throws {
    let f = lib.saveFolder(programID: id).appendingPathComponent("data/00000001")
    try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
    try Data(text.utf8).write(to: f.appendingPathComponent("main"))
    try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: f.appendingPathComponent("main").path)
}

@Test func twoGamesWithOneTitleKeepTheirOwnBackups() throws {
    let root = scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let lib = GameLibrary(folder: root)
    let a: UInt64 = 0x0004_0000_0005_5D00, b: UInt64 = 0x0004_0000_0005_5E00
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    try makeSave(lib, a, "A-progress", t0)
    let aCopy = try #require(lib.backUpSave(programID: a, title: "Pokémon X"))
    for i in 1...12 {
        try makeSave(lib, b, "B\(i)", t0.addingTimeInterval(Double(i) * 100))
        _ = lib.backUpSave(programID: b, title: "Pokémon X")
    }
    #expect(FileManager.default.fileExists(atPath: aCopy.path))
    try makeSave(lib, a, "A-new", t0.addingTimeInterval(1000))             // the same second as one of B's saves
    #expect(lib.backUpSave(programID: a, title: "Pokémon X") != nil)
}

@Test func theCopyJustMadeIsNeverTheOneThatIsRemoved() throws {
    let root = scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let lib = GameLibrary(folder: root)
    let id: UInt64 = 0x0004_0000_0005_5D00, t0 = Date(timeIntervalSince1970: 1_790_000_000)
    for i in 1...10 {
        try makeSave(lib, id, "new \(i)", t0.addingTimeInterval(Double(i) * 100))
        _ = lib.backUpSave(programID: id, title: "Game")
    }
    try makeSave(lib, id, "an older save, put back by the user", t0.addingTimeInterval(-5000))
    let copy = try #require(lib.backUpSave(programID: id, title: "Game"))
    #expect(FileManager.default.fileExists(atPath: copy.appendingPathComponent("data/00000001/main").path))
    let all = try FileManager.default.contentsOfDirectory(atPath: copy.deletingLastPathComponent().path).filter { !$0.hasPrefix(".") }
    #expect(all.count == GameLibrary.backupsKept && !all.contains { $0.contains("partial") })
}

/// Runs only with N3_OTHER_VOLUME=<folder on another disk>: the copy-and-check path.
@Test func aGameFromAnotherDiskIsCopiedCheckedAndTheOriginalLeaves() throws {
    guard let other = ProcessInfo.processInfo.environment["N3_OTHER_VOLUME"] else { return }
    let root = scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = URL(fileURLWithPath: other).appendingPathComponent("Far Game.cci")
    try gameFile().write(to: source)
    let placed = try GameLibrary(folder: root).add(source)
    #expect(try Data(contentsOf: placed) == gameFile())
    #expect(!FileManager.default.fileExists(atPath: source.path))
    let names = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("games").path)
    #expect(names == ["Far Game.cci"])                                  // no working file is left
}

@Test func beforeAnUpdateAllSavesAreCopied() throws {
    let root = scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let lib = GameLibrary(folder: root)
    #expect(try lib.backUpAllSaves() == nil)                              // no saves folder: nothing to copy
    let save = root.appendingPathComponent("saves/a/b/save.bin")
    try FileManager.default.createDirectory(at: save.deletingLastPathComponent(), withIntermediateDirectories: true)
    let bytes = Data((0..<4096).map { _ in UInt8.random(in: 0...255) })
    try bytes.write(to: save)
    let copy = try #require(try lib.backUpAllSaves())
    #expect(copy.lastPathComponent.hasPrefix("All saves before update "))
    #expect(copy.deletingLastPathComponent().lastPathComponent == "save-backups")
    #expect(try Data(contentsOf: copy.appendingPathComponent("saves/a/b/save.bin")) == bytes)
    #expect(try Data(contentsOf: save) == bytes)                          // the saves stay as they are
    let left = try FileManager.default.contentsOfDirectory(atPath: copy.deletingLastPathComponent().path)
    #expect(!left.contains { $0.contains("partial") })
}
