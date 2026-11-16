import Testing
@testable import Nasty3DSKit

@Test func thePageIsSelfContained() {
    let html = PhonePage.html(livePort: 49222)
    for outside in ["https://", "http://", "src=\"//", "@import", "<link"] {
        #expect(!html.contains(outside), "\(outside)")
    }
}

@Test func thePageKnowsTheLivePort() {
    let html = PhonePage.html(livePort: 49222)
    #expect(html.contains(":49222/"))
    #expect(!html.contains("__LIVE_PORT__"))
    #expect(html.contains("wss://"))
    #expect(!html.contains("'ws://"))
}

@Test func thePageIsAHomeScreenWebApp() {
    let html = PhonePage.html(livePort: 1)
    #expect(html.contains("apple-mobile-web-app-capable"))
    #expect(html.contains("user-scalable=no"))
    #expect(html.contains("Connecting to your Mac"))
}

@Test func thePageKeepsTheDisplayOnWithTheWakeLock() {
    let html = PhonePage.html(livePort: 1)
    #expect(html.contains("navigator.wakeLock.request('screen')"))
    #expect(html.contains("visibilitychange"))
    #expect(!html.contains("<video"))
}

@Test func thePageSaysHowToGetFullScreen() {
    // iPhone Safari cannot hide its bars for a page. Only a home screen icon opens with no bars.
    let html = PhonePage.html(livePort: 1)
    #expect(html.contains("Add to Home Screen"))
    #expect(html.contains("navigator.standalone"))
    #expect(html.contains("black-translucent"))      // the picture can use the whole display
}
