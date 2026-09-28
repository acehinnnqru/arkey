import CoreGraphics
import Foundation
import ImageIO
import RimeEngine

// rime-capture-check: measures a screenshot against the keyboard model, so S3 §2.3 and §4 are one command:
//
//   rime-capture-check --capture <png> [--width 430] [--layer letters] [--dark] [--tolerance 1.5]
//   rime-capture-check --self-test        # paints a keyboard, measures it back, and reports
//
// The device steps it serves are 5 and 6 of docs/device-run.md: a light and a dark screenshot through the
// same code the tests use.

func value(for flag: String, in arguments: [String]) -> String? {
  guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
  return arguments[index + 1]
}

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(2)
}

let arguments = Array(CommandLine.arguments.dropFirst())
let width = value(for: "--width", in: arguments).flatMap(Double.init) ?? 430
let tolerance = value(for: "--tolerance", in: arguments).flatMap(Double.init) ?? 1.5
let layer = RimeKeyboardLayer(rawValue: value(for: "--layer", in: arguments) ?? "letters") ?? .letters
// A dark screenshot measured against the light palette would report a large, meaningless delta, so the
// palette being compared has to be the one the screenshot was taken with.
let palette = arguments.contains("--dark") ? RimeKeyboardPalette.dark : RimeKeyboardPalette.light

func measure(_ capture: RimeKeyboardCapture) {
  let layout = RimeKeyboardLayoutEngine.layout(width: CGFloat(width), layer: layer)
  let scale = capture.scale(against: layout)
  print("capture:  " + String(capture.width) + "x" + String(capture.height) + " px")
  print("model:    " + String(format: "%.1f", layout.size.width) + "x"
        + String(format: "%.1f", layout.size.height) + " pt at " + String(Int(width)) + " pt wide")
  if let scale {
    print("scale:    " + String(format: "%.0f", Double(scale)) + " px per point (inferred)")
  }
  let effective = scale ?? 1
  let differences = capture.differences(from: layout, scale: effective,
                                        tolerance: CGFloat(tolerance) * effective)
  if differences.isEmpty {
    print("geometry: every key within " + String(tolerance) + " pt of the model")
  } else {
    print("geometry: " + String(differences.count) + " finding(s)")
    for difference in differences.prefix(20) { print("  " + difference.description) }
  }
  let deltas = capture.paletteDeltas(against: palette)
  if !deltas.isEmpty {
    print("palette (against the " + (palette.isDark ? "dark" : "light") + " palette):")
    for delta in deltas { print("  " + delta.description) }
  }
}

if arguments.contains("--self-test") {
  // Paints the model as a screenshot would look, then measures it back: the tool proving itself before it
  // is pointed at a device.
  let layout = RimeKeyboardLayoutEngine.layout(width: CGFloat(width), layer: layer)
  let pixelWidth = Int(layout.size.width.rounded() * 3)
  let pixelHeight = Int(layout.size.height.rounded() * 3)
  let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  guard let context else { fail("could not create a drawing context") }
  func paint(_ rect: CGRect, _ colour: RimeKeyboardPalette.Color) {
    context.setFillColor(red: colour.red, green: colour.green, blue: colour.blue, alpha: 1)
    context.fill(CGRect(x: rect.minX * 3, y: Double(pixelHeight) - rect.maxY * 3,
                        width: rect.width * 3, height: rect.height * 3))
  }
  let painter = RimeKeyboardPalette.light
  paint(CGRect(origin: .zero, size: layout.size), painter.backing)
  for key in layout.keys { paint(key.frame, painter.keyCap) }
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("rime-capture-check.png")
  guard let image = context.makeImage(),
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
  else { fail("could not write the test image") }
  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else { fail("could not write the test image") }
  print("self-test: painted a keyboard at 3x and wrote " + url.path)
  do {
    measure(try RimeKeyboardCapture.load(contentsOf: url))
    try? FileManager.default.removeItem(at: url)
  } catch {
    fail("self-test failed: " + String(describing: error))
  }
  exit(0)
}

guard let path = value(for: "--capture", in: arguments) else {
  fail("usage: rime-capture-check --capture <png> [--width 430] [--layer letters] [--tolerance 1.5]\n"
       + "       rime-capture-check --self-test")
}
do {
  measure(try RimeKeyboardCapture.load(contentsOf: URL(fileURLWithPath: path)))
} catch {
  fail("could not read " + path + ": " + String(describing: error))
}
