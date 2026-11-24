import AVFoundation
import Nasty3DSKit

final class AudioOut {
    /// Seconds of audio the buffer can hold. Real clocks drift; tune this if sound crackles (lower
    /// = less delay, more underruns).
    static let bufferSeconds = 0.10

    /// Diagnosis counters. Plain ints written from two threads: good enough for a log line.
    final class Stats { var underrunSamples = 0; var droppedSamples = 0 }
    let stats = Stats()
    /// Text for the stats line, then the counters start again.
    func takeStats() -> String {
        defer { stats.underrunSamples = 0; stats.droppedSamples = 0 }
        return "underrun=\(stats.underrunSamples) dropped=\(stats.droppedSamples) buffered=\(ring.available)"
    }

    /// How full the buffer is, 0...1. The emulation loop paces itself from this.
    var fillFraction: Double { Double(ring.available) / Double(capacity) }
    private let capacity: Int

    private let engine = AVAudioEngine()
    private let ring: RingBuffer
    private var source: AVAudioSourceNode!
    private var deviceChange: NSObjectProtocol?
    /// For one line in core.log when the sound device changes.
    var log: (String) -> Void = { _ in }

    init(sampleRate: Double) throws {
        capacity = Int(sampleRate * Self.bufferSeconds) * 2
        ring = RingBuffer(capacity: capacity)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let ring = self.ring
        let stats = self.stats
        var scratch = [Int16](repeating: 0, count: 8192)
        source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let frames = min(Int(frameCount), scratch.count / 2)
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            scratch.withUnsafeMutableBufferPointer { s in
                let got = ring.read(into: s.baseAddress!, count: frames * 2)   // underrun = zeros
                if got < frames * 2 { stats.underrunSamples += frames * 2 - got }
                let left = buffers[0].mData!.assumingMemoryBound(to: Float.self)
                let right = buffers[1].mData!.assumingMemoryBound(to: Float.self)
                for i in 0..<frames {
                    left[i] = Float(s[i * 2]) / 32768
                    right[i] = Float(s[i * 2 + 1]) / 32768
                }
                for i in frames..<Int(frameCount) { left[i] = 0; right[i] = 0 }
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        try engine.start()
        // A new sound device (headphones, AirPlay, a TV) stops the engine. It does not start again
        // by itself: without this the game is silent until the next start of the app.
        deviceChange = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.restart(triesLeft: 3) }
    }

    deinit { if let deviceChange { NotificationCenter.default.removeObserver(deviceChange) } }

    private func restart(triesLeft: Int) {
        guard !engine.isRunning else { return }
        do {
            try engine.start()
            log("[n3] sound device changed: the sound runs again")
        } catch {
            log("[n3] sound device changed: no start (\(error.localizedDescription)), tries left \(triesLeft)")
            // A device that just arrived can need a moment before it takes sound.
            guard triesLeft > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.restart(triesLeft: triesLeft - 1) }
        }
    }

    func enqueue(_ samples: UnsafePointer<Int16>, frames: Int) {
        let stored = ring.write(samples, count: frames * 2)   // overrun = extra samples dropped
        stats.droppedSamples += frames * 2 - stored
    }
}
