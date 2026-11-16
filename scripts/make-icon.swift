// Draws the app icon: the two 3DS screens on a macOS icon tile. Usage: swift make-icon.swift out.png
import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// The macOS icon grid: an 824-point tile, centred, with a soft shadow.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.3).cgColor)
NSColor.black.setFill(); tilePath.fill()
ctx.restoreGState()
ctx.saveGState()
tilePath.addClip()
let colors = [NSColor(srgbRed: 0.36, green: 0.42, blue: 0.98, alpha: 1).cgColor,
              NSColor(srgbRed: 0.10, green: 0.11, blue: 0.24, alpha: 1).cgColor] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
ctx.restoreGState()

// Top screen (5:3) and lower screen (4:3), as on the console.
func screen(_ rect: CGRect, alpha: Double) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    NSColor.white.withAlphaComponent(alpha).setFill()
    NSBezierPath(roundedRect: rect, xRadius: 34, yRadius: 34).fill()
    ctx.restoreGState()
}
screen(CGRect(x: 512 - 250, y: 530, width: 500, height: 300), alpha: 0.96)
screen(CGRect(x: 512 - 200, y: 194, width: 400, height: 300), alpha: 0.62)
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
rep.size = NSSize(width: size, height: size)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
