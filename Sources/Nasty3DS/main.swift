import AppKit

setvbuf(stdout, nil, _IOLBF, 0)     // lines reach a log file at once

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)

// A terminate or interrupt signal quits the normal way, so the core can write its save data.
let quitSignals = [SIGTERM, SIGINT].map { sig -> DispatchSourceSignal in
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { delegate.quitNow() }
    source.resume()
    return source
}

app.run()
