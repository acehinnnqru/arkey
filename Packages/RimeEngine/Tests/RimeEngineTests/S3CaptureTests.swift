import XCTest
@testable import RimeEngine
import CoreGraphics

/// S3 §2.3 and §4, with the device capture replaced by images the test paints itself. The detector has to
/// recover the model's rectangles from pixels, the reader has to say what colours the picture is made of,
/// and a capture has to survive the path a real one takes — a PNG on disk, decoded by CoreGraphics.
final class S3CaptureTests: XCTestCase {
  /// The width S3 measured the reference layout at (iPhone 15 Pro Max, portrait).
  private let width: CGFloat = 430

  // MARK: Painting

  private func capture(of layout: RimeKeyboardLayout, moving label: String? = nil,
                       by offset: CGSize = .zero, face: Double = 0.85) -> RimeKeyboardCapture {
    let pixelWidth = Int(layout.size.width.rounded())
    let pixelHeight = Int(layout.size.height.rounded())
    var pixels = [Double](repeating: 0, count: pixelWidth * pixelHeight)
    for key in layout.keys {
      let frame = key.label == label ? key.frame.offsetBy(dx: offset.width, dy: offset.height)
                                     : key.frame
      fill(&pixels, width: pixelWidth, height: pixelHeight, rect: frame, value: face)
    }
    return RimeKeyboardCapture(width: pixelWidth, height: pixelHeight, luminance: pixels)
  }

  private func colourCapture(of layout: RimeKeyboardLayout,
                             material: RimeKeyboardPalette.Color,
                             cap: RimeKeyboardPalette.Color) -> RimeKeyboardCapture {
    let pixelWidth = Int(layout.size.width.rounded())
    let pixelHeight = Int(layout.size.height.rounded())
    var pixels = [RimeKeyboardPalette.Color](repeating: material, count: pixelWidth * pixelHeight)
    for key in layout.keys {
      colourFill(&pixels, width: pixelWidth, height: pixelHeight, rect: key.frame, value: cap)
    }
    return RimeKeyboardCapture(width: pixelWidth, height: pixelHeight, colour: pixels)
  }

  /// A picture closer to a device screenshot: a material that changes brightness down the screen, caps with
  /// anti-aliased rounded corners, the one-pixel shadow a cap casts, and a glyph in every cap. Light and
  /// dark differ in *which side* of the material the keys are on.
  private func renderedCapture(of layout: RimeKeyboardLayout,
                               background: (top: Double, bottom: Double),
                               face: Double, glyph: Double, shadow: Double,
                               cornerRadius: Double = 5,
                               glyphShare: Double = 0.34) -> RimeKeyboardCapture {
    let pixelWidth = Int(layout.size.width.rounded())
    let pixelHeight = Int(layout.size.height.rounded())
    var pixels = [Double](repeating: 0, count: pixelWidth * pixelHeight)
    for y in 0..<pixelHeight {
      let t = pixelHeight <= 1 ? 0 : Double(y) / Double(pixelHeight - 1)
      let value = background.top + (background.bottom - background.top) * t
      for x in 0..<pixelWidth { pixels[y * pixelWidth + x] = value }
    }
    for key in layout.keys {
      roundedFill(&pixels, width: pixelWidth, height: pixelHeight, rect: key.frame,
                  cornerRadius: cornerRadius, value: face)
      let shadowRect = CGRect(x: key.frame.minX + cornerRadius, y: key.frame.maxY,
                              width: max(0, key.frame.width - 2 * cornerRadius), height: 1)
      fill(&pixels, width: pixelWidth, height: pixelHeight, rect: shadowRect, value: shadow)
      let half = key.frame.width * glyphShare / 2
      fill(&pixels, width: pixelWidth, height: pixelHeight,
           rect: CGRect(x: key.frame.midX - half, y: key.frame.midY - half * 0.5,
                        width: half * 2, height: half),
           value: glyph)
    }
    return RimeKeyboardCapture(width: pixelWidth, height: pixelHeight, luminance: pixels)
  }

  private func fill(_ pixels: inout [Double], width: Int, height: Int, rect: CGRect, value: Double) {
    let minX = max(0, Int(rect.minX.rounded()))
    let maxX = min(width - 1, Int(rect.maxX.rounded()) - 1)
    let minY = max(0, Int(rect.minY.rounded()))
    let maxY = min(height - 1, Int(rect.maxY.rounded()) - 1)
    guard minX <= maxX, minY <= maxY else { return }
    for y in minY...maxY {
      for x in minX...maxX { pixels[y * width + x] = value }
    }
  }

  private func colourFill(_ pixels: inout [RimeKeyboardPalette.Color], width: Int, height: Int,
                          rect: CGRect, value: RimeKeyboardPalette.Color) {
    let minX = max(0, Int(rect.minX.rounded()))
    let maxX = min(width - 1, Int(rect.maxX.rounded()) - 1)
    let minY = max(0, Int(rect.minY.rounded()))
    let maxY = min(height - 1, Int(rect.maxY.rounded()) - 1)
    guard minX <= maxX, minY <= maxY else { return }
    for y in minY...maxY {
      for x in minX...maxX { pixels[y * width + x] = value }
    }
  }

  /// A pixel's coverage is the signed distance to the rounded outline, which is what a renderer produces.
  private func roundedFill(_ pixels: inout [Double], width: Int, height: Int, rect: CGRect,
                           cornerRadius: Double, value: Double) {
    let minX = Int(rect.minX.rounded(.down))
    let maxX = Int(rect.maxX.rounded(.up))
    let minY = Int(rect.minY.rounded(.down))
    let maxY = Int(rect.maxY.rounded(.up))
    guard minX <= maxX, minY <= maxY else { return }
    for y in max(0, minY)...min(maxY, height - 1) {
      for x in max(0, minX)...min(maxX, width - 1) {
        let coverage = self.coverage(x: x, y: y, rect: rect, radius: cornerRadius)
        guard coverage > 0 else { continue }
        let index = y * width + x
        pixels[index] = pixels[index] * (1 - coverage) + value * coverage
      }
    }
  }

  private func coverage(x: Int, y: Int, rect: CGRect, radius: Double) -> Double {
    let px = Double(x) + 0.5
    let py = Double(y) + 0.5
    let qx = abs(px - rect.midX) - (rect.width / 2 - radius)
    let qy = abs(py - rect.midY) - (rect.height / 2 - radius)
    let outside = (max(qx, 0) * max(qx, 0) + max(qy, 0) * max(qy, 0)).squareRoot()
    let distance = outside + min(max(qx, qy), 0) - radius
    return min(max(0.5 - distance, 0), 1)
  }

  /// The layout painted at `scale` pixels per point.
  private func scaledCapture(of layout: RimeKeyboardLayout, scale: CGFloat) -> RimeKeyboardCapture {
    let pixelWidth = Int((layout.size.width * scale).rounded())
    let pixelHeight = Int((layout.size.height * scale).rounded())
    var pixels = [Double](repeating: 0, count: pixelWidth * pixelHeight)
    for key in layout.keys {
      let frame = key.frame.applying(CGAffineTransform(scaleX: scale, y: scale))
      fill(&pixels, width: pixelWidth, height: pixelHeight, rect: frame, value: 0.85)
    }
    return RimeKeyboardCapture(width: pixelWidth, height: pixelHeight, luminance: pixels)
  }

  // MARK: Geometry

  func testTheDetectorRecoversEveryKeyOfTheMeasuredLayout() throws {
    let layout = RimeKeyboardLayoutEngine.layout(width: width)
    let capture = capture(of: layout)

    XCTAssertEqual(capture.keyRects().count, layout.keys.count, "one rectangle per key")
    XCTAssertEqual(capture.differences(from: layout, tolerance: 1.0), [],
                   "every key is within a point of where the model puts it")
  }

  func testAKeyThatMovedIsReported() throws {
    let layout = RimeKeyboardLayoutEngine.layout(width: width)
    let key = try XCTUnwrap(layout.keys.first { $0.label == "a" })
    let capture = capture(of: layout, moving: "a", by: CGSize(width: 0, height: 4))

    let differences = capture.differences(from: layout, tolerance: 1.0)
    XCTAssertEqual(differences.count, 1, "exactly the key that moved: " + String(describing: differences))
    guard case .moved(let label, _, let actual)? = differences.first else {
      return XCTFail("expected a moved key, got " + String(describing: differences))
    }
    XCTAssertEqual(label, "a")
    XCTAssertEqual(actual.minY - key.frame.minY, 4, accuracy: 1.0)
  }

  func testTheDetectorSurvivesARenderedKeyboardInLightMode() throws {
    let layout = RimeKeyboardLayoutEngine.layout(width: width)
    let capture = renderedCapture(of: layout, background: (0.80, 0.86), face: 1.0,
                                  glyph: 0.15, shadow: 0.62)

    XCTAssertEqual(capture.keyRects().count, layout.keys.count, "one rectangle per key")
    XCTAssertEqual(capture.differences(from: layout, tolerance: 1.5), [],
                   "a rendered light keyboard is measured like a flat one")
  }

  func testTheDetectorSurvivesARenderedKeyboardInDarkMode() throws {
    let layout = RimeKeyboardLayoutEngine.layout(width: width)
    let capture = renderedCapture(of: layout, background: (0.12, 0.18), face: 0.36,
                                  glyph: 0.92, shadow: 0.05)

    XCTAssertEqual(capture.keyRects().count, layout.keys.count, "one rectangle per key")
    XCTAssertEqual(capture.differences(from: layout, tolerance: 1.5), [],
                   "and so is a dark one, where the keys are the brighter side")
  }

  /// A glyph's antialiased edge can land exactly on the material's luminance, and then it **splits** its cap:
  /// the row has three runs — cap-left, glyph, cap-right — of which one extends the cap the detector already
  /// has and the others start blobs of their own. A light keyboard is the case that does it, because a black
  /// glyph on a white cap crosses a ~0.88 material on its way down. Found by rendering the real views and
  /// reading the picture back (the iOS render test, round 143): 103 rectangles for 32 keys. One key is one
  /// rectangle, so detections that overlap are merged.
  func testAGlyphsAntialiasedEdgeDoesNotSplitItsKey() throws {
    let layout = RimeKeyboardLayoutEngine.layout(width: width)
    let pixelWidth = Int(layout.size.width)
    let pixelHeight = Int(layout.size.height)
    var pixels = [Double](repeating: 0.88, count: pixelWidth * pixelHeight)
    for key in layout.keys {
      fill(&pixels, width: pixelWidth, height: pixelHeight, rect: key.frame, value: 1.0)
      let glyph = CGRect(x: key.frame.midX - 8, y: key.frame.midY - 8, width: 16, height: 16)
      fill(&pixels, width: pixelWidth, height: pixelHeight, rect: glyph, value: 0.0)
      for x in [glyph.minX - 1, glyph.maxX] {
        fill(&pixels, width: pixelWidth, height: pixelHeight,
             rect: CGRect(x: x, y: glyph.minY, width: 1, height: glyph.height), value: 0.88)
      }
    }
    let capture = RimeKeyboardCapture(width: pixelWidth, height: pixelHeight, luminance: pixels)

    XCTAssertEqual(capture.keyRects().count, layout.keys.count, "one rectangle per key")
    XCTAssertEqual(capture.differences(from: layout, tolerance: 1.5), [],
                   "a glyph whose edge matches the material is not a key")
  }

  // MARK: Colour (S3 §4)

  func testTheCaptureReportsTheColoursItIsMadeOf() throws {
    let layout = RimeKeyboardLayoutEngine.layout(width: width)
    let material = RimeKeyboardPalette.light.backing
    let cap = RimeKeyboardPalette.light.keyCap
    let capture = colourCapture(of: layout, material: material, cap: cap)

    let dominant = capture.dominantColours(count: 2)
    XCTAssertEqual(dominant.count, 2)
    let ordered = dominant.sorted {
      RimeKeyboardCapture.luminance(of: $0) < RimeKeyboardCapture.luminance(of: $1)
    }
    XCTAssertEqual(ordered[0].hex, material.hex, "the darker bucket is the material")
    XCTAssertEqual(ordered[1].hex, cap.hex, "the lighter one is what the caps are painted")
  }

  func testAPaletteTheCaptureMatchesIsReportedAsSuch() throws {
    let layout = RimeKeyboardLayoutEngine.layout(width: width)
    let palette = RimeKeyboardPalette.light
    let capture = colourCapture(of: layout, material: palette.backing, cap: palette.keyCap)

    let deltas = capture.paletteDeltas(against: palette)
    XCTAssertEqual(deltas.count, 2)
    for delta in deltas { XCTAssertLessThan(delta.delta, 0.01, delta.description) }
  }

  /// The case S3-AC2 is about: a material that is not the one the palette assumes. The number has to land
  /// on the role that moved, and the largest difference has to lead.
  func testAMaterialThatMovedIsReportedByRole() throws {
    let layout = RimeKeyboardLayoutEngine.layout(width: width)
    let palette = RimeKeyboardPalette.light
    let capture = colourCapture(of: layout,
                                material: RimeKeyboardPalette.Color(hex: 0xC9CAD0),
                                cap: palette.keyCap)

    let deltas = capture.paletteDeltas(against: palette)
    let backing = try XCTUnwrap(deltas.first { $0.role == "backing" })
    XCTAssertEqual(backing.delta, 0.083, accuracy: 0.01, "0xDEDFE4 measured as 0xC9CAD0")
    XCTAssertEqual(deltas.first?.role, "backing", "the largest difference leads")
    let caps = try XCTUnwrap(deltas.first { $0.role == "keyCap" })
    XCTAssertLessThan(caps.delta, 0.01, "and the caps are still right")
  }

  // MARK: The file path a device run uses

  /// The loader is the piece a device run actually calls — a screenshot arrives as a file. This writes a
  /// capture as a PNG, reads it back and measures it, which is also the only test of the row order: a
  /// picture whose rows came back flipped put every rectangle in the wrong place, and that is exactly what
  /// this reader did until the row-ramp measurement below was turned into it.
  func testAPngOnDiskLoadsAndMeasuresLikeThePixelsDo() throws {
    let layout = RimeKeyboardLayoutEngine.layout(width: width)
    let palette = RimeKeyboardPalette.light
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkey-capture-" + UUID().uuidString + ".png")
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    try writePNG(of: layout, material: palette.backing, cap: palette.keyCap, to: url)

    let loaded = try RimeKeyboardCapture.load(contentsOf: url)
    XCTAssertEqual(loaded.width, Int(layout.size.width.rounded()))
    XCTAssertEqual(loaded.height, Int(layout.size.height.rounded()))
    XCTAssertEqual(loaded.keyRects().count, layout.keys.count, "every key survives the file")
    XCTAssertEqual(loaded.differences(from: layout, tolerance: 1.5), [],
                   "and lands where the model puts it, so the rows are the right way up")
    let deltas = loaded.paletteDeltas(against: palette)
    XCTAssertEqual(deltas.count, 2)
    for delta in deltas {
      XCTAssertLessThan(delta.delta, 0.02, delta.description + " (through a PNG)")
    }
  }

  /// Paints the layout into a bitmap context and writes it as an RGBA PNG — the path a screenshot takes.
  /// The context's y axis points up and the layout's points down, so a row at `y` is drawn at
  /// `height - 1 - y`; the loader then has to bring the rows back in that same order.
  private func writePNG(of layout: RimeKeyboardLayout,
                        material: RimeKeyboardPalette.Color,
                        cap: RimeKeyboardPalette.Color,
                        to url: URL) throws {
    let pixelWidth = Int(layout.size.width.rounded())
    let pixelHeight = Int(layout.size.height.rounded())
    let context = try XCTUnwrap(CGContext(data: nil, width: pixelWidth, height: pixelHeight,
                                          bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    func paint(_ rect: CGRect, _ colour: RimeKeyboardPalette.Color) {
      context.setFillColor(red: colour.red, green: colour.green, blue: colour.blue, alpha: 1)
      context.fill(CGRect(x: rect.minX, y: Double(pixelHeight) - rect.maxY,
                          width: rect.width, height: rect.height))
    }
    paint(CGRect(x: 0, y: 0, width: layout.size.width, height: layout.size.height), material)
    for key in layout.keys { paint(key.frame, cap) }

    let image = try XCTUnwrap(context.makeImage())
    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,
                                                                    "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination), "the PNG was written")
  }

  // MARK: Scale (a device screenshot is in pixels)

  /// A device screenshot is in pixels: the 430 × 384 pt keyboard arrives as 1290 × 1152 on a 3× phone. The
  /// model has to be scaled into the picture's space, and the capture reports the ratio when it is clean.
  func testADeviceSizedCaptureIsMeasuredWithItsScale() throws {
    let layout = RimeKeyboardLayoutEngine.layout(width: width)
    let capture = scaledCapture(of: layout, scale: 3)

    XCTAssertEqual(try XCTUnwrap(capture.scale(against: layout)), 3, accuracy: 0.01)
    XCTAssertEqual(capture.differences(from: layout, scale: 3, tolerance: 3), [],
                   "a 3× screenshot measures like the model once the scale is given")
  }

  /// Without the scale the comparison cannot say anything about keys, and it says exactly that rather than
  /// returning a page of differences between rectangles that were never in the same space.
  func testACaptureOfTheWrongSizeSaysSoInsteadOfListingNonsense() throws {
    let layout = RimeKeyboardLayoutEngine.layout(width: width)
    let capture = scaledCapture(of: layout, scale: 2)

    let differences = capture.differences(from: layout)
    XCTAssertEqual(differences.count, 1, "one finding, not hundreds: " + String(describing: differences))
    guard case .sizeMismatch(let measured, let model)? = differences.first else {
      return XCTFail("expected a size mismatch, got " + String(describing: differences))
    }
    XCTAssertEqual(measured.width, 860, accuracy: 1)
    XCTAssertEqual(model.height, layout.size.height, accuracy: 1, "the model is in points")
  }
}
