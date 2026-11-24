// Signs an update file with the owner's key, so the app installs only files from the owner.
//   swift scripts/sign-update.swift new-key        makes the key one time, prints the public key
//   swift scripts/sign-update.swift sign <file>    writes <file>.sig
//   swift scripts/sign-update.swift public         prints the public key
// The private key stays in ~/.config/nasty3ds/update-key. It never goes into the repo or a log.
// N3_UPDATE_KEY_FILE=<path> uses another key file (the update check makes throw-away keys).
import CryptoKit
import Foundation

let fm = FileManager.default
let keyFile = ProcessInfo.processInfo.environment["N3_UPDATE_KEY_FILE"].map { URL(fileURLWithPath: $0) }
    ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(".config/nasty3ds/update-key")
let folder = keyFile.deletingLastPathComponent()

func fail(_ text: String) -> Never {
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(1)
}

func privateKey() -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOf: keyFile, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else { fail("No signing key at \(keyFile.path). Run: swift scripts/sign-update.swift new-key") }
    return key
}

let args = CommandLine.arguments.dropFirst()
switch (args.first, args.count) {
case ("new-key", 1):
    guard !fm.fileExists(atPath: keyFile.path) else { fail("A key exists already. A new key would stop every installed copy from updating.") }
    let key = Curve25519.Signing.PrivateKey()
    do {
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        // The file is made with mode 0600 before the key goes in.
        guard fm.createFile(atPath: keyFile.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { fail("The key file could not be made.") }
        let handle = try FileHandle(forWritingTo: keyFile)
        try handle.write(contentsOf: Data((key.rawRepresentation.base64EncodedString() + "\n").utf8))
        try handle.close()
    } catch { fail("The key file could not be written: \(error.localizedDescription)") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case ("sign", 2):
    let file = URL(fileURLWithPath: args.last!)
    guard let data = try? Data(contentsOf: file) else { fail("Cannot read \(file.path)") }
    guard let signature = try? privateKey().signature(for: data) else { fail("The signature could not be made.") }
    do { try Data((signature.base64EncodedString() + "\n").utf8).write(to: URL(fileURLWithPath: file.path + ".sig")) }
    catch { fail("Cannot write \(file.path).sig") }
case ("public", 1):
    print(privateKey().publicKey.rawRepresentation.base64EncodedString())
default:
    fail("Use: swift scripts/sign-update.swift new-key | sign <file> | public")
}
