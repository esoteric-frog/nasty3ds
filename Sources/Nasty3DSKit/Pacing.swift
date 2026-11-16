/// Keeps the emulator and the sound card in step.
/// The emulator makes a fixed number of sound samples per frame. If frames are paced only by the
/// wall clock, the audio buffer slowly fills (then samples are dropped) or empties (then silence).
public enum Pacing {
    /// The time one frame must take so the audio buffer moves toward `target`.
    /// `fill` and `target` are fractions of the buffer, 0...1. `maxAdjust` is the largest speed
    /// change. 0.02 = 2%: too small to see, and the sound pitch does not change.
    /// Measured need on this Mac: about 0.4%. A larger limit keeps the buffer near the target.
    public static func frameTime(base: Double, fill: Double, target: Double = 0.5, maxAdjust: Double = 0.02) -> Double {
        guard fill.isFinite, target > 0 else { return base }
        let error = max(-1, min(1, (fill - target) / target))   // above 0: buffer too full
        return base * (1 + maxAdjust * error)
    }

    /// How far behind the clock the frame loop can stay and catch up with back-to-back frames.
    /// Each caught-up frame adds `base` seconds of sound, so the debt must fit in the free part
    /// of the sound buffer (one frame of margin). More than that would overflow and drop samples.
    public static func catchUpDebt(behind: Double, fill: Double, bufferSeconds: Double, base: Double) -> Double {
        guard behind > 0, fill.isFinite, bufferSeconds.isFinite, base.isFinite else { return 0 }
        let room = (1 - max(0, fill)) * bufferSeconds - base
        return max(0, min(behind, room))
    }
}
