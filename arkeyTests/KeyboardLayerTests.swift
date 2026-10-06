import XCTest
import UIKit
import RimeEngine

/// The keyboard's own transitions, at the layer the model tests cannot reach: a tap on a real key has to
/// change what the grid draws. S3-AC3's layers, shift states and the 中/英 key are engine-tested as *layouts*;
/// what was never checked is the controller wiring them to the grid, which is the same seam that put the
/// callout a key to the left (round 147).
final class KeyboardLayerTests: XCTestCase {
  private func booted() -> KeyboardViewController {
    let controller = KeyboardViewController()
    controller.loadViewIfNeeded()
    controller.view.frame = CGRect(x: 0, y: 0, width: 430, height: 420)
    // The keyboard's *appearance* is what configures the grid from the engine — layers, shift, and the 中/英
    // label, which only exists once refreshLayout has asked the schema. Without it the grid keeps its default
    // configuration, which is what made the first version of the language test see no such key at all.
    controller.viewWillAppear(false)
    controller.view.setNeedsLayout()
    controller.view.layoutIfNeeded()
    return controller
  }

  private func grid(_ controller: KeyboardViewController) throws -> KeyboardKeyGrid {
    try XCTUnwrap(controller.view.subviews.compactMap { $0 as? KeyboardKeyGrid }.first, "no key grid")
  }

  private func buttons(_ grid: KeyboardKeyGrid) -> [KeyButton] {
    grid.setNeedsLayout()
    grid.layoutIfNeeded()
    return grid.subviews.compactMap { $0 as? KeyButton }
  }

  private func titles(_ grid: KeyboardKeyGrid) -> [String] {
    buttons(grid).compactMap { $0.title }
  }

  private func languageButton(_ grid: KeyboardKeyGrid) -> KeyButton? {
    buttons(grid).first { button in
      if case .language? = button.key { return true }
      return false
    }
  }

  private func tap(_ key: KeyboardKey, in grid: KeyboardKeyGrid) throws {
    let button = try XCTUnwrap(buttons(grid).first { $0.key == key }, "no key " + String(describing: key))
    button.sendActions(for: .primaryActionTriggered)
  }

  func testFunctionKeyLabelsFollowSystemLanguageIndependentlyOfInputMode() {
    XCTAssertEqual(KeyboardKeyLabels.space(language: "zh-Hans-CN"), "空格")
    XCTAssertEqual(KeyboardKeyLabels.space(language: "en-US"), "space")
    XCTAssertEqual(KeyboardKeyLabels.returnKey(.default, language: "zh-Hans-CN"), "换行")
    XCTAssertEqual(KeyboardKeyLabels.returnKey(.default, language: "en-US"), "return")
    XCTAssertEqual(KeyboardKeyLabels.returnKey(.send, language: "en-US"), "Send")
    XCTAssertEqual(KeyboardKeyLabels.returnKey(.search, language: "en-US"), "Search")

    let grid = KeyboardKeyGrid(frame: CGRect(x: 0, y: 0, width: 430, height: 300))
    let theme = KeyboardTheme.current(for: .light)
    grid.configure(theme: theme, layer: .letters, asciiMode: false, returnKeyLabel: "return",
                   spaceKeyLabel: "space", showsGlobeRow: false)
    XCTAssertTrue(titles(grid).contains("space"))
    grid.configure(theme: theme, layer: .letters, asciiMode: true, returnKeyLabel: "return",
                   spaceKeyLabel: "space", showsGlobeRow: false)
    XCTAssertTrue(titles(grid).contains("space"))
    XCTAssertTrue(titles(grid).contains("q"), "English mode should start with lowercase letters")
    XCTAssertFalse(titles(grid).contains("Q"))
    let shift = buttons(grid).first { $0.key == .shift }
    XCTAssertEqual(shift?.backgroundColor, theme.fill(for: .wide),
                   "English mode alone should not highlight Shift")
  }

  func testTheLayerKeysChangeWhatTheGridDraws() throws {
    let controller = booted()
    let grid = try grid(controller)
    XCTAssertTrue(titles(grid).contains("q"), "the letters layer is not showing to begin with")

    try tap(.numbers, in: grid)
    XCTAssertTrue(titles(grid).contains("1"),
                  "123 did not switch the board: " + titles(grid).joined(separator: " "))
    XCTAssertFalse(titles(grid).contains("q"), "the letters are still on the numbers layer")
    XCTAssertTrue(titles(grid).contains("?"))
    XCTAssertTrue(buttons(grid).contains { $0.key == .character(".") },
                  "the decimal key still sends a character from the previous layer")

    try tap(.symbols, in: grid)
    let symbols = titles(grid)
    XCTAssertTrue(symbols.contains("-") || symbols.contains("/") || symbols.contains("+"),
                  "the symbols layer did not appear: " + symbols.joined(separator: " "))

    try tap(.letters, in: grid)
    XCTAssertTrue(titles(grid).contains("q"), "ABC did not bring the letters back")
  }

  func testShiftChangesTheLetterCaseOnTheGrid() throws {
    let controller = booted()
    let grid = try grid(controller)
    XCTAssertTrue(titles(grid).contains("q"), "no lower-case letters to begin with")

    // One tap is one key event. A second target on the same control would toggle twice and the board would
    // never leave capitals, which is worth pinning next to the case assertions.
    var fired: [KeyboardKey] = []
    let original = grid.onKey
    grid.onKey = { key in
      fired.append(key)
      original?(key)
    }
    try tap(.shift, in: grid)
    XCTAssertEqual(fired, [.shift], "one tap fired the controller " + String(fired.count) + " time(s)")
    XCTAssertTrue(titles(grid).contains("Q"),
                  "shift did not upper-case the board: " + titles(grid).joined(separator: " "))

    // The second tap has to be outside the double-tap window (0.3 s), or it is the caps-lock gesture and the
    // board is *meant* to stay upper-case.
    Thread.sleep(forTimeInterval: 0.4)
    try tap(.shift, in: grid)
    XCTAssertTrue(titles(grid).contains("q"),
                  "shift did not come back off: " + titles(grid).joined(separator: " "))
  }

  /// The 中/英 key says the state the keyboard is in, in the schema's own word. Tapping it flips both.
  func testTheLanguageKeyFlipsTheStateItNames() throws {
    let controller = booted()
    let grid = try grid(controller)
    try XCTSkipIf(languageButton(grid) == nil,
                  "the bundled tracer schema declares no ascii_mode switch, so the controller draws no 中/英 key; "
                    + "a profile that does (rime-ice) is what the device run installs")
    let before = try XCTUnwrap(languageButton(grid)?.title)

    languageButton(grid)?.sendActions(for: .primaryActionTriggered)

    let after = try XCTUnwrap(languageButton(grid)?.title, "the 中/英 key disappeared after the toggle")
    XCTAssertNotEqual(after, before, "the key still says the old state: " + after)
  }

  /// The grid's own contract, which the controller relies on: a reconfiguration that changes only the
  /// language label still has to redraw that key. The first version of configure compared every field it
  /// applied except language, so a label that changed on its own kept the old word.
  func testReconfiguringWithADifferentLanguageLabelRedrawsIt() throws {
    let grid = KeyboardKeyGrid(frame: CGRect(x: 0, y: 0, width: 430, height: 300))
    let theme = KeyboardTheme.current(for: .light)
    let chinese = RimeLanguageKey(label: "中", isASCII: false)
    let english = RimeLanguageKey(label: "英", isASCII: true)

    grid.configure(theme: theme, layer: .letters, asciiMode: false, returnKeyLabel: "换行",
                   showsGlobeRow: false, language: chinese)
    grid.setNeedsLayout()
    grid.layoutIfNeeded()
    XCTAssertTrue(titles(grid).contains("中"), "the language key does not show its label at all")

    grid.configure(theme: theme, layer: .letters, asciiMode: false, returnKeyLabel: "换行",
                   showsGlobeRow: false, language: english)
    grid.setNeedsLayout()
    grid.layoutIfNeeded()
    XCTAssertTrue(titles(grid).contains("英"),
                  "the grid kept the old language label: " + titles(grid).joined(separator: " "))
  }

  /// S3-AC5: nothing on the input path animates or awaits.
  ///
  /// The awaiting half is synchronous by construction here — a key that had to be awaited could not be driven
  /// from a test method that does not await — and the animating half is what could quietly come back, so it is
  /// checked on every layer of both views the input path touches.
  func testTheInputPathNeitherAwaitsNorAnimates() throws {
    let controller = booted()
    let grid = try grid(controller)
    let bar = try XCTUnwrap(descendants(CandidateBar.self, in: controller.view).first, "no candidate bar")

    try tap(.character("n"), in: grid)
    grid.layoutIfNeeded()

    for (name, view) in [("the key grid", grid as UIView), ("the candidate bar", bar)] {
      let animated = layers(of: view.layer).filter { !($0.animationKeys() ?? []).isEmpty }
      let names = animated.flatMap { $0.animationKeys() ?? [] }
      XCTAssertTrue(animated.isEmpty,
                    name + " animates on the input path: " + names.joined(separator: ", "))
    }
  }

  private func descendants<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
    view.subviews.flatMap { subview -> [T] in
      (subview as? T).map { [$0] } ?? [] } + view.subviews.flatMap { descendants(type, in: $0) }
  }

  private func layers(of layer: CALayer) -> [CALayer] {
    [layer] + (layer.sublayers ?? []).flatMap { layers(of: $0) }
  }
}
