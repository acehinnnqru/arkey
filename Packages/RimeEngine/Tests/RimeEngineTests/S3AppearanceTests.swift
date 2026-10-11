import XCTest
import CoreGraphics
@testable import RimeEngine

/// S3 §4 and §5 as data: the measured palette, the feedback timings, the callout's clamp, and the
/// shift machine. None of it needs a device, and all of it is what the views read.
final class S3AppearanceTests: XCTestCase {
  private let style = RimeKeyboardStyle.measured
  private let feedback = RimeKeyFeedback.standard

  private func layout(_ layer: RimeKeyboardLayer = .letters,
                      shift: RimeShiftState = .off) -> RimeKeyboardLayout {
    RimeKeyboardLayoutEngine.layout(width: 430, layer: layer, shift: shift, style: style)
  }

  // MARK: Palette

  func testTheMeasuredPaletteIsWhatTheCapturesSay() {
    let light = RimeKeyboardPalette.light
    XCTAssertEqual(light.backing.hex, 0xDEDFE4)
    XCTAssertEqual(light.keyCap.hex, 0xFEFEFE)
    XCTAssertEqual(light.wideKeyCap.hex, 0xFEFEFE, "in light mode every key cap is white")
    XCTAssertEqual(light.actionEnabled.hex, 0x3378F4)
    XCTAssertEqual(light.glyph.hex, 0x000000)

    let dark = RimeKeyboardPalette.dark
    XCTAssertEqual(dark.backing.hex, 0x161616)
    XCTAssertEqual(dark.keyCap.hex, 0x3D3D3D)
    XCTAssertEqual(dark.wideKeyCap.hex, 0x444444, "wider keys are lighter in dark mode")
    XCTAssertEqual(dark.actionDisabled.hex, 0x737373)
    XCTAssertEqual(dark.actionEnabled.hex, light.actionEnabled.hex, "the action key is the same blue")
    XCTAssertEqual(dark.glyph.hex, 0xFFFFFF)

    // The material decision is data, not a comment: both palettes say the backing should come from
    // the system when it can.
    XCTAssertTrue(light.backingFollowsMaterial)
    XCTAssertTrue(dark.backingFollowsMaterial)
    XCTAssertEqual(RimeKeyboardPalette.current(isDark: true), dark)
    XCTAssertEqual(RimeKeyboardPalette.current(isDark: false), light)
  }

  func testCapFillsFollowTheOppositeRulesOfTheLegacyKeyboard() throws {
    let letters = layout()
    let letter = try XCTUnwrap(letters.keys.first { $0.isCharacter })
    let delete = try XCTUnwrap(letters.keys.first { $0.kind == .delete })
    let space = try XCTUnwrap(letters.keys.first { $0.kind == .space })

    XCTAssertEqual(RimeKeyboardPalette.light.capFill(for: letter, isPressed: false).hex, 0xFEFEFE)
    XCTAssertEqual(RimeKeyboardPalette.light.capFill(for: delete, isPressed: false).hex, 0xFEFEFE,
                   "shift, delete and the bottom row are white too; only the glyph differs")
    XCTAssertEqual(RimeKeyboardPalette.light.capFill(for: space, isPressed: false).hex, 0xFEFEFE)

    XCTAssertEqual(RimeKeyboardPalette.dark.capFill(for: letter, isPressed: false).hex, 0x3D3D3D)
    XCTAssertEqual(RimeKeyboardPalette.dark.capFill(for: delete, isPressed: false).hex, 0x444444)

    // Pressed: letter caps darken in light and lighten in dark.
    let lightLetterPressed = RimeKeyboardPalette.light.capFill(for: letter, isPressed: true).hex
    XCTAssertLessThan(lightLetterPressed, 0xFEFEFE)
    let darkLetterPressed = RimeKeyboardPalette.dark.capFill(for: letter, isPressed: true).hex
    XCTAssertGreaterThan(darkLetterPressed, 0x3D3D3D)
    // And the wider keys move the other way.
    XCTAssertLessThan(RimeKeyboardPalette.dark.capFill(for: delete, isPressed: true).hex, 0x444444)
  }

  func testTheActionKeyHasTwoMeasuredStates() {
    let palette = RimeKeyboardPalette.light
    XCTAssertEqual(palette.returnKeyFill(isEnabled: true).hex, 0x3378F4)
    XCTAssertNotEqual(palette.returnKeyFill(isEnabled: false).hex, 0x3378F4)
    XCTAssertEqual(RimeKeyboardPalette.dark.returnKeyFill(isEnabled: false).hex, 0x737373)
  }

  // MARK: Feedback

  func testTheDeleteRepeatScheduleIsTheShippedOne() {
    let schedule = RimeKeyFeedbackPolicy.deleteRepeatSchedule()
    XCTAssertEqual(schedule.delay, 0.5)
    XCTAssertEqual(schedule.interval, 0.1)

    // A slide past the threshold cancels the repeat; a small one does not.
    XCTAssertFalse(RimeKeyFeedbackPolicy.cancelsDeleteRepeat(translation: CGSize(width: 30, height: 10)))
    XCTAssertTrue(RimeKeyFeedbackPolicy.cancelsDeleteRepeat(translation: CGSize(width: 60, height: 0)))
    XCTAssertTrue(RimeKeyFeedbackPolicy.cancelsDeleteRepeat(translation: CGSize(width: 0, height: -55)))
    XCTAssertFalse(RimeKeyFeedbackPolicy.cancelsDeleteRepeat(translation: CGSize(width: 50, height: 50)),
                   "the threshold is exclusive, as the recorded 50 pt suggests")
  }

  func testOnlyCharacterKeysRaiseACallout() throws {
    let letters = layout()
    var custom = feedback
    custom.calloutForModifierKeys = true

    for key in letters.keys {
      let expected = key.isCharacter && key.isCore && !key.isAuxiliary
      XCTAssertEqual(RimeKeyFeedbackPolicy.raisesCallout(key, feedback: feedback), expected,
                     "callout policy for \(key.kind)")
      XCTAssertEqual(RimeKeyFeedbackPolicy.raisesCallout(key, feedback: custom), expected,
                     "modifier overrides cannot enable callouts outside core character keys")
    }

    let character = try XCTUnwrap(letters.keys.first { $0.isCharacter })
    XCTAssertFalse(RimeKeyFeedbackPolicy.raisesCallout(character, isPhoneClass: false),
                   "iPad-class devices have no callout")
    XCTAssertFalse(RimeKeyFeedbackPolicy.raisesCallout(character, isRepeatingDelete: true),
                   "nothing raises a callout while delete repeats")
  }

  func testCalloutsExcludeBottomRowAcrossAllLayers() {
    for layer: RimeKeyboardLayer in [.letters, .numbers, .symbols] {
      let keyboard = RimeKeyboardLayoutEngine.layout(
        width: 430, layer: layer, needsGlobeRow: true,
        punctuationLabels: [",": "，", ".": "。"])
      for (rowIndex, row) in keyboard.rows.enumerated() {
        for key in row.keys {
          XCTAssertEqual(RimeKeyFeedbackPolicy.raisesCallout(key),
                         rowIndex < 3 && key.isCharacter,
                         "Unexpected callout in row \(rowIndex) for \(key.kind)")
        }
      }
    }
  }

  // MARK: Callout geometry

  /// R10 in numbers: the callout must fit inside the extension's own frame, so the first row's is
  /// clipped by the candidate slot and the keyboard owes it the difference.
  func testTheCalloutNeverEscapesTheKeyboardAndTheFirstRowIsClipped() throws {
    let bounds = CGRect(x: 0, y: 0, width: 430, height: layout().height)
    XCTAssertEqual(RimeCalloutGeometry.requiredTopSlot(feedback: feedback), 64)
    XCTAssertEqual(feedback.calloutSlotShortfall(candidateSlotHeight: 39.7), 24.3, accuracy: 0.01,
                   "the measured slot cannot hold a full-height callout; the keyboard must grow")

    for layer in RimeKeyboardLayer.allCases {
      let grid = layout(layer)
      for key in grid.keys {
        let callout = RimeCalloutGeometry.frame(for: key, in: bounds, feedback: feedback)
        XCTAssertGreaterThanOrEqual(callout.minX, bounds.minX - 0.001, "\(key.kind) escapes left")
        XCTAssertLessThanOrEqual(callout.maxX, bounds.maxX + 0.001, "\(key.kind) escapes right")
        XCTAssertGreaterThanOrEqual(callout.minY, bounds.minY - 0.001, "\(key.kind) escapes the top")
        XCTAssertLessThanOrEqual(callout.maxY, key.frame.minY + 0.001,
                                 "\(key.kind): the callout sits above its key")
        XCTAssertEqual(callout.width, key.frame.width * feedback.calloutWidthScale, accuracy: 0.001)
      }
    }

    // The first letter row: 39.7 pt of room, so 39.7 pt of callout rather than 64.
    let firstRow = try XCTUnwrap(layout().rows.first)
    let firstKey = try XCTUnwrap(firstRow.keys.first)
    let callout = RimeCalloutGeometry.frame(for: firstKey, in: bounds, feedback: feedback)
    XCTAssertEqual(RimeCalloutGeometry.availableHeight(for: firstKey, in: bounds), 39.7, accuracy: 0.01)
    XCTAssertEqual(callout.height, 39.7, accuracy: 0.01)
    XCTAssertEqual(callout.maxY, firstKey.frame.minY, accuracy: 0.01)

    // The second row has the room the first one does not.
    let secondKey = try XCTUnwrap(layout().rows[1].keys.first)
    XCTAssertGreaterThanOrEqual(RimeCalloutGeometry.availableHeight(for: secondKey, in: bounds),
                                feedback.calloutMinimumHeight)
    XCTAssertEqual(RimeCalloutGeometry.frame(for: secondKey, in: bounds, feedback: feedback).height,
                   64, accuracy: 0.01)
  }

  func testTheCalloutIsClampedHorizontallyAtTheEdges() throws {
    let bounds = CGRect(x: 0, y: 0, width: 430, height: layout().height)
    let keys = layout().keys

    // A letter key sits far enough from the edge that its centred callout needs no clamping.
    let letter = try XCTUnwrap(keys.first { $0.kind == .character(.init("e")) })
    let letterCallout = RimeCalloutGeometry.frame(for: letter, in: bounds, feedback: feedback)
    XCTAssertEqual(letterCallout.minX, letter.frame.midX - letterCallout.width / 2, accuracy: 0.01)

    // The return key is wide and near the right edge: its centred callout would end past the
    // keyboard, so it is clamped — an extension cannot draw outside its own frame.
    let returnKey = try XCTUnwrap(keys.first { $0.kind == .returnKey })
    let callout = RimeCalloutGeometry.frame(for: returnKey, in: bounds, feedback: feedback)
    XCTAssertEqual(callout.width, 96.4 * feedback.calloutWidthScale, accuracy: 0.01)
    XCTAssertEqual(callout.maxX, bounds.maxX, accuracy: 0.01, "clamped to the right edge")
    XCTAssertLessThan(callout.minX, returnKey.frame.midX - callout.width / 2,
                      "and therefore no longer centred on the key")
    XCTAssertGreaterThanOrEqual(callout.minX, bounds.minX)
  }

  /// Following the finger must not be a way out of the keyboard: the clamp is the same one.
  func testTheCalloutFollowsTheFingerAndStaysClamped() throws {
    let bounds = CGRect(x: 0, y: 0, width: 430, height: layout().height)
    let key = try XCTUnwrap(layout().keys.first { $0.kind == .character(.init("q")) })

    let centred = RimeCalloutGeometry.frame(for: key, in: bounds, feedback: feedback)
    XCTAssertEqual(centred.minX, bounds.minX, accuracy: 0.01,
                   "the enlarged callout for q is clamped to the left edge")

    // A finger to the right of the key moves the callout right, still clamped inside.
    let right = RimeCalloutGeometry.frame(for: key, in: bounds, fingerX: key.frame.midX + 60,
                                          feedback: feedback)
    XCTAssertGreaterThan(right.minX, centred.minX)
    XCTAssertLessThanOrEqual(right.maxX, bounds.maxX + 0.001)

    // A finger past the edge pins it to the edge rather than letting it escape.
    let pinned = RimeCalloutGeometry.frame(for: key, in: bounds, fingerX: bounds.maxX + 200,
                                           feedback: feedback)
    XCTAssertEqual(pinned.maxX, bounds.maxX, accuracy: 0.01)
    let pinnedLeft = RimeCalloutGeometry.frame(for: key, in: bounds, fingerX: -200,
                                               feedback: feedback)
    XCTAssertEqual(pinnedLeft.minX, bounds.minX, accuracy: 0.01)

    // And it never leaves its key's row, whatever the finger does.
    XCTAssertEqual(pinned.minY, centred.minY, accuracy: 0.01)
  }

  // MARK: Shift

  func testShiftIsOneShotAndDoubleTapLocks() {
    var controller = RimeShiftController()
    let start = Date()
    XCTAssertEqual(controller.state, .off)
    XCTAssertFalse(controller.isActive)

    XCTAssertEqual(controller.tap(at: start), .on)
    XCTAssertTrue(controller.isActive)
    XCTAssertEqual(controller.tap(at: start.addingTimeInterval(1.0)), .off,
                   "a slow second tap turns it off again")

    XCTAssertEqual(controller.tap(at: start), .on)
    XCTAssertEqual(controller.tap(at: start.addingTimeInterval(0.15)), .caps,
                   "a quick second tap locks caps")

    // Caps survives a character; a one-shot does not.
    XCTAssertEqual(controller.consumeAfterCharacter(), .caps)
    controller.reset()
    XCTAssertEqual(controller.tap(at: start), .on)
    XCTAssertEqual(controller.consumeAfterCharacter(), .off)
    XCTAssertEqual(controller.consumeAfterCharacter(), .off, "consuming twice is harmless")

    // A tap while locked clears it.
    controller.reset()
    _ = controller.tap(at: start)
    _ = controller.tap(at: start.addingTimeInterval(0.1))
    XCTAssertEqual(controller.state, .caps)
    XCTAssertEqual(controller.tap(at: start.addingTimeInterval(1.0)), .off)
  }

  /// The role table is now the only place the cap rule lives, so it is pinned twice: every role against the
  /// palette field it names, and the key-level entry point against the role it should pick. When the keyboard
  /// view had its own style-to-colour mapping this table could not be wrong without the screen showing it.
  func testEveryCapRoleIsThePaletteFieldItNames() {
    for palette in [RimeKeyboardPalette.light, RimeKeyboardPalette.dark] {
      XCTAssertEqual(RimeKeyCapRole.letter.colour(in: palette).hex, palette.keyCap.hex)
      XCTAssertEqual(RimeKeyCapRole.wide.colour(in: palette).hex, palette.wideKeyCap.hex)
      XCTAssertEqual(RimeKeyCapRole.pressedLetter.colour(in: palette).hex, palette.pressedKeyCap.hex)
      XCTAssertEqual(RimeKeyCapRole.pressedWide.colour(in: palette).hex, palette.pressedWideKeyCap.hex)
      XCTAssertEqual(RimeKeyCapRole.actionEnabled.colour(in: palette).hex, palette.actionEnabled.hex)
      XCTAssertEqual(RimeKeyCapRole.actionDisabled.colour(in: palette).hex, palette.actionDisabled.hex)
      XCTAssertEqual(RimeKeyCapRole.plain.colour(in: palette).alpha, 0)
    }
  }

  func testAKeyPicksItsRoleFromItsWidthAndItsState() throws {
    let palette = RimeKeyboardPalette.dark
    let letter = RimeKeyboardKey(kind: .character("q"), frame: .zero, label: "q", accessibilityLabel: "q")
    let wide = RimeKeyboardKey(kind: .space, frame: .zero, label: "空格", accessibilityLabel: "空格")

    XCTAssertEqual(palette.capRole(isWide: false, isPressed: false), .letter)
    XCTAssertEqual(palette.capRole(isWide: true, isPressed: false), .wide)
    XCTAssertEqual(palette.capRole(isWide: false, isPressed: true), .pressedLetter)
    XCTAssertEqual(palette.capRole(isWide: true, isPressed: true), .pressedWide)
    XCTAssertEqual(palette.capFill(for: letter, isPressed: false).hex, palette.keyCap.hex)
    XCTAssertEqual(palette.capFill(for: wide, isPressed: false).hex, palette.wideKeyCap.hex)
    XCTAssertEqual(palette.capFill(for: wide, isPressed: true).hex, palette.pressedWideKeyCap.hex)
    XCTAssertEqual(palette.returnKeyFill(isEnabled: true).hex, palette.actionEnabled.hex)
    XCTAssertEqual(palette.returnKeyFill(isEnabled: false).hex, palette.actionDisabled.hex)
  }

  /// The kinds and the states the view has to feed the rule, and the answers it must get back: the space bar
  /// is a wide cap (measured: in dark mode wide keys are lighter than letter keys), the return key is the
  /// action colour in both of its states, and a character key is never wide.
  func testTheKindAndStatePickTheRoleTheMeasuredAppearanceExpects() throws {
    let dark = RimeKeyboardPalette.dark
    func key(_ kind: RimeKeyboardKey.Kind) -> RimeKeyboardKey {
      RimeKeyboardKey(kind: kind, frame: .zero, label: "k", accessibilityLabel: "k")
    }

    XCTAssertFalse(RimeKeyboardKey.Kind.character("q").isWideCap)
    XCTAssertTrue(RimeKeyboardKey.Kind.space.isWideCap)
    XCTAssertTrue(RimeKeyboardKey.Kind.returnKey.isWideCap)

    XCTAssertEqual(dark.capFill(for: key(.space), isPressed: false).hex, 0x444444,
                   "the space bar is a wide key: darker letter caps, lighter wide caps")
    XCTAssertEqual(dark.capFill(for: key(.character("q")), isPressed: false).hex, 0x3D3D3D)
    XCTAssertEqual(dark.capFill(for: key(.returnKey), isPressed: false).hex, 0x3378F4,
                   "an enabled action key is the measured blue, not a cap colour")
    XCTAssertEqual(dark.capFill(for: key(.returnKey), isPressed: false, isEnabled: false).hex, 0x737373)
    XCTAssertEqual(dark.capFill(for: key(.character("q")), isPressed: true).hex, 0x4E4E4E)
    XCTAssertEqual(dark.capFill(for: key(.space), isPressed: true).hex, 0x363636)
  }
}
