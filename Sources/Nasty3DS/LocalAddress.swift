import Foundation
import SystemConfiguration

/// The name the phone uses to reach this Mac: the Bonjour local name, in lower case.
/// The certificate names only this name, and it stays the same between sessions (an IP address
/// can change). Lower case always: a second letter case once made a second certificate.
enum LocalAddress {
    static func host() -> String {
        let bonjour = SCDynamicStoreCopyLocalHostName(nil) as String?
        let name = (bonjour ?? ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")).lowercased()
        return name + ".local"
    }
}
