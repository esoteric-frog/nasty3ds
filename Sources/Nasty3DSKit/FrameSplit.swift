public struct PixelRect: Equatable, Sendable {
    public var x: Int, y: Int, width: Int, height: Int
    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

/// Where the two 3DS screens are inside the frame the core draws (Default Top-Bottom layout).
public struct FrameSplit: Equatable, Sendable {
    public let frameWidth: Int, frameHeight: Int
    public var top: PixelRect, lower: PixelRect

    public init(frameWidth: Int, frameHeight: Int) {
        self.frameWidth = frameWidth; self.frameHeight = frameHeight
        let half = frameHeight / 2
        let lowerWidth = frameWidth * 320 / 400
        top = PixelRect(x: 0, y: 0, width: frameWidth, height: half)
        lower = PixelRect(x: (frameWidth - lowerWidth) / 2, y: half, width: lowerWidth, height: frameHeight - half)
    }

    /// A rect as 0...1 fractions of the frame. This is the value for CALayer.contentsRect.
    public func unitRect(_ r: PixelRect) -> (x: Double, y: Double, width: Double, height: Double) {
        (Double(r.x) / Double(frameWidth), Double(r.y) / Double(frameHeight),
         Double(r.width) / Double(frameWidth), Double(r.height) / Double(frameHeight))
    }

    /// Touch at (u, v) inside the lower screen -> libretro pointer units (-32767...32767 over the frame).
    /// Aims at the pixel center, because the core truncates when it converts back.
    public func pointer(u: Double, v: Double) -> (x: Int16, y: Int16) {
        func unit(_ t: Double, _ origin: Int, _ size: Int, _ frame: Int) -> Int16 {
            guard frame > 0, t.isFinite else { return 0 }
            // The pixel under the finger is floor(t * size). The last pixel takes t = 1.
            let index = max(0, min(Double(size - 1), (max(0, min(1, t)) * Double(size)).rounded(.down)))
            let pixel = Double(origin) + index + 0.5
            return Int16((pixel / Double(frame) * 65534 - 32767).rounded())
        }
        var x = unit(u, lower.x, lower.width, frameWidth)
        let y = unit(v, lower.y, lower.height, frameHeight)
        if x == 0 && y == 0 { x = 1 }   // the core treats (0, 0) as "no pointer"
        return (x, y)
    }
}
