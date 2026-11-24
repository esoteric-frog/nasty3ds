import AppKit
import Nasty3DSKit
setvbuf(stdout, nil, _IONBF, 0)
func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
let app = NSApplication.shared
let gv = GameView(frame: NSRect(x: 0, y: 0, width: 800, height: 960))
let win = NSWindow(contentRect: gv.frame, styleMask: [.titled], backing: .buffered, defer: false)
win.contentView = gv
gv.layoutSubtreeIfNeeded()
let mode = CommandLine.arguments[1]
Emulator.shared.view = gv
// "sfx": the sound effects of the core must come out of Emulator.onEffects, on the emulation thread.
var effectFrames = 0, effectBad = 0
if mode == "sfx" {
  Emulator.shared.onEffects = { samples, frames in
    effectFrames += frames
    for i in 0..<(frames * 2) where samples[i] != 1234 { effectBad += 1 }
  }
}
do { try Emulator.shared.start(gamePath: "/tmp/game.3ds") } catch { print("start threw:", error); exit(2) }
spin(0.4)
if mode == "view" {
  print("view.isFlipped=\(gv.isFlipped) layer.isGeometryFlipped=\(gv.layer!.isGeometryFlipped) topLayer.frame=\(gv.topLayer.frame) lowerLayer.frame=\(gv.lowerLayer.frame)")
  print("topLayer.contentsRect=\(gv.topLayer.contentsRect) lowerLayer.contentsRect=\(gv.lowerLayer.contentsRect) hasContents=\(gv.topLayer.contents != nil)")
  let rep = gv.bitmapImageRepForCachingDisplay(in: gv.bounds)!
  gv.cacheDisplay(in: gv.bounds, to: rep)
  func px(_ x: Int, _ y: Int) -> String { let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!; return String(format: "r=%.2f g=%.2f b=%.2f", c.redComponent, c.greenComponent, c.blueComponent) }
  let sc = rep.pixelsWide / 800
  print("bitmap \(rep.pixelsWide)x\(rep.pixelsHigh); rep rows count from the top")
  print("pixel in the upper screen area (400,240 of 800x960):", px(400*sc, 240*sc), " expect red (core top screen)")
  print("pixel in the lower screen area (400,720):", px(400*sc, 720*sc), " expect blue (core lower screen)")
  print("pixel left of lower screen (40,720):", px(40*sc, 720*sc), " expect black")
  // mouse: click the visual top-left corner and the bottom-right corner of the lower screen
  func click(_ vx: CGFloat, _ vy: CGFloat) -> (u: Double, v: Double)? {
    Emulator.shared.touch = nil
    let inWin = gv.convert(NSPoint(x: vx, y: vy), to: nil)
    let e = NSEvent.mouseEvent(with: .leftMouseDown, location: inWin, modifierFlags: [], timestamp: 0, windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    gv.mouseDown(with: e); return Emulator.shared.touch
  }
  print("click 10pt inside top-left of lower screen (view-flipped 90,490):", click(90, 490) as Any, " expect u~0.016 v~0.021")
  print("click near bottom-right (710,950):", click(710, 950) as Any, " expect u~0.98 v~0.98")
  print("click on the top screen (400,100):", click(400, 100) as Any, " expect nil")
  Emulator.shared.stop(); exit(0)
}
if mode == "twice" {
  print("second start() while the first game runs (File > Open path)")
  do { try Emulator.shared.start(gamePath: "/tmp/game2.3ds") } catch { print("second start threw:", error) }
  spin(0.6)
  let t0 = Date(); Emulator.shared.stop(); print(String(format: "stop() returned after %.3fs", Date().timeIntervalSince(t0)))
  usleep(200_000); print("probe end"); exit(0)
}
if mode == "restart" {
  Emulator.shared.stop(); print("stopped; start again")
  do { try Emulator.shared.start(gamePath: "/tmp/game2.3ds") } catch { print("second start threw:", error) }
  spin(0.3); print("fps:", Emulator.shared.measuredFPS); Emulator.shared.stop(); print("probe end"); exit(0)
}
if mode == "sfx" {
  let has = Emulator.shared.hasEffects
  Emulator.shared.stop()
  print("effects has=\(has) frames=\(effectFrames) bad=\(effectBad)"); exit(0)
}
if mode == "flip" {
  // The switch must reach the core as a new tilt reading, and each new game must start flat.
  print("flip: upsideDown=\(Emulator.shared.upsideDown)")
  Emulator.shared.upsideDown = true; spin(0.2)
  print("flip: upsideDown=\(Emulator.shared.upsideDown)")
  gv.upsideDown = true
  print("flip: top=\(gv.topLayer.affineTransform()) lower=\(gv.lowerLayer.affineTransform())")
  gv.layoutSubtreeIfNeeded()
  print("flip: topFrame=\(gv.topLayer.frame)")
  gv.upsideDown = false
  print("flip: back top=\(gv.topLayer.affineTransform())")
  do { try Emulator.shared.start(gamePath: "/tmp/game2.3ds") } catch { print("second start threw:", error) }
  spin(0.2)
  print("flip: after a new game upsideDown=\(Emulator.shared.upsideDown)")
  Emulator.shared.stop(); exit(0)
}
