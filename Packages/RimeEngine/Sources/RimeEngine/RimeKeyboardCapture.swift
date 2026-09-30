import Foundation
import CoreGraphics
import ImageIO

// MARK: - Capture measurement

/// S3 §2.3's other half: a capture has to be *measured*, not eyeballed. This reads a screenshot of a
/// keyboard, recovers the rectangles the keys occupy, and compares them with the rectangles
/// `RimeKeyboardLayoutEngine` predicts.
///
/// It is deliberately independent of the views: the model says where a key should be, the image says
/// where one is, and the difference between them is the number a capture settles. Nothing here knows
/// about UIKit, so the same code runs on the Mac against a synthetic image (which is what the tests
/// drive) and against a device screenshot (which is what the device run needs).
public struct RimeKeyboardCapture: Sendable {
  public let width: Int
  public let height: Int
  /// Row-major luminance, 0 (black) to 1 (white), first row at the top.
  public let luminance: [Double]
  /// The same pixels in colour, when the capture was loaded from an image or built from colours. The
  /// rectangle detector only needs luminance; S3 §4's material question — does the keyboard's backing
  /// follow the system material, and how far is the measured palette from ours — needs the colour.
  public let colour: [RimeKeyboardPalette.Color]?

  public init(width: Int, height: Int, luminance: [Double]) {
    self.width = width
    self.height = height
    self.luminance = luminance
    self.colour = nil
  }

  /// Builds a capture from colour, deriving the luminance the rectangle detector works on.
  public init(width: Int, height: Int, colour: [RimeKeyboardPalette.Color]) {
    self.width = width
    self.height = height
    self.colour = colour
    self.luminance = colour.map { RimeKeyboardCapture.luminance(of: $0) }
  }

  /// Rec. 709 luma, which is what a grayscale conversion of these colours would use.
  public static func luminance(of colour: RimeKeyboardPalette.Color) -> Double {
    0.2126 * colour.red + 0.7152 * colour.green + 0.0722 * colour.blue
  }

  /// Decodes a screenshot. CoreGraphics hands back rows bottom-up, so they are flipped here: every
  /// rectangle this type reports then has its origin at the top left, which is what the layout model and
  /// every screenshot tool use.
  public static func load(contentsOf url: URL) throws -> RimeKeyboardCapture {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      throw RimeKeyboardCaptureError.unreadableImage(url.lastPathComponent)
    }
    let width = image.width
    let height = image.height
    // Four bytes per pixel: the colour the palette comparison needs, and the luminance the rectangle
    // detector needs, out of one decode. The context owns its buffer and reports its own stride — asking
    // CoreGraphics for a tightly packed buffer and trusting it to be tightly packed is what made an earlier
    // version of this reader produce a scrambled picture (measured: 42 pt wide keys in two bands instead of
    // 32.6 pt keys in four).
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let base = context.data else {
      throw RimeKeyboardCaptureError.unreadableImage(url.lastPathComponent)
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    let rowBytes = context.bytesPerRow
    let bytes = base.assumingMemoryBound(to: UInt8.self)
    var colours: [RimeKeyboardPalette.Color] = []
    colours.reserveCapacity(width * height)
    // Measured with a row-ramp PNG: the context's first byte row is the image's **top**, so the rows are
    // read in order. Reversing them — which is what "CoreGraphics is bottom-up" suggests — produced a
    // vertically mirrored capture, and every rectangle came back in the wrong place.
    for y in 0..<height {
      for x in 0..<width {
        let offset = y * rowBytes + x * 4
        colours.append(RimeKeyboardPalette.Color(red: Double(bytes[offset]) / 255,
                                                 green: Double(bytes[offset + 1]) / 255,
                                                 blue: Double(bytes[offset + 2]) / 255,
                                                 alpha: 1))
      }
    }
    return RimeKeyboardCapture(width: width, height: height, colour: colours)
  }

  /// The key rectangles in the capture.
  ///
  /// The background is the most common luminance — on a keyboard that is the space between the keys. A
  /// pixel counts as key when it differs from the background by more than `threshold`; runs of key pixels
  /// are then merged down the image, so glyphs inside a key do not split it and a gap between two keys
  /// does.
  public func keyRects(threshold: Double = 0.08, minimumLength: Int = 6) -> [CGRect] {
    let background = self.background()
    var open: [Blob] = []
    var closed: [Blob] = []
    var nextID = 0

    for y in 0..<height {
      let runs = self.runs(inRow: y, background: background, threshold: threshold,
                           minimumLength: minimumLength)
      var matched = Set<Int>()
      var next: [Blob] = []
      for run in runs {
        if let index = open.firstIndex(where: { $0.overlaps(run) && !matched.contains($0.id) }) {
          var blob = open[index]
          blob.minX = min(blob.minX, run.minX)
          blob.maxX = max(blob.maxX, run.maxX)
          blob.maxY = y
          matched.insert(blob.id)
          next.append(blob)
        } else {
          nextID += 1
          next.append(Blob(id: nextID, minX: run.minX, maxX: run.maxX, minY: y, maxY: y))
        }
      }
      for blob in open where !matched.contains(blob.id) { closed.append(blob) }
      open = next
    }
    closed.append(contentsOf: open)

    let detected = closed
      .filter { $0.maxY - $0.minY + 1 >= minimumLength }
      .map { blob in
        CGRect(x: CGFloat(blob.minX), y: CGFloat(blob.minY),
               width: CGFloat(blob.maxX - blob.minX + 1), height: CGFloat(blob.maxY - blob.minY + 1))
      }

    // One key is one rectangle. The runs above are merged down the image, but a glyph's **antialiased edge**
    // can land exactly on the material's luminance: that pixel is background, so its row splits into
    // cap-left, glyph and cap-right, only one of which extends the blob already open — the others arrive as
    // rectangles of their own. A light keyboard is the case that does it (a black glyph on a white cap
    // crosses a ~0.88 material on its way down), and a real capture does it too: rendering the app's own
    // views produced 103 rectangles for 32 keys (round 143, the test named
    // testAGlyphsAntialiasedEdgeDoesNotSplitItsKey).
    //
    // Two keys never overlap — there is a gap between them — so rectangles that intersect are one key. The
    // union is repeated until nothing overlaps, because a union can reach a rectangle its parts did not.
    var merged: [CGRect] = []
    for rect in detected {
      var union = rect
      var index = 0
      while index < merged.count {
        if merged[index].intersects(union) {
          union = merged[index].union(union)
          merged.remove(at: index)
          index = 0
        } else {
          index += 1
        }
      }
      merged.append(union)
    }
    return merged.sorted { $0.minY == $1.minY ? $0.minX < $1.minX : $0.minY < $1.minY }
  }

  /// How many capture pixels there are per model point, when that ratio is a whole number.
  /// A device screenshot is in pixels and the model is in points: a 430 × 384 pt keyboard arrives as
  /// 860 × 768 on a 2× phone and 1290 × 1152 on a 3× one. The ratio is only reported when it is clean, so a
  /// capture that is simply the wrong size is not silently scaled into a match.
  public func scale(against layout: RimeKeyboardLayout) -> CGFloat? {
    guard width > 0, height > 0, layout.size.width > 0, layout.size.height > 0 else { return nil }
    let horizontal = CGFloat(width) / layout.size.width
    let vertical = CGFloat(height) / layout.size.height
    guard abs(horizontal - vertical) < 0.02 * horizontal else { return nil }
    let rounded = horizontal.rounded()
    guard rounded >= 1, rounded <= 4, abs(horizontal - rounded) < 0.02 * horizontal else { return nil }
    return rounded
  }

  /// Every way the capture disagrees with the model — a key that moved by more than `tolerance`, a key the
  /// model has and the image does not, a rectangle the image has and the model does not — or, when the two
  /// are not the same size and no scale was given, that fact alone.
  ///
  /// The size guard is the one that matters: without it a 3× screenshot was compared against point
  /// rectangles and produced a long list of nonsense differences, which reads like a broken keyboard rather
  /// than a broken comparison. `scale:` is what turns a device screenshot into a measurement;
  /// `scale(against:)` infers it.
  public func differences(from layout: RimeKeyboardLayout, scale: CGFloat = 1, tolerance: CGFloat = 1.0)
    -> [RimeKeyboardCaptureDifference] {
    let expected = CGSize(width: layout.size.width * scale, height: layout.size.height * scale)
    if abs(CGFloat(width) - expected.width) > 2 * scale || abs(CGFloat(height) - expected.height) > 2 * scale {
      return [.sizeMismatch(capture: CGSize(width: width, height: height), model: expected)]
    }

    var detected = keyRects()
    var differences: [RimeKeyboardCaptureDifference] = []
    for key in layout.keys {
      let frame = key.frame.applying(CGAffineTransform(scaleX: scale, y: scale))
      guard !detected.isEmpty else {
        differences.append(.missing(label: key.label, expected: frame))
        continue
      }
      var best = 0
      var bestDistance = CGFloat.greatestFiniteMagnitude
      for (index, rect) in detected.enumerated() {
        let distance = abs(rect.midX - frame.midX) + abs(rect.midY - frame.midY)
        if distance < bestDistance { bestDistance = distance; best = index }
      }
      let actual = detected.remove(at: best)
      let delta = max(max(abs(actual.minX - frame.minX), abs(actual.maxX - frame.maxX)),
                      max(abs(actual.minY - frame.minY), abs(actual.maxY - frame.maxY)))
      if delta > tolerance * scale {
        differences.append(.moved(label: key.label, expected: frame, actual: actual))
      }
    }
    differences.append(contentsOf: detected.map { RimeKeyboardCaptureDifference.extra($0) })
    return differences
  }
  // MARK: Palette

  /// The colours the picture is made of, most used first.
  ///
  /// Quantising to five bits per channel first is what turns a rendered or photographed keyboard into a
  /// handful of buckets: a material with a gradient still lands in one or two of them, and the key caps in
  /// another. Each bucket is reported as the mean of its own pixels, so a gradient does not turn into its
  /// corner colour.
  public func dominantColours(count: Int = 2) -> [RimeKeyboardPalette.Color] {
    guard let colour, !colour.isEmpty, count > 0 else { return [] }
    var totals: [Int: (pixels: Int, red: Double, green: Double, blue: Double)] = [:]
    for pixel in colour {
      let key = (Int(pixel.red * 31) << 10) | (Int(pixel.green * 31) << 5) | Int(pixel.blue * 31)
      var entry = totals[key] ?? (0, 0, 0, 0)
      entry.pixels += 1
      entry.red += pixel.red
      entry.green += pixel.green
      entry.blue += pixel.blue
      totals[key] = entry
    }
    return totals.values
      .sorted { $0.pixels > $1.pixels }
      .prefix(count)
      .map { entry in
        RimeKeyboardPalette.Color(red: entry.red / Double(entry.pixels),
                                  green: entry.green / Double(entry.pixels),
                                  blue: entry.blue / Double(entry.pixels),
                                  alpha: 1)
      }
  }

  /// How far the capture is from a palette, one row per role, largest difference first.
  ///
  /// This is S3 §4's question turned into a number: `backing` is compared with the colour the picture is
  /// mostly made of (the material between the keys) and `keyCap` with the next one, which is what the caps
  /// are painted. A capture that matches comes back with small numbers; a fixed palette on top of a system
  /// material that moved shows up as a large one.
  public func paletteDeltas(against palette: RimeKeyboardPalette) -> [RimeKeyboardCapturePaletteDelta] {
    let dominant = dominantColours(count: 2)
    guard dominant.count == 2 else { return [] }
    let material = dominant[0]
    let caps = dominant[1]
    return [RimeKeyboardCapturePaletteDelta(role: "backing", expected: palette.backing, measured: material),
            RimeKeyboardCapturePaletteDelta(role: "keyCap", expected: palette.keyCap, measured: caps)]
      .sorted { $0.delta > $1.delta }
  }

  // MARK: Internals

  private struct Blob {
    let id: Int
    var minX: Int
    var maxX: Int
    let minY: Int
    var maxY: Int

    func overlaps(_ run: Run) -> Bool { run.minX <= maxX && run.maxX >= minX }
  }

  private struct Run { let minX: Int; let maxX: Int }

  /// The material between the keys, as one luminance.
  ///
  /// The most common *exact* value is not it: a real keyboard sits on a material that gets brighter or
  /// darker down the screen, so the background is spread over many values while a key cap is one flat
  /// colour — measure it exactly and the cap wins the vote, and the detector then reports the material as
  /// the key. Binning the histogram coarsely first puts a drifting background back into one bucket, and the
  /// value returned is the mean of the pixels in that bucket, which is what a gradient needs.
  private func background() -> Double {
    let bins = 32
    var total = [Int](repeating: 0, count: bins)
    var sum = [Double](repeating: 0, count: bins)
    for value in luminance {
      let bin = min(bins - 1, max(0, Int(value * Double(bins))))
      total[bin] += 1
      sum[bin] += value
    }
    // A background spread by a gradient is a *plateau*: its bucket and the buckets next to it all have
    // mass. A key cap is a spike with empty neighbours, so scoring a bucket together with its neighbours
    // picks the material even when the caps cover more of the picture than any single bucket of it.
    var best = 0
    var bestScore = -1
    for bin in 0..<bins {
      var score = total[bin]
      if bin > 0 { score += total[bin - 1] }
      if bin + 1 < bins { score += total[bin + 1] }
      if score > bestScore { bestScore = score; best = bin }
    }
    var pixels = 0
    var luminanceSum = 0.0
    for bin in max(0, best - 1)...min(bins - 1, best + 1) {
      pixels += total[bin]
      luminanceSum += sum[bin]
    }
    guard pixels > 0 else { return 0 }
    return luminanceSum / Double(pixels)
  }

  private func runs(inRow y: Int, background: Double, threshold: Double,
                    minimumLength: Int) -> [Run] {
    var runs: [Run] = []
    var start: Int?
    for x in 0..<width {
      let isKey = abs(luminance[y * width + x] - background) > threshold
      if isKey, start == nil { start = x }
      if !isKey, let from = start {
        if x - from >= minimumLength { runs.append(Run(minX: from, maxX: x - 1)) }
        start = nil
      }
    }
    if let from = start, width - from >= minimumLength { runs.append(Run(minX: from, maxX: width - 1)) }
    return runs
  }
}

/// One measured difference between a palette and a capture: the role, what the app paints and what the
/// picture actually contains.
public struct RimeKeyboardCapturePaletteDelta: Sendable, Hashable, CustomStringConvertible {
  public let role: String
  public let expected: RimeKeyboardPalette.Color
  public let measured: RimeKeyboardPalette.Color

  /// The largest per-channel difference, 0...1 — the number a threshold is set on.
  public var delta: Double {
    max(abs(expected.red - measured.red),
        max(abs(expected.green - measured.green), abs(expected.blue - measured.blue)))
  }

  public var description: String {
    role + " is off by " + String(format: "%.3f", delta)
  }
}
/// One measured disagreement between a capture and the layout model.
public enum RimeKeyboardCaptureDifference: Sendable, Hashable, CustomStringConvertible {
  case moved(label: String, expected: CGRect, actual: CGRect)
  case missing(label: String, expected: CGRect)
  case extra(CGRect)
  /// The capture and the model are different sizes, so no key can be compared with any other.
  case sizeMismatch(capture: CGSize, model: CGSize)

  public var description: String {
    switch self {
    case .moved(let label, let expected, let actual):
      return "'" + label + "' is at " + RimeKeyboardCaptureDifference.string(actual)
        + ", not " + RimeKeyboardCaptureDifference.string(expected)
    case .missing(let label, let expected):
      return "'" + label + "' is missing where the model puts it at "
        + RimeKeyboardCaptureDifference.string(expected)
    case .extra(let rect):
      return "there is a key at " + RimeKeyboardCaptureDifference.string(rect)
        + " that the model does not have"
    case .sizeMismatch(let capture, let model):
      func size(_ value: CGSize) -> String {
        String(format: "%.0f × %.0f", value.width, value.height)
      }
      return "the capture is " + size(capture) + " and the model expects " + size(model)
        + " — give the scale (a device screenshot is in pixels, the model in points)"
        + " — give the scale (a device screenshot is in pixels, the model in points)"
    }
  }

  private static func string(_ rect: CGRect) -> String {
    "(" + String(format: "%.1f", rect.minX) + ", " + String(format: "%.1f", rect.minY) + ") "
      + String(format: "%.1f", rect.width) + "x" + String(format: "%.1f", rect.height)
  }
}

public enum RimeKeyboardCaptureError: Error, CustomStringConvertible, Sendable {
  case unreadableImage(String)

  public var description: String {
    switch self {
    case .unreadableImage(let name): return "the capture '" + name + "' could not be read"
    }
  }
}