import GameController
import Nasty3DSKit

/// Reads the current game controller on the main thread and publishes a snapshot.
final class PadInput {
    var onChange: ((PadSnapshot, String?) -> Void)?

    private var started = false

    func start() {
        guard !started else { return attach() }     // a second File > Open must not add the observers again
        started = true
        let center = NotificationCenter.default
        center.addObserver(forName: .GCControllerDidBecomeCurrent, object: nil, queue: .main) { [weak self] _ in self?.attach() }
        center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in self?.attach() }
        center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in self?.attach() }
        GCController.shouldMonitorBackgroundEvents = false
        attach()
    }

    private func attach() {
        guard let controller = GCController.current ?? GCController.controllers().first,
              let gamepad = controller.extendedGamepad else {
            onChange?(PadSnapshot(), nil)
            return
        }
        let name = controller.vendorName ?? "Controller"
        gamepad.valueChangedHandler = { [weak self] g, _ in self?.onChange?(Self.snapshot(g), name) }
        onChange?(Self.snapshot(gamepad), name)
    }

    private static func snapshot(_ g: GCExtendedGamepad) -> PadSnapshot {
        let buttons: [(PadElement, GCControllerButtonInput?)] = [
            (.buttonA, g.buttonA), (.buttonB, g.buttonB), (.buttonX, g.buttonX), (.buttonY, g.buttonY),
            (.leftShoulder, g.leftShoulder), (.rightShoulder, g.rightShoulder),
            (.leftTrigger, g.leftTrigger), (.rightTrigger, g.rightTrigger),
            (.dpadUp, g.dpad.up), (.dpadDown, g.dpad.down), (.dpadLeft, g.dpad.left), (.dpadRight, g.dpad.right),
            (.menu, g.buttonMenu), (.options, g.buttonOptions),
        ]
        var pressed = Set<PadElement>()
        for (element, button) in buttons where button?.isPressed == true { pressed.insert(element) }
        return PadSnapshot(pressed: pressed,
                           lx: g.leftThumbstick.xAxis.value, ly: g.leftThumbstick.yAxis.value,
                           rx: g.rightThumbstick.xAxis.value, ry: g.rightThumbstick.yAxis.value)
    }
}
