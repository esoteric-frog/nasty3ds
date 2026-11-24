import AppKit
import Nasty3DSKit

/// Two layers that show two regions of the same frame. A mode hides the layer that shows somewhere else.
final class GameView: NSView {
    let topLayer = CALayer()
    let lowerLayer = CALayer()
    private let statusLabel = NSTextField(labelWithString: "")

    var status: String = "" { didSet { statusLabel.stringValue = status; needsLayout = true } }

    enum Mode { case both, topOnly, lowerOnly }
    /// `.topOnly` when the lower screen is on the phone or in its own window. `.lowerOnly` is that window.
    var mode: Mode = .both {
        didSet { lowerLayer.isHidden = mode == .topOnly; topLayer.isHidden = mode == .lowerOnly; needsLayout = true }
    }

    /// The top screen shows upside down, as on a 3DS that the player turned over. The lower screen
    /// stays as it is: a touch must land where the finger is.
    var upsideDown = false {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)      // no slow turn: the picture is a game screen, not a control
            // scale -1, -1 is a half turn with exact numbers (a rotation by pi leaves 1e-16 in the frame)
            topLayer.setAffineTransform(upsideDown ? CGAffineTransform(scaleX: -1, y: -1) : .identity)
            CATransaction.commit()
        }
    }

    /// A second view that shows the same frames (the window for the lower screen).
    weak var companion: GameView?

    /// Called when the pointer starts or stops moving in this view. The window controls show only then.
    var onHover: ((Bool) -> Void)?
    private(set) var hovering = false
    private var hoverTimer: Timer?
    /// The pointer on this view keeps the controls on screen (a button the user is about to click).
    weak var hoverHold: NSView?

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
        statusLabel.alphaValue = 0
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
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
        companion?.show(image, split: split)
    }

    // MARK: hover (the controls and the status text show only while the pointer moves)

    static func fade(_ views: [NSView?], visible: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
            for view in views { view?.animator().alphaValue = visible ? 1 : 0 }
        }
    }

    override func mouseMoved(with event: NSEvent) { setHover(true) }
    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }

    private func setHover(_ on: Bool) {
        hoverTimer?.invalidate()
        if on {
            hoverTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
                guard let self else { return }
                guard let window = self.window else { return self.setHover(false) }
                if let hold = self.hoverHold, hold.window === window,
                   hold.convert(hold.bounds, to: nil).contains(window.mouseLocationOutsideOfEventStream) {
                    return self.setHover(true)      // the pointer rests on a control: wait
                }
                if window.isKeyWindow { NSCursor.setHiddenUntilMouseMoves(true) }
                self.setHover(false)
            }
        }
        guard on != hovering else { return }
        hovering = on
        Self.fade([statusLabel], visible: on)
        onHover?(on)
    }

    /// Top screen 400x240 above lower screen 320x240, largest size that fits, centered.
    override func layout() {
        super.layout()
        if mode == .lowerOnly {
            let scale = min(bounds.width / 320, bounds.height / 240)
            lowerLayer.frame = CGRect(x: (bounds.width - 320 * scale) / 2, y: (bounds.height - 240 * scale) / 2,
                                      width: 320 * scale, height: 240 * scale)
        } else {
            let fullHeight: CGFloat = mode == .topOnly ? 240 : 480
            let scale = min(bounds.width / 400, bounds.height / fullHeight)
            let originX = (bounds.width - 400 * scale) / 2
            let originY = (bounds.height - fullHeight * scale) / 2
            topLayer.frame = CGRect(x: originX, y: originY, width: 400 * scale, height: 240 * scale)
            lowerLayer.frame = CGRect(x: originX + 40 * scale, y: originY + 240 * scale, width: 320 * scale, height: 240 * scale)
        }
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

    /// A click on the lower screen is a touch. A click on any other part moves the window: it has
    /// no title bar to hold. Command-drag moves the window from the lower screen too.
    override func mouseDown(with event: NSEvent) {
        if mode != .topOnly, !event.modifierFlags.contains(.command),
           let t = touchPoint(event), (0...1).contains(t.u), (0...1).contains(t.v) {
            mouseTouching = true
            Emulator.shared.touch = t
            return
        }
        window?.performDrag(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard mouseTouching, mode != .topOnly, let t = touchPoint(event) else { return }
        Emulator.shared.touch = t      // FrameSplit clamps a drag that leaves the screen
    }

    override func mouseUp(with event: NSEvent) { releaseTouch() }

    /// Ends a touch that the mouse started in this view.
    func releaseTouch() {
        guard mouseTouching else { return }
        mouseTouching = false
        Emulator.shared.touch = nil
    }

    /// With two windows, the first click on the window that is not in front is a touch too.
    /// Not when the app is in the background: that click only brings the app to the front.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { NSApp.isActive }

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
