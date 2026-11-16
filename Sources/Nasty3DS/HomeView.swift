import AppKit
import Nasty3DSKit

/// The first thing you see: your games. The game you played last is large, with a Continue
/// button (Return starts it). The other games are icons below it. A game file dropped on the
/// window goes into the library.
final class HomeView: NSView {
    var onPlay: ((LibraryGame) -> Void)?
    var onAdd: (() -> Void)?
    var onDrop: (([URL]) -> Void)?
    var onShowInFinder: ((LibraryGame) -> Void)?
    var onTrash: ((LibraryGame) -> Void)?

    private let backdrop = NSVisualEffectView()
    private let scroll = NSScrollView()
    private let content = FlippedView()
    private let heading = NSTextField(labelWithString: "Games")
    private let addButton = NSButton(title: "Add Game…", target: nil, action: nil)
    private var hero: HeroRow?
    private var tiles: [GameTile] = []
    private var emptyState: NSView?
    private var dropRing = false { didSet { needsDisplay = true; layer?.borderWidth = dropRing ? 3 : 0 } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        backdrop.material = .underWindowBackground
        backdrop.blendingMode = .behindWindow
        backdrop.state = .followsWindowActiveState
        backdrop.autoresizingMask = [.width, .height]
        backdrop.frame = bounds
        addSubview(backdrop)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.autoresizingMask = [.width, .height]
        scroll.frame = bounds
        scroll.documentView = content
        addSubview(scroll)

        heading.font = .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .largeTitle).pointSize, weight: .bold)
        content.addSubview(heading)
        addButton.target = self
        addButton.action = #selector(add(_:))
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        addButton.imagePosition = .imageLeading
        addButton.bezelStyle = .rounded
        addButton.controlSize = .large
        content.addSubview(addButton)

        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func add(_ sender: Any?) { onAdd?() }

    // MARK: content

    func show(_ games: [LibraryGame]) {
        hero?.removeFromSuperview(); hero = nil
        tiles.forEach { $0.removeFromSuperview() }; tiles = []
        emptyState?.removeFromSuperview(); emptyState = nil
        heading.isHidden = games.isEmpty
        addButton.isHidden = games.isEmpty

        if games.isEmpty {
            let empty = makeEmptyState()
            content.addSubview(empty)
            emptyState = empty
        } else {
            var rest = games
            if let first = games.first, first.lastPlayed != nil {
                let row = HeroRow(game: first)
                row.onPlay = { [weak self] in self?.onPlay?(first) }
                row.menu = menu(for: first)
                content.addSubview(row)
                hero = row
                rest.removeFirst()
            }
            for game in rest {
                let tile = GameTile(game: game)
                tile.target = self
                tile.action = #selector(tileClicked(_:))
                tile.menu = menu(for: game)
                content.addSubview(tile)
                tiles.append(tile)
            }
        }
        needsLayout = true
        // Return continues the last game with no click.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.contentView === self else { return }
            self.window?.makeFirstResponder(self.hero?.button ?? self.tiles.first ?? self.emptyButton)
        }
    }

    @objc private func tileClicked(_ sender: GameTile) { onPlay?(sender.game) }

    private func menu(for game: LibraryGame) -> NSMenu {
        let menu = NSMenu()
        let play = NSMenuItem(title: game.lastPlayed == nil ? "Play" : "Continue", action: #selector(menuPlay(_:)), keyEquivalent: "")
        let finder = NSMenuItem(title: "Show in Finder", action: #selector(menuFinder(_:)), keyEquivalent: "")
        let trash = NSMenuItem(title: "Move Game to Trash…", action: #selector(menuTrash(_:)), keyEquivalent: "")
        for item in [play, finder, .separator(), trash] where !item.isSeparatorItem {
            item.target = self
            item.representedObject = game.url
        }
        menu.items = [play, finder, .separator(), trash]
        games[game.url] = game
        return menu
    }
    private var games: [URL: LibraryGame] = [:]
    private func game(_ sender: NSMenuItem) -> LibraryGame? { (sender.representedObject as? URL).flatMap { games[$0] } }
    @objc private func menuPlay(_ sender: NSMenuItem) { game(sender).map { onPlay?($0) } }
    @objc private func menuFinder(_ sender: NSMenuItem) { game(sender).map { onShowInFinder?($0) } }
    @objc private func menuTrash(_ sender: NSMenuItem) { game(sender).map { onTrash?($0) } }

    private weak var emptyButton: NSButton?
    private func makeEmptyState() -> NSView {
        let symbol = NSImageView(image: NSImage(systemSymbolName: "square.and.arrow.down.on.square", accessibilityDescription: nil) ?? NSImage())
        symbol.symbolConfiguration = .init(pointSize: 44, weight: .regular)
        symbol.contentTintColor = .secondaryLabelColor
        let title = NSTextField(labelWithString: "Add your first game")
        title.font = .preferredFont(forTextStyle: .title1)
        let body = NSTextField(wrappingLabelWithString: "Drag a 3DS game file onto this window, or click Add Game. Nasty3DS moves the file into its library.")
        body.font = .preferredFont(forTextStyle: .body)
        body.textColor = .secondaryLabelColor
        body.alignment = .center
        body.preferredMaxLayoutWidth = 340
        let button = NSButton(title: "Add Game…", target: self, action: #selector(add(_:)))
        button.controlSize = .large
        button.keyEquivalent = "\r"
        emptyButton = button
        let stack = NSStackView(views: [symbol, title, body, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(20, after: body)
        stack.translatesAutoresizingMaskIntoConstraints = true
        return stack
    }

    // MARK: layout

    private static let margin: CGFloat = 40

    override func layout() {
        super.layout()
        let width = bounds.width, m = Self.margin
        var y: CGFloat = 28

        if let empty = emptyState {
            let size = empty.fittingSize
            content.frame = NSRect(x: 0, y: 0, width: width, height: max(bounds.height, size.height + 80))
            empty.frame = NSRect(x: (width - size.width) / 2, y: (content.frame.height - size.height) / 2 - 20, width: size.width, height: size.height)
            return
        }

        heading.sizeToFit()
        addButton.sizeToFit()
        heading.setFrameOrigin(NSPoint(x: m, y: y))
        addButton.setFrameOrigin(NSPoint(x: width - m - addButton.frame.width, y: y + (heading.frame.height - addButton.frame.height) / 2))
        y += heading.frame.height + 28

        if let hero {
            hero.frame = NSRect(x: m, y: y, width: width - 2 * m, height: HeroRow.height)
            y += HeroRow.height + (tiles.isEmpty ? 0 : 44)
        }
        // Icons in rows, like a Finder icon view: as many columns as fit, spread to the full width.
        let columns = max(1, Int((width - 2 * m + 24) / (GameTile.size.width + 24)))
        let gap = columns > 1 ? max(24, (width - 2 * m - CGFloat(columns) * GameTile.size.width) / CGFloat(columns - 1)) : 0
        for (i, tile) in tiles.enumerated() {
            let column = CGFloat(i % columns), row = CGFloat(i / columns)
            tile.frame = NSRect(x: m + column * (GameTile.size.width + min(gap, 56)), y: y + row * (GameTile.size.height + 28),
                                width: GameTile.size.width, height: GameTile.size.height)
        }
        if !tiles.isEmpty { y += CGFloat((tiles.count - 1) / columns + 1) * (GameTile.size.height + 28) }
        content.frame = NSRect(x: 0, y: 0, width: width, height: max(bounds.height, y + 28))
    }

    // MARK: drop a game file on the window

    private func gameFiles(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { GameFile.extensions.contains($0.pathExtension.lowercased()) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropRing = !gameFiles(sender).isEmpty
        return dropRing ? .copy : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropRing = false }
    override func draggingEnded(_ sender: NSDraggingInfo) { dropRing = false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = gameFiles(sender)
        dropRing = false
        guard !files.isEmpty else { return false }
        DispatchQueue.main.async { [weak self] in self?.onDrop?(files) }      // after the drag ends: an alert must not block Finder
        return true
    }

    /// Diagnosis aid: N3_SNAPSHOT_DIR=/folder writes a PNG of this view there. Not in the app bundle.
    func snapshotIfAsked() {
        guard Bundle.main.bundleURL.pathExtension != "app",
              let folder = ProcessInfo.processInfo.environment["N3_SNAPSHOT_DIR"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
            guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return }
            cacheDisplay(in: bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appendingPathComponent("home.png"))
        }
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - the game's own icon, with depth

/// The 48 x 48 icon from the game file, drawn sharp (pixel art) on a rounded tile with a soft shadow.
/// A game with no readable icon gets a quiet tile with a controller symbol.
final class GameIconView: NSView {
    private let shadowLayer = CALayer()
    private let imageLayer = CALayer()

    init(game: LibraryGame, side: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        wantsLayer = true
        layer?.masksToBounds = false
        let radius = side * 0.225
        shadowLayer.frame = bounds
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.28
        shadowLayer.shadowRadius = side * 0.09
        shadowLayer.shadowOffset = CGSize(width: 0, height: -side * 0.04)
        shadowLayer.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        layer?.addSublayer(shadowLayer)

        imageLayer.frame = bounds
        imageLayer.cornerRadius = radius
        imageLayer.cornerCurve = .continuous
        imageLayer.masksToBounds = true
        imageLayer.magnificationFilter = .nearest
        imageLayer.borderWidth = 0.5
        imageLayer.borderColor = NSColor.black.withAlphaComponent(0.18).cgColor
        if let pixels = game.icon, let image = Self.image(pixels) {
            imageLayer.contents = image
        } else {
            imageLayer.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            let symbol = NSImageView(image: NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: nil) ?? NSImage())
            symbol.symbolConfiguration = .init(pointSize: side * 0.34, weight: .regular)
            symbol.contentTintColor = .secondaryLabelColor
            symbol.frame = bounds
            addSubview(symbol)
        }
        layer?.insertSublayer(imageLayer, above: shadowLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The icon is pixel art: 48 x 48. It is made 6 times larger with hard pixel edges, so it stays sharp.
    static func image(_ rgba: [UInt8]) -> CGImage? {
        let side = GameFile.iconSide, big = side * 6
        guard rgba.count == side * side * 4, let provider = CGDataProvider(data: Data(rgba) as CFData),
              let small = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let context = CGContext(data: nil, width: big, height: big, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .none
        context.draw(small, in: CGRect(x: 0, y: 0, width: big, height: big))
        return context.makeImage()
    }

    /// Lifts a little under the pointer and sinks when pressed. No motion when the user asked for less.
    func setLift(_ scale: CGFloat, shadow: Float) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.22)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1))
        let move = CGAffineTransform(translationX: bounds.midX, y: bounds.midY).scaledBy(x: scale, y: scale).translatedBy(x: -bounds.midX, y: -bounds.midY)
        layer?.setAffineTransform(move)
        shadowLayer.shadowOpacity = shadow
        CATransaction.commit()
    }
}

func playedText(_ game: LibraryGame) -> String {
    guard let date = game.lastPlayed else { return "Not played yet" }
    if Date().timeIntervalSince(date) < 90 { return "Played just now" }
    let format = RelativeDateTimeFormatter()
    format.unitsStyle = .full
    return "Played " + format.localizedString(for: date, relativeTo: Date())
}

// MARK: - one game in the grid: the icon is the button

final class GameTile: NSButton {
    static let size = NSSize(width: 132, height: 172)
    let game: LibraryGame
    private let icon: GameIconView
    private var hovering = false

    init(game: LibraryGame) {
        self.game = game
        icon = GameIconView(game: game, side: 96)
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .exterior
        icon.setFrameOrigin(NSPoint(x: (Self.size.width - 96) / 2, y: 6))      // NSButton counts from the top
        addSubview(icon)

        let name = NSTextField(wrappingLabelWithString: game.title)
        name.font = .preferredFont(forTextStyle: .headline)
        name.alignment = .center
        name.maximumNumberOfLines = 2
        name.lineBreakMode = .byTruncatingTail
        let nameHeight = min(38, ceil(name.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: Self.size.width, height: 38)).height ?? 19))
        name.frame = NSRect(x: 0, y: 112, width: Self.size.width, height: nameHeight)
        addSubview(name)
        let played = NSTextField(labelWithString: playedText(game))
        played.font = .preferredFont(forTextStyle: .subheadline)
        played.textColor = .secondaryLabelColor
        played.alignment = .center
        played.lineBreakMode = .byTruncatingTail
        played.frame = NSRect(x: 0, y: 112 + nameHeight + 2, width: Self.size.width, height: 18)
        addSubview(played)

        toolTip = game.title
        setAccessibilityLabel((game.lastPlayed == nil ? "Play " : "Continue ") + game.title)
        setAccessibilityHelp(playedText(game))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }     // the labels are part of the button
    override func draw(_ dirtyRect: NSRect) {}
    override func drawFocusRingMask() { NSBezierPath(roundedRect: icon.frame, xRadius: 22, yRadius: 22).fill() }
    override var focusRingMaskBounds: NSRect { icon.frame }
    override func mouseEntered(with event: NSEvent) { hovering = true; icon.setLift(1.05, shadow: 0.4) }
    override func mouseExited(with event: NSEvent) { hovering = false; icon.setLift(1, shadow: 0.28) }
    override func mouseDown(with event: NSEvent) {
        icon.setLift(0.96, shadow: 0.18)
        super.mouseDown(with: event)             // returns after the mouse is up
        icon.setLift(hovering ? 1.05 : 1, shadow: hovering ? 0.4 : 0.28)
    }
}

// MARK: - the game you played last

final class HeroRow: NSView {
    static let height: CGFloat = 144
    var onPlay: (() -> Void)?
    let button = NSButton(title: "Continue", target: nil, action: nil)
    private let icon: GameIconView

    init(game: LibraryGame) {
        icon = GameIconView(game: game, side: 144)
        super.init(frame: .zero)
        addSubview(icon)

        let name = NSTextField(wrappingLabelWithString: game.title)
        name.font = .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .title1).pointSize, weight: .semibold)
        name.maximumNumberOfLines = 2
        name.lineBreakMode = .byTruncatingTail
        let played = NSTextField(labelWithString: playedText(game))
        played.font = .preferredFont(forTextStyle: .body)
        played.textColor = .secondaryLabelColor
        button.target = self
        button.action = #selector(play(_:))
        button.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.controlSize = .large
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        button.setAccessibilityLabel("Continue \(game.title)")

        let text = NSStackView(views: [name, played, button])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        text.setCustomSpacing(16, after: played)
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 144 + 28),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        // The icon is a second way to continue, for the pointer.
        let click = NSClickGestureRecognizer(target: self, action: #selector(play(_:)))
        icon.addGestureRecognizer(click)
        icon.setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    @objc private func play(_ sender: Any?) { onPlay?() }
}
