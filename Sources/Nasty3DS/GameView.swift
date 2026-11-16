import AppKit
import Nasty3DSKit

/// Two layers that show two regions of the same frame. Part 2 hides `lowerLayer` on the Mac.
final class GameView: NSView {
    let topLayer = CALayer()
    let lowerLayer = CALayer()
    private let statusLabel = NSTextField(labelWithString: "")

    var status: String = "" { didSet { statusLabel.stringValue = status; needsLayout = true } }

    enum Mode { case both, topOnly }
    /// `.topOnly` when the lower screen is on the phone.
    var mode: Mode = .both { didSet { lowerLayer.isHidden = mode == .topOnly; needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        for l in [topLayer, lowerLayer] {
            l.contentsGravity = .resize
            l.magnificationFilter = .nearest
            l.actions = ["contents": NSNull(), "contentsRect": NSNull(), "frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
            layer?.addSublayer(l)
        }
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setAccessibilityLabel("Game status")
        addSubview(statusLabel)
        setAccessibilityLabel("Game screen")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    func show(_ image: CGImage, split: FrameSplit) {
        let t = split.unitRect(split.top), l = split.unitRect(split.lower)
        topLayer.contents = image
        topLayer.contentsRect = CGRect(x: t.x, y: t.y, width: t.width, height: t.height)
        lowerLayer.contents = image
        lowerLayer.contentsRect = CGRect(x: l.x, y: l.y, width: l.width, height: l.height)
    }

    /// Top screen 400x240 above lower screen 320x240, largest size that fits, centered.
    override func layout() {
        super.layout()
        let fullHeight: CGFloat = mode == .topOnly ? 240 : 480
        let scale = min(bounds.width / 400, bounds.height / fullHeight)
        let originX = (bounds.width - 400 * scale) / 2
        let originY = (bounds.height - fullHeight * scale) / 2
        topLayer.frame = CGRect(x: originX, y: originY, width: 400 * scale, height: 240 * scale)
        lowerLayer.frame = CGRect(x: originX + 40 * scale, y: originY + 240 * scale, width: 320 * scale, height: 240 * scale)
        statusLabel.sizeToFit()
        statusLabel.setFrameOrigin(NSPoint(x: 8, y: bounds.height - statusLabel.frame.height - 8))
    }

    // MARK: touch (mouse on the lower screen)

    private func touchPoint(_ event: NSEvent) -> (u: Double, v: Double)? {
        let p = convert(event.locationInWindow, from: nil)
        let f = lowerLayer.frame
        guard f.width > 0 else { return nil }
        return (Double((p.x - f.minX) / f.width), Double((p.y - f.minY) / f.height))
    }

    // Only a touch that the Mac mouse started is the mouse's to move or release. In top-only
    // mode the touch comes from the phone, and a click on the Mac must not let it go.
    private var mouseTouching = false

    override func mouseDown(with event: NSEvent) {
        guard mode == .both else { return }
        guard let t = touchPoint(event), (0...1).contains(t.u), (0...1).contains(t.v) else { return }
        mouseTouching = true
        Emulator.shared.touch = t
    }

    override func mouseDragged(with event: NSEvent) {
        guard mouseTouching, mode == .both, let t = touchPoint(event) else { return }
        Emulator.shared.touch = t      // FrameSplit clamps a drag that leaves the screen
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseTouching else { return }
        mouseTouching = false
        Emulator.shared.touch = nil
    }

    // MARK: keyboard fallback (so the app is usable with no controller)

    private static let keys: [UInt16: PadElement] = [
        126: .dpadUp, 125: .dpadDown, 123: .dpadLeft, 124: .dpadRight,
        7: .buttonB,     // X key  -> 3DS A
        6: .buttonA,     // Z key  -> 3DS B
        1: .buttonY,     // S key  -> 3DS X
        0: .buttonX,     // A key  -> 3DS Y
        12: .leftShoulder, 13: .rightShoulder,   // Q, W
        36: .menu, 49: .options,                 // Return = Start, Space = Select
    ]

    override func keyDown(with event: NSEvent) {
        guard let e = Self.keys[event.keyCode] else { return super.keyDown(with: event) }
        Emulator.shared.keyboard.insert(e)
    }

    /// A key-up that goes to another window would leave the key pressed in the game.
    override func resignFirstResponder() -> Bool { Emulator.shared.keyboard.removeAll(); return super.resignFirstResponder() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { _ in
            Emulator.shared.keyboard.removeAll()
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let e = Self.keys[event.keyCode] else { return super.keyUp(with: event) }
        Emulator.shared.keyboard.remove(e)
    }
}
