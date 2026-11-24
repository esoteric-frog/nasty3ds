import AppKit

/// The small panel under the Rumble button: one slider, 0 (off) to 100.
final class RumblePopover: NSViewController {
    /// Called while the user drags, with the new value.
    var onChange: ((Int) -> Void)?

    private let slider = NSSlider(value: 60, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let valueLabel = NSTextField(labelWithString: "")

    var value: Int {
        get { Int(slider.doubleValue.rounded()) }
        set { slider.doubleValue = Double(max(0, min(100, newValue))); showValue() }
    }

    override func loadView() {
        let title = NSTextField(labelWithString: "Rumble")
        title.font = .preferredFont(forTextStyle: .headline)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        slider.target = self
        slider.action = #selector(changed(_:))
        slider.isContinuous = true
        slider.setAccessibilityLabel("Rumble strength")
        let header = NSStackView(views: [title, valueLabel])
        header.distribution = .fill
        valueLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [header, slider])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 16, right: 16)
        NSLayoutConstraint.activate([
            slider.widthAnchor.constraint(equalToConstant: 220),
            header.widthAnchor.constraint(equalTo: slider.widthAnchor),
        ])
        view = stack
        showValue()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(slider)      // the arrow keys change the value
    }

    @objc private func changed(_ sender: NSSlider) {
        showValue()
        onChange?(value)
    }

    private func showValue() {
        valueLabel.stringValue = value == 0 ? "Off" : "\(value)"
        slider.setAccessibilityValueDescription(value == 0 ? "Off" : "\(value) percent")
    }
}
