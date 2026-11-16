import Foundation

public struct LibraryGame: Sendable {
    public let url: URL
    public let title: String
    public let programID: UInt64?
    public let icon: [UInt8]?
    public let lastPlayed: Date?
}

/// The games the app knows: every game file in `<folder>/games`. The folder is the list;
/// `library.json` holds only the "last played" dates.
public final class GameLibrary {
    public struct Failure: Error { public let message: String }
    public static let backupsKept = 10

    public let folder: URL
    public var gamesFolder: URL { folder.appendingPathComponent("games") }
    private var playedFile: URL { folder.appendingPathComponent("library.json") }
    private let fm = FileManager.default

    public init(folder: URL) { self.folder = folder }

    private func played() -> [String: Date] {
        guard let data = try? Data(contentsOf: playedFile),
              let raw = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
        return raw.mapValues { Date(timeIntervalSince1970: $0) }
    }

    public func markPlayed(_ url: URL, at date: Date = Date()) {
        var all = played()
        all[url.lastPathComponent] = date
        if let data = try? JSONEncoder().encode(all.mapValues(\.timeIntervalSince1970)) { try? data.write(to: playedFile, options: .atomic) }
    }

    /// The game you played last comes first; games not played yet follow, by name.
    public func games() -> [LibraryGame] {
        let dates = played()
        let files = (try? fm.contentsOfDirectory(at: gamesFolder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return files.filter { GameFile.extensions.contains($0.pathExtension.lowercased()) }.map { url -> LibraryGame in
            let info = GameFile.read(url)
            return LibraryGame(url: url, title: info?.title ?? url.deletingPathExtension().lastPathComponent,
                               programID: info?.programID, icon: info?.icon, lastPlayed: dates[url.lastPathComponent])
        }.sorted {
            switch ($0.lastPlayed, $1.lastPlayed) {
            case let (a?, b?): return a > b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }
    }

    /// Moves a game file into the library folder and returns its new place. The original does
    /// not stay behind. A file that is already in the library is not added again, and then the
    /// user's file is not touched.
    public func add(_ source: URL) throws -> URL {
        var isFolder: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isFolder), !isFolder.boolValue,
              GameFile.extensions.contains(source.pathExtension.lowercased()) else {
            throw Failure(message: "“\(source.lastPathComponent)” is not a 3DS game file.")
        }
        try fm.createDirectory(at: gamesFolder, withIntermediateDirectories: true)
        if source.deletingLastPathComponent().standardizedFileURL.path == gamesFolder.standardizedFileURL.path { return source }

        func size(_ url: URL) -> Int? { (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int }
        let stem = source.deletingPathExtension().lastPathComponent, ext = source.pathExtension
        var target = gamesFolder.appendingPathComponent(source.lastPathComponent)
        var n = 2
        while fm.fileExists(atPath: target.path) {
            // The same name and the same bytes: this game is already here.
            if size(target) == size(source), fm.contentsEqual(atPath: target.path, andPath: source.path) { return target }
            target = gamesFolder.appendingPathComponent("\(stem) \(n).\(ext)")
            n += 1
        }
        func volume(_ url: URL) -> NSObject? { (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject }
        if let a = volume(source), let b = volume(gamesFolder), a.isEqual(b) {
            do { try fm.moveItem(at: source, to: target) }      // same disk: one rename, nothing is copied
            catch { throw Failure(message: "Nasty3DS could not move “\(source.lastPathComponent)”. \(error.localizedDescription)") }
            return target
        }
        // Another disk: copy under a working name, check the copy, give it its name, and only
        // then put the original in the Trash. If the Trash step fails, the original stays.
        let partial = gamesFolder.appendingPathComponent(".partial-" + UUID().uuidString)
        do {
            try fm.copyItem(at: source, to: partial)
            guard let copied = size(partial), copied == size(source) else { throw Failure(message: "The copy was not complete.") }
            try fm.moveItem(at: partial, to: target)
        } catch {
            try? fm.removeItem(at: partial)
            let why = (error as? Failure)?.message ?? error.localizedDescription
            throw Failure(message: "Nasty3DS could not copy “\(source.lastPathComponent)”. \(why) The original is unchanged.")
        }
        try? fm.trashItem(at: source, resultingItemURL: nil)
        return target
    }

    // MARK: save backup

    public func saveFolder(programID: UInt64) -> URL {
        let zeros = String(repeating: "0", count: 32)
        return folder.appendingPathComponent("saves/Azahar/sdmc/Nintendo 3DS/\(zeros)/\(zeros)/" + GameFile.saveFolderName(programID: programID))
    }

    /// Copies the game's save to `save-backups/<title>/<time of the save>` and returns the copy.
    /// Nil when there is no save, or when this save already has a copy. Only the newest copies stay.
    @discardableResult
    public func backUpSave(programID: UInt64, title: String) -> URL? {
        let save = saveFolder(programID: programID)
        guard let files = fm.enumerator(at: save, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { return nil }
        var newest: Date?
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true, let date = values.contentModificationDate else { continue }
            newest = max(newest ?? date, date)
        }
        guard let newest else { return nil }

        // The title goes into a folder name: no path parts.
        var name = title.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters)).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        // The game ID is part of the name: two games with one title must not share a folder.
        let id = String(programID, radix: 16)
        name = (name.isEmpty ? "" : name + " ") + String(repeating: "0", count: max(0, 16 - id.count)) + id
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")           // names must sort by time in every time zone
        format.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let home = folder.appendingPathComponent("save-backups").appendingPathComponent(name)
        let copy = home.appendingPathComponent(format.string(from: newest))
        guard !fm.fileExists(atPath: copy.path) else { return nil }
        // Copy under a working name, then rename: a copy cut short (full disk) never counts as a backup.
        let partial = home.appendingPathComponent(".partial-" + UUID().uuidString)
        do {
            try fm.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.copyItem(at: save, to: partial)
            try fm.moveItem(at: partial, to: copy)
        } catch {
            try? fm.removeItem(at: partial)
            return nil
        }

        // Keep the copy just made and the newest of the others.
        let others = ((try? fm.contentsOfDirectory(atPath: home.path)) ?? [])
            .filter { format.date(from: $0) != nil && $0 != copy.lastPathComponent }.sorted()
        for old in others.dropLast(Self.backupsKept - 1) { try? fm.removeItem(at: home.appendingPathComponent(old)) }
        return copy
    }
}
