import XCTest
import UIKit
@testable import RimeEngine

/// S3 §2's capture comparison, run on a picture this machine produced instead of one a device produced.
///
/// The keyboard's views are laid out at 3x — the scale a device screenshot arrives at — rendered into a
/// bitmap and written as a PNG, and then read back through RimeKeyboardCapture.load: the same decoder and the
/// same comparison a device screenshot goes through. Two questions are asked of the picture. Do the rendered
/// rectangles sit where the layout model says the keys are? And does every key's fill follow its **role** in
/// the palette — the plain return and space bar the wide cap, the globe no cap at all?
///
/// The palette's own *values* are not this test's subject: they are measured numbers, and the engine's
/// S3AppearanceTests compare them with the hexes the captures recorded. What no test on the Mac can see is
/// whether the views paint from them with the right role, in a real render, and that is what this covers.
/// (A mutation made the distinction plain: moving a palette value changes both the paint and this test's
/// expectation, so it proves nothing; remapping a plain return to the action cap fails it at once.)
///
/// It does not pretend to be a screenshot either. The material path — a UIInputView styled for the keyboard,
/// under a real system material — still needs a device, and no golden bitmap is kept: that would pin the
/// simulator's font rasterisation rather than our palette. The first version of this test did find a real
/// defect in the reader it drives: a glyph's antialiased edge can match the material's luminance and split
/// its cap into three rectangles, which is fixed in RimeKeyboardCapture.keyRects (one key, one rectangle).
final class KeyboardRenderTests: XCTestCase {
  func testLetterTypographyMatchesDeviceReference() throws {
    let reference = ["q": CGSize(width: 33, height: 52), "w": CGSize(width: 51, height: 38),
                     "e": CGSize(width: 31, height: 39), "t": CGSize(width: 20, height: 48),
                     "p": CGSize(width: 32, height: 52)]
    let grid = KeyboardKeyGrid(frame: CGRect(x: 0, y: 0, width: 430, height: 213))
    grid.configure(theme: .current(for: .dark), layer: .letters, asciiMode: false,
                   returnKeyLabel: "Return", showsGlobeRow: false)
    grid.layoutIfNeeded()
    for (letter, expected) in reference {
      let button = try XCTUnwrap(grid.subviews.compactMap { $0 as? KeyButton }.first { $0.title == letter })
      button.layoutIfNeeded()
      let format = UIGraphicsImageRendererFormat.default()
      format.scale = 3
      let image = UIGraphicsImageRenderer(size: button.bounds.size, format: format).image { button.layer.render(in: $0.cgContext) }
      let url = FileManager.default.temporaryDirectory.appendingPathComponent("arkey-letter-reference.png")
      try XCTUnwrap(image.pngData()).write(to: url)
      let capture = try RimeKeyboardCapture.load(contentsOf: url)
      try FileManager.default.removeItem(at: url)
      var xs: [Int] = []; var ys: [Int] = []
      for y in 0..<capture.height { for x in 0..<capture.width where capture.luminance[y * capture.width + x] > 180.0 / 255 {
        xs.append(x); ys.append(y)
      } }
      let glyphWidth = try XCTUnwrap(xs.max()) - XCTUnwrap(xs.min()) + 1
      let glyphHeight = try XCTUnwrap(ys.max()) - XCTUnwrap(ys.min()) + 1
      XCTAssertEqual(CGFloat(glyphWidth), expected.width, accuracy: 2, letter)
      XCTAssertEqual(CGFloat(glyphHeight), expected.height, accuracy: 2, letter)
      let expectedTop: CGFloat = letter == "t" ? 39 : 48
      XCTAssertEqual(CGFloat(try XCTUnwrap(ys.min())), expectedTop, accuracy: 2, letter)
    }
  }

  func testMissingClientAppearancePreservesKeyColoursDuringNavigation() {
    for appearance in [UIKeyboardAppearance.light, .dark] {
      let before = KeyboardTheme.current(for: appearance)
      let detached = KeyboardTheme.current(for: nil, interfaceStyle: .unspecified, previous: before)
      XCTAssertEqual(detached.appearance, before.appearance)
      XCTAssertEqual(detached.keyFill, before.keyFill)
      XCTAssertEqual(detached.candidateText, before.candidateText)
      let reattached = KeyboardTheme.current(for: appearance, previous: detached)
      XCTAssertEqual(reattached.keyFill, before.keyFill)
    }
  }

  func testDefaultKeyboardAppearanceFollowsHostTraits() {
    for style in [UIUserInterfaceStyle.light, .dark] {
      let expected = KeyboardTheme.current(for: style == .dark ? .dark : .light)
      let theme = KeyboardTheme.current(for: .default, interfaceStyle: style)
      XCTAssertEqual(theme.appearance, expected.appearance)
      XCTAssertEqual(theme.keyFill, expected.keyFill)
      XCTAssertEqual(KeyboardTheme.current(for: nil, interfaceStyle: style).keyFill, expected.keyFill)
      let explicit = KeyboardTheme.current(for: .light, interfaceStyle: style)
      XCTAssertEqual(explicit.appearance, .light)
    }
    let dark = KeyboardTheme.current(for: .dark)
    XCTAssertEqual(KeyboardTheme.current(for: .default, previous: dark).keyFill, dark.keyFill)
    let switchedToLight = KeyboardTheme.current(for: .default, interfaceStyle: .light, previous: dark)
    XCTAssertEqual(switchedToLight.appearance, .light)
    XCTAssertNotEqual(switchedToLight.keyFill, dark.keyFill)
  }

  private let width: CGFloat = 430

  /// A device capture arrives at 2x or 3x; so does this one. Rendering at 1x put the cap shadows and the
  /// glyphs on single pixels, which the rectangle detector reads as extra blobs a point or two wide — a
  /// property of a 1x render, not of the keyboard.
  private let scale: CGFloat = 3

  private struct Render {
    let capture: RimeKeyboardCapture
    let layout: RimeKeyboardLayout
    let palette: RimeKeyboardPalette
    let appearance: UIKeyboardAppearance
    let scale: CGFloat
  }

  /// The grid on the theme's own backing, at the measured style — the arrangement the extension builds.
  private func render(_ appearance: UIKeyboardAppearance, globe: Bool = false) throws -> Render {
    let palette = RimeKeyboardPalette.current(isDark: appearance == .dark)
    // The whole keyboard, not a crop of its rows: the candidate slot above and the bottom inset below are
    // material, and the capture reader's rectangle detector is built for that composition — its background
    // is the material the keys sit on, which a tight crop of the rows does not contain enough of. The grid
    // lays its own rows out from its own origin, so it is placed below the slot.
    var style = KeyboardMetrics.style
    style.spaceKeyWidth = width - 2 * style.sideMargin - 3 * style.horizontalGap
      - style.layerKeyWidth - style.emojiKeyWidth - style.returnKeyWidth
    let layout = RimeKeyboardLayoutEngine.layout(width: width, layer: .letters, needsGlobeRow: globe,
                                                 style: style, auxiliaryPrefix: ",")
    let size = layout.size

    let container = UIView(frame: CGRect(origin: .zero, size: size))
    container.backgroundColor = UIColor(red: palette.backing.red, green: palette.backing.green,
                                        blue: palette.backing.blue, alpha: 1)
    let grid = KeyboardKeyGrid(frame: CGRect(x: 0, y: style.candidateSlotHeight, width: size.width,
                                             height: KeyboardKeyGrid.rowsHeight(width: width,
                                                                                needsGlobeRow: globe)))
    grid.configure(theme: KeyboardTheme.current(for: appearance), layer: .letters, asciiMode: false,
                   returnKeyLabel: "换行", showsGlobeRow: globe)
    grid.setNeedsLayout()
    grid.layoutIfNeeded()
    container.addSubview(grid)

    let format = UIGraphicsImageRendererFormat.default()
    format.scale = scale
    let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
      container.layer.render(in: context.cgContext)
    }
    let name = "arkey-render-" + (appearance == .dark ? "dark" : "light") + (globe ? "-globe" : "") + ".png"
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
    try XCTUnwrap(image.pngData()).write(to: url)
    return Render(capture: try RimeKeyboardCapture.load(contentsOf: url), layout: layout,
                  palette: palette, appearance: appearance, scale: scale)
  }

  /// The pixel a point lands on, in the capture's own pixels.
  private func colour(_ render: Render, at point: CGPoint) -> RimeKeyboardPalette.Color {
    let x = min(render.capture.width - 1, max(0, Int(point.x * render.scale)))
    let y = min(render.capture.height - 1, max(0, Int(point.y * render.scale)))
    return render.capture.colour![y * render.capture.width + x]
  }

  /// The most common colour inside a rect: the cap's fill, with the glyph drawn on it and the shadow around
  /// it both outvoted.
  private func fill(_ render: Render, of rect: CGRect) -> RimeKeyboardPalette.Color {
    let inset = rect.insetBy(dx: 2, dy: 2)
    var counts: [UInt32: Int] = [:]
    var sums: [UInt32: (Double, Double, Double)] = [:]
    let step = 1 / render.scale
    var y = inset.minY
    while y < inset.maxY {
      var x = inset.minX
      while x < inset.maxX {
        let pixel = colour(render, at: CGPoint(x: x, y: y))
        let key = (UInt32(pixel.red * 31) << 10) | (UInt32(pixel.green * 31) << 5) | UInt32(pixel.blue * 31)
        counts[key, default: 0] += 1
        let sum = sums[key] ?? (0, 0, 0)
        sums[key] = (sum.0 + pixel.red, sum.1 + pixel.green, sum.2 + pixel.blue)
        x += step
      }
      y += step
    }
    guard let best = counts.max(by: { $0.value < $1.value })?.key,
          let sum = sums[best], let count = counts[best], count > 0 else {
      return RimeKeyboardPalette.Color(red: 0, green: 0, blue: 0)
    }
    return RimeKeyboardPalette.Color(red: sum.0 / Double(count), green: sum.1 / Double(count),
                                     blue: sum.2 / Double(count))
  }

  private func delta(_ one: RimeKeyboardPalette.Color, _ other: RimeKeyboardPalette.Color) -> Double {
    max(abs(one.red - other.red), max(abs(one.green - other.green), abs(one.blue - other.blue)))
  }

  private func hex(_ colour: RimeKeyboardPalette.Color) -> String {
    String(format: "%06X", colour.hex)
  }

  private func assertFill(_ render: Render, of key: RimeKeyboardKey,
                          is expected: RimeKeyboardPalette.Color, tolerance: Double = 0.03,
                          file: StaticString = #filePath, line: UInt = #line) {
    let measured = fill(render, of: key.frame)
    XCTAssertLessThanOrEqual(delta(measured, expected), tolerance,
                             key.label + " is painted " + hex(measured)
                               + ", the palette says " + hex(expected),
                             file: file, line: line)
  }

  private func key(_ render: Render, _ kind: RimeKeyboardKey.Kind) throws -> RimeKeyboardKey {
    try XCTUnwrap(render.layout.keys.first { $0.kind == kind }, "the layout has no such key")
  }

  /// The picture agrees with the model: every key the engine places is a rectangle in the image, in the
  /// same place, within a point. This is the comparison a device capture is put through.
  func testTheRenderedKeysAreWhereTheModelSaysTheyAre() throws {
    for appearance in [UIKeyboardAppearance.light, .dark] {
      let render = try render(appearance)
      let differences = render.capture.differences(from: render.layout, scale: render.scale, tolerance: 1)
      XCTAssertTrue(differences.isEmpty,
                    "the rendered keyboard disagrees with the model: "
                      + differences.prefix(3).map { $0.description }.joined(separator: "; "))
    }
  }

  /// Each key's fill follows its role, in **both** appearances: the return key takes the action colour, the
  /// space bar the wide cap (a different colour from a letter cap in dark mode, which is the rule S3 §4
  /// records), a letter key the letter cap, and the gaps the backing. Remapping any of them fails here.
  func testEveryKeysFillFollowsItsRoleInThePalette() throws {
    for appearance in [UIKeyboardAppearance.light, .dark] {
      let render = try render(appearance)
      let palette = render.palette
      assertFill(render, of: try key(render, .character("a")), is: palette.keyCap)
      assertFill(render, of: try key(render, .space), is: palette.wideKeyCap)
      assertFill(render, of: try key(render, .returnKey), is: palette.wideKeyCap)
      // The material between the keys: the side margin, which no key covers.
      let margin = colour(render, at: CGPoint(x: 2, y: render.layout.rows[0].frame.midY))
      XCTAssertLessThanOrEqual(delta(margin, palette.backing), 0.03,
                               "the backing is " + hex(margin) + " and the palette says " + hex(palette.backing))
    }
  }

  /// The two appearances differ by the rule the captures recorded, not only by value: in light mode a wide
  /// cap is the same white as a letter cap, in dark mode it is lighter than one.
  func testTheWideCapRuleIsTheMeasuredOne() {
    XCTAssertEqual(RimeKeyboardPalette.light.wideKeyCap, RimeKeyboardPalette.light.keyCap,
                   "in light mode the wide cap is the same white as a letter cap")
    XCTAssertNotEqual(RimeKeyboardPalette.dark.wideKeyCap, RimeKeyboardPalette.dark.keyCap,
                      "in dark mode a wide cap is lighter than a letter cap")
  }

  /// The picture is *made of* the palette: its two most used colours are the backing and the cap fill, in
  /// whichever order the areas fall. A third colour large enough to matter — a default system grey, a stale
  /// hard-coded value in one of the views — fails here even if the sampled keys above happen to be right.
  func testThePictureIsMadeOfThePalette() throws {
    for appearance in [UIKeyboardAppearance.light, .dark] {
      let render = try render(appearance)
      let dominant = render.capture.dominantColours(count: 2)
      XCTAssertEqual(dominant.count, 2, "the picture has no dominant colours")
      for colour in dominant {
        let near = min(delta(colour, render.palette.keyCap), delta(colour, render.palette.backing))
        XCTAssertLessThanOrEqual(near, 0.03,
                                 "the picture is mostly " + hex(colour)
                                   + ", which is neither the cap fill nor the backing")
      }
      XCTAssertGreaterThanOrEqual(delta(dominant[0], dominant[1]), 0.05,
                                  "the two dominant colours are the same one, so nothing was measured")
    }
  }

  /// The globe row is painted too — and it is the one place the pixel comparison cannot look, which is worth
  /// pinning rather than skipping.
  func testTheGlobeRowIsPainted() throws {
    let render = try render(.light, globe: true)
    let globe = try key(render, .globe)
    // The globe is the one key with no cap at all — RimeKeyCapRole.plain is transparent — so the material
    // shows through its frame. That is the measured rule, not a fill that went missing.
    assertFill(render, of: globe, is: render.palette.backing)

    // The same fact from the other side: the rectangle detector finds *caps*, so a capless key has no
    // rectangle of its own — but it does have a glyph, and a glyph drawn straight on the material is a blob
    // like any other. So every capped key is found around its own centre, and whatever else is found has to
    // lie inside the globe key's frame: the model and the picture agreeing by a different route.
    let capped = render.layout.keys.filter { $0.kind != .globe }
    let detected = render.capture.keyRects()
    let centres = capped.map { key -> CGPoint in
      let frame = key.frame.applying(CGAffineTransform(scaleX: render.scale, y: render.scale))
      return CGPoint(x: frame.midX, y: frame.midY)
    }
    for (key, centre) in zip(capped, centres) {
      XCTAssertTrue(detected.contains { $0.contains(centre) },
                    key.label + " has no rectangle around its centre")
    }
    let globeFrame = globe.frame.applying(CGAffineTransform(scaleX: render.scale, y: render.scale))
      .insetBy(dx: -2, dy: -2)
    let unmatched = detected.filter { rect in !centres.contains { rect.contains($0) } }
    XCTAssertFalse(unmatched.isEmpty, "not even the globe's glyph was found, so nothing was measured")
    for rect in unmatched {
      XCTAssertTrue(globeFrame.contains(rect),
                    "a rectangle that is neither a capped key nor the globe: " + rect.debugDescription)
    }
  }
}
