import AVFoundation
import Nasty3DSKit

// Runs the real AudioOut.swift with no game. It feeds silence at game speed. Then it stops the sound
// engine the way a device change does (headphones, AirPlay to a TV): the engine stops and the
// system sends AVAudioEngineConfigurationChange. After that, the sound must flow again.
let rate = 32728.0
let framesPerTick = 546                      // one 60 Hz game frame
let audio = try AudioOut(sampleRate: rate)
guard let engine = Mirror(reflecting: audio).children.first(where: { $0.label == "engine" })?.value as? AVAudioEngine
else { print("FAIL: AudioOut has no engine property"); exit(1) }

let silence = [Int16](repeating: 0, count: framesPerTick * 2)
let feeder = Thread { while true { audio.enqueue(silence, frames: framesPerTick); usleep(16_683) } }
feeder.start()

/// The share of the fed samples that found no room in one second. Near 0 = the engine pulls sound.
func droppedShare() -> Double {
    _ = audio.takeStats()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
    return Double(audio.stats.droppedSamples) / (rate * 2)
}

RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
let before = droppedShare()
guard before < 0.1 else { print(String(format: "FAIL: no sound flow at the start (dropped %.0f%%)", before * 100)); exit(1) }

engine.stop()
NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
let after = droppedShare()
guard after < 0.1 else {
    print(String(format: "FAIL: the sound stays off after a device change (dropped %.0f%%)", after * 100)); exit(1)
}
print(String(format: "PASS: the sound flows again after a device change (dropped %.0f%% before, %.0f%% after)", before * 100, after * 100))
