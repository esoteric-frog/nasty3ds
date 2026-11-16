import Testing
@testable import Nasty3DSKit

@Test func parsesEachValidMessage() {
    #expect(PhoneMessage.parse(#"{"t":"hello","k":"abc"}"#) == .hello(secret: "abc"))
    #expect(PhoneMessage.parse(#"{"t":"down","u":0.25,"v":0.75}"#) == .down(u: 0.25, v: 0.75))
    #expect(PhoneMessage.parse(#"{"t":"move","u":0,"v":1}"#) == .move(u: 0, v: 1))
    #expect(PhoneMessage.parse(#"{"t":"up"}"#) == .up)
    #expect(PhoneMessage.parse(#"{"t":"pong","id":7}"#) == .pong(id: 7))
}

@Test func clampsTouchToTheScreen() {
    #expect(PhoneMessage.parse(#"{"t":"down","u":-4,"v":9}"#) == .down(u: 0, v: 1))
    #expect(PhoneMessage.parse(#"{"t":"move","u":1e300,"v":-1e300}"#) == .move(u: 1, v: 0))
}

@Test(arguments: [
    "", "not json", "[]", "7", #"{"t":"fly"}"#, #"{"u":0.5,"v":0.5}"#,
    #"{"t":"down","u":0.5}"#, #"{"t":"down","u":"0.5","v":0.5}"#, #"{"t":"down","u":null,"v":0.5}"#,
    #"{"t":"down","u":1e999,"v":0.5}"#, #"{"t":"hello"}"#, #"{"t":"hello","k":7}"#, #"{"t":"pong","id":"7"}"#,
])
func rejectsBadMessages(text: String) {
    #expect(PhoneMessage.parse(text) == nil)
}

@Test func rejectsAMessageOverTheLengthLimit() {
    let long = #"{"t":"hello","k":""# + String(repeating: "a", count: 300) + #""}"#
    #expect(PhoneMessage.parse(long) == nil)
    let atLimit = #"{"t":"hello","k":""# + String(repeating: "a", count: 256 - 20) + #""}"#
    #expect(atLimit.utf8.count == 256)
    #expect(PhoneMessage.parse(atLimit) != nil)
}

@Test func outgoingMessagesAreValidJSON() {
    #expect(PhoneMessage.ping(id: 3) == #"{"t":"ping","id":3}"#)
    #expect(PhoneMessage.state("closed") == #"{"t":"state","s":"closed"}"#)
}

private func session() -> PhoneSession { PhoneSession(matches: { $0 == "good" }) }

@Test func aCorrectHelloAuthorizes() {
    var s = session()
    #expect(s.receive(#"{"t":"hello","k":"good"}"#) == .authorized)
    #expect(s.authorized)
    #expect(s.receive(#"{"t":"down","u":0.5,"v":0.5}"#) == .touch(u: 0.5, v: 0.5))
    #expect(s.receive(#"{"t":"move","u":1,"v":1}"#) == .touch(u: 1, v: 1))
    #expect(s.receive(#"{"t":"up"}"#) == .release)
    #expect(s.receive(#"{"t":"pong","id":2}"#) == .pong(id: 2))
}

@Test func anythingBeforeACorrectHelloCloses() {
    var a = session(); #expect(a.receive(#"{"t":"hello","k":"bad"}"#) == .close)
    var b = session(); #expect(b.receive(#"{"t":"down","u":0.5,"v":0.5}"#) == .close)
    var c = session(); #expect(c.receive("garbage") == .close)
    #expect(!a.authorized && !b.authorized && !c.authorized)
}

@Test func afterHelloBadMessagesAreIgnoredNotFatal() {
    var s = session()
    _ = s.receive(#"{"t":"hello","k":"good"}"#)
    #expect(s.receive("garbage") == .ignore)
    #expect(s.receive(#"{"t":"hello","k":"good"}"#) == .ignore)
    #expect(s.authorized)
}

@Test func aPongCanReportTheDisplayLock() {
    // The page says if it holds the display lock, so the Mac log can show why a display dims.
    #expect(PhoneMessage.parse(#"{"t":"pong","id":7,"w":1}"#) == .pong(id: 7))
    #expect(PhoneMessage.wakeReport(#"{"t":"pong","id":7,"w":1}"#) == "held")
    #expect(PhoneMessage.wakeReport(#"{"t":"pong","id":7,"w":0,"e":"NotAllowedError"}"#) == "no:NotAllowedError")
    #expect(PhoneMessage.wakeReport(#"{"t":"pong","id":7,"w":0,"e":"<script>alert(1)</script> and more than twenty-four"}"#) == "no:scriptalert1scriptandmor")
    #expect(PhoneMessage.wakeReport(#"{"t":"pong","id":7}"#) == nil)
    #expect(PhoneMessage.wakeReport("garbage") == nil)
}
