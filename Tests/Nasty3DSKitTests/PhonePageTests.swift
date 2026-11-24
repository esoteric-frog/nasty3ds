import Testing
@testable import Nasty3DSKit

@Test func thePageIsSelfContained() {
    for html in [PhonePage.html(livePorts: [49222], stable: true), PhonePage.html(livePorts: [49222], stable: false)] {
        for outside in ["https://", "http://", "src=\"//", "@import", "<link"] {
            #expect(!html.contains(outside), "\(outside)")
        }
    }
}

@Test func thePageKnowsTheLivePorts() {
    let html = PhonePage.html(livePorts: [49222, 31000], stable: true)
    #expect(html.contains("const ports = [49222,31000];"))
    #expect(!html.contains("__LIVE_PORTS__"))
    #expect(html.contains("wss://"))
    #expect(!html.contains("'ws://"))
}

@Test func theLivePortListIsActiveThenSavedThenBackup() {
    #expect(PhonePage.livePorts(active: 23456, remembered: 41350, backup: 22937) == [23456, 41350, 22937])
    #expect(PhonePage.livePorts(active: 41350, remembered: 41350, backup: 22937) == [41350, 22937])
    #expect(PhonePage.livePorts(active: 22937, remembered: 41350, backup: 22937) == [22937, 41350])
    #expect(PhonePage.livePorts(active: 41350, remembered: 41350, backup: nil) == [41350])
    #expect(PhonePage.livePorts(active: 0, remembered: 41350, backup: 0) == [41350])
}

@Test func thePageIsAHomeScreenWebApp() {
    let html = PhonePage.html(livePorts: [1], stable: true)
    #expect(html.contains("apple-mobile-web-app-capable"))
    #expect(html.contains("user-scalable=no"))
    #expect(html.contains("Connecting to your Mac"))
}

@Test func thePageKeepsTheDisplayOnWithTheWakeLock() {
    let html = PhonePage.html(livePorts: [1], stable: true)
    #expect(html.contains("navigator.wakeLock.request('screen')"))
    #expect(html.contains("visibilitychange"))
    #expect(!html.contains("<video"))
}

@Test func thePageSaysHowToGetFullScreen() {
    // iPhone Safari cannot hide its bars for a page. Only a home screen icon opens with no bars.
    let html = PhonePage.html(livePorts: [1], stable: true)
    #expect(html.contains("Add to Home Screen"))
    #expect(html.contains("navigator.standalone"))
    #expect(html.contains("black-translucent"))      // the picture can use the whole display
}

@Test func aStablePageKeepsACopyOfItselfAndAnUnstableOneDoesNot() {
    let stable = PhonePage.html(livePorts: [1], stable: true), session = PhonePage.html(livePorts: [1], stable: false)
    #expect(stable.contains("const stable = 1 === 1;"))
    #expect(session.contains("const stable = 0 === 1;"))
    for html in [stable, session] {
        #expect(!html.contains("__STABLE__") && !html.contains("__CACHE__"))
        #expect(html.contains("navigator.serviceWorker.register('/sw.js?k=' + encodeURIComponent(key))"))
        #expect(html.contains("caches.open('nasty3ds-1')"))       // the first load primes the copy
        #expect(html.contains("if (stable && !navigator.standalone && !tipHidden)"))   // no icon tip for a session port
    }
}

@Test func theWorkerServesTheSavedCopyOnlyForPageLoads() {
    let worker = PhonePage.worker
    #expect(worker.contains("'navigate'"))
    #expect(worker.contains("const CACHE = 'nasty3ds-1';"))
    #expect(worker.contains("cache.delete(url)"))                   // the Mac forgot this phone: no old page
    #expect(!worker.contains("__CACHE__"))
    // A slow Mac: the copy answers after 2.5 s, and the fetch is not cut off. It still updates the copy.
    #expect(worker.contains("Promise.race") && worker.contains("2500"))
    #expect(worker.contains("event.waitUntil(fresh"))
    #expect(!worker.contains("abort"))
}

@Test func thePageSaysWhatToDoWhenTheMacIsNotReady() {
    let html = PhonePage.html(livePorts: [1], stable: true)
    #expect(html.contains("Start a game on your Mac. This page connects by itself."))
    #expect(html.contains("fails < 2"))
}

@Test func thePageReplacesADeadConnectionByItself() {
    let html = PhonePage.html(livePorts: [1], stable: true)
    #expect(html.contains("let lastHeard = Date.now()"))
    #expect(html.contains("quiet > 4000") && html.contains("quiet > 8000"))
    #expect(html.contains("clearTimeout(retryTimer)"))
    #expect(html.contains("pageshow"))
}

@Test func theBackOffGrowsOnlyAfterEveryPortWasTried() {
    let html = PhonePage.html(livePorts: [1, 2, 3], stable: true)
    #expect(html.contains("if (tries % ports.length === 0) retry = Math.min(retry * 2, 5000);"))
}
