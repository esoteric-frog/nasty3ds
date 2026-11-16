import CryptoKit
import Foundation
import Network
import Security

/// The local certificate authority (CA) and the server certificate for the phone screen.
///
/// Threat model:
/// - The iPhone trusts this CA. If the CA key is stolen, a thief could make certificates the
///   iPhone accepts. So the CA is name-constrained (critical) to this Mac's `.local` name and has
///   pathlen 0: it cannot sign for any other site and cannot make sub-CAs.
/// - The keys never leave this Mac. Only the CA certificate (public) goes to the iPhone.
/// - The CA is made once and kept. The server certificate lasts 397 days and is made again when
///   under 30 days remain, or when the Mac's name changes (that also makes a new CA).
enum PhoneTLS {
    struct Failure: Error { let message: String }

    /// A check can point this at a scratch folder, so it never touches the real certificates.
    static var folder: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Nasty3DS/phone-tls")

    /// The public CA certificate, with a name the user can recognise in AirDrop.
    static var caFile: URL { folder.appendingPathComponent("Nasty3DS iPhone Certificate.crt") }

    private static let openssl = "/usr/bin/openssl"

    // The host name goes into the script through the environment and is checked there:
    // letters, digits and hyphens only. Nothing from the network reaches this script.
    private static let script = #"""
    set -euo pipefail
    umask 077
    SSL=/usr/bin/openssl
    [[ "$N3_HOST" =~ '^[A-Za-z0-9-]+\.local$' ]] || { echo "bad host name" >&2; exit 2; }
    NAME=${(L)N3_HOST}     # one letter case: the same Mac name must never make a second CA
    mkdir -p "$N3_DIR" && chmod 700 "$N3_DIR"
    cd "$N3_DIR"

    if [[ ! -f ca.key || ! -f ca.crt || "${(L)$(cat ca.name 2>/dev/null)}" != "$NAME" ]]; then
      rm -f ca.key ca.crt ca.srl leaf.key leaf.crt
      cat > ca.cnf <<CNF
    [req]
    distinguished_name = dn
    prompt = no
    x509_extensions = v3_ca
    [dn]
    CN = Nasty3DS Local ($NAME)
    [v3_ca]
    basicConstraints = critical, CA:TRUE, pathlen:0
    keyUsage = critical, keyCertSign, cRLSign
    subjectKeyIdentifier = hash
    nameConstraints = critical, permitted;DNS:$NAME
    CNF
      $SSL ecparam -name prime256v1 -genkey -noout -out ca.key
      $SSL req -new -x509 -sha256 -key ca.key -out ca.crt -days 3650 -config ca.cnf
      print -n "$NAME" > ca.name
      echo "NEW_CA"
    fi

    if [[ ! -f leaf.crt || ! -f leaf.key ]] || ! $SSL x509 -in leaf.crt -noout -checkend $((30 * 86400)) >/dev/null; then
      cat > leaf.cnf <<CNF
    [req]
    distinguished_name = dn
    prompt = no
    [dn]
    CN = $NAME
    [v3_leaf]
    basicConstraints = critical, CA:FALSE
    keyUsage = critical, digitalSignature
    extendedKeyUsage = serverAuth
    subjectAltName = DNS:$NAME
    CNF
      $SSL ecparam -name prime256v1 -genkey -noout -out leaf.key
      $SSL req -new -sha256 -key leaf.key -out leaf.csr -config leaf.cnf
      $SSL x509 -req -sha256 -in leaf.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out leaf.crt -days 397 \
        -extfile leaf.cnf -extensions v3_leaf 2>/dev/null
      rm -f leaf.csr
    fi
    chmod 600 ca.key leaf.key
    cp ca.crt "Nasty3DS iPhone Certificate.crt"
    """#

    private static func run(_ tool: String, _ arguments: [String], environment: [String: String], input: String? = nil) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin"].merging(environment) { $1 }
        let output = Pipe(), errors = Pipe(), stdin = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = stdin
        try process.run()
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try? stdin.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(message: "The phone certificate could not be made. \(errorText.prefix(200))")
        }
        return data
    }

    /// Makes the CA and the server certificate when they are missing, near their end, or for another name.
    static func ensureCertificates() throws {
        _ = try run("/bin/zsh", ["-f", "-s"], environment: ["N3_HOST": LocalAddress.host(), "N3_DIR": folder.path], input: script)
    }

    /// TLS options with our server certificate. Each listener needs its own options object.
    static func tlsOptions() throws -> NWProtocolTLS.Options {
        try ensureCertificates()
        // The key and certificate go to Security as a PKCS#12 blob in memory. The password is
        // random, lives only in this call, and goes to openssl through the environment, not argv.
        let password = (0..<32).map { _ in String(UInt8.random(in: 0...255), radix: 16) }.joined()
        let p12 = try run(openssl, ["pkcs12", "-export", "-inkey", folder.appendingPathComponent("leaf.key").path,
                                    "-in", folder.appendingPathComponent("leaf.crt").path,
                                    "-passout", "env:N3_P12", "-name", "nasty3ds", "-out", "/dev/stdout"],
                          environment: ["N3_P12": password])
        var options: [String: Any] = [kSecImportExportPassphrase as String: password]
        if #available(macOS 15.0, *) { options[kSecImportToMemoryOnly as String] = true }   // not into the keychain
        var items: CFArray?
        guard SecPKCS12Import(p12 as CFData, options as CFDictionary, &items) == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let value = first[kSecImportItemIdentity as String],
              let identity = sec_identity_create(value as! SecIdentity)
        else { throw Failure(message: "The phone certificate could not be loaded.") }

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        return tls
    }

    /// SHA-256 of the CA certificate, as the iPhone shows it. Nil when no CA exists yet.
    static func fingerprint() -> String? {
        guard let pem = try? String(contentsOf: caFile, encoding: .utf8),
              let der = Data(base64Encoded: pem.components(separatedBy: "\n").filter { !$0.hasPrefix("-----") }.joined())
        else { return nil }
        return SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}
