import Foundation
import Testing
@testable import Nasty3DSKit

@Test(arguments: ["Sam’s MacBook Pro", "", "é", "a", "A very long computer name that never ends", "名前", "x_y.z-1 ok", "  spaces  "])
func aNicknameAlwaysFitsTheRoomRule(computer: String) {
    // The room accepts only: ^[ a-zA-Z0-9._-]{4,20}$
    let name = LocalPlayText.nickname(from: computer, suffix: 42)
    #expect(name.range(of: "^[ a-zA-Z0-9._-]{4,20}$", options: .regularExpression) != nil, "\(name)")
    #expect(name.hasSuffix("42"))
    #expect(name == name.trimmingCharacters(in: .whitespaces))
}

@Test func aNicknameKeepsTheReadablePartOfTheComputerName() {
    #expect(LocalPlayText.nickname(from: "Sam’s MacBook Pro", suffix: 7) == "Sams MacBook Pro 07")
    #expect(LocalPlayText.nickname(from: "", suffix: 7) == "Player 07")
}

@Test func theStatusSaysWhatTheRoomDoes() {
    #expect(LocalPlayText.status(state: 0, hosting: false, players: 0) == "")
    #expect(LocalPlayText.status(state: 1, hosting: false, players: 0) == "Local play: joining…")
    #expect(LocalPlayText.status(state: 2, hosting: true, players: 1) == "Local play: hosting, no other player yet")
    #expect(LocalPlayText.status(state: 2, hosting: true, players: 2) == "Local play: hosting, 2 players")
    #expect(LocalPlayText.status(state: 2, hosting: false, players: 3) == "Local play: joined, 3 players")
    #expect(LocalPlayText.status(state: -9, hosting: false, players: 0) == "Local play: the other Mac did not answer")
    #expect(LocalPlayText.status(state: -7, hosting: false, players: 0) == "Local play: the other Mac has a different version")
    #expect(LocalPlayText.status(state: -10, hosting: false, players: 0) == "Local play: the room is full")
    #expect(LocalPlayText.status(state: -1, hosting: false, players: 0) == "Local play: the connection was lost")
    #expect(LocalPlayText.status(state: -99, hosting: false, players: 0) == "Local play: could not join")
    #expect(LocalPlayText.status(state: -1, hosting: false, players: 0).isEmpty == false)
}

@Test func onlyAnAddressOnTheLocalNetworkCanBeJoined() {
    // An advert on the network names the address. It must not send this Mac to the internet.
    for ok in ["10.0.0.5", "172.16.0.1", "172.31.255.254", "192.168.1.20", "169.254.10.1", "127.0.0.1"] {
        #expect(LocalPlayText.isLocalAddress(ok), "\(ok)")
    }
    for bad in ["8.8.8.8", "172.32.0.1", "172.15.0.1", "192.169.1.1", "11.0.0.1", "", "abc", "10.0.0", "10.0.0.256", "10.0.0.1.1", "::1", "10.0.0.-1"] {
        #expect(!LocalPlayText.isLocalAddress(bad), "\(bad)")
    }
}
