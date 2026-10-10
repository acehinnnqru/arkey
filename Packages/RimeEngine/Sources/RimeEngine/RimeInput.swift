import Foundation

// MARK: - Intents and effects

/// What a key press means, after the keyboard's own layout has decided. Deliberately not a keysym:
/// S4's rules are about intent (this is a space, this is the return key, this selects a candidate),
/// and keeping the decision here is what makes the table testable off the device.
public enum RimeInputIntent: Sendable, Hashable {
  /// A character key: the ASCII code point the layout produced.
  case character(UInt16)
  case space
  case returnKey
  case backspace
  case escape
  /// A candidate tap, or a digit/letter select key: both mean "select this candidate".
  case selectCandidate(Int)
  case pageBackward
  case pageForward
  /// A schema switch key: flips a runtime option such as ascii_mode.
  case toggleOption(String)
}

public enum RimeInputEffect: Sendable, Hashable {
  case none
  /// The composition changed; the marked text is what to show.
  case composing
  case committed(String)
  /// librime declined the key and nothing was composing, so the character is typed literally.
  case literal(String)
  case cleared
  case paged
}

public struct RimeInputOutcome: Sendable {
  public let effect: RimeInputEffect
  /// The text to hand to the client. Nil means "insert nothing".
  public let insertText: String?
  /// What the marked text should be. Nil means "clear the marked text".
  public let markedText: String?
  public let page: RimePage?
  public let status: RimeStatusSnapshot?
  /// The client must delete one character backwards: the backspace librime cannot act on.
  public let deleteBackward: Bool

  public var isComposing: Bool { !(markedText ?? "").isEmpty }

  init(effect: RimeInputEffect, insertText: String? = nil, markedText: String? = nil,
       page: RimePage? = nil, status: RimeStatusSnapshot? = nil, deleteBackward: Bool = false) {
    self.effect = effect
    self.insertText = insertText
    self.markedText = markedText
    self.page = page
    self.status = status
    self.deleteBackward = deleteBackward
  }
}

// MARK: - The driver

/// S4's input contract, in one place.
///
/// The keyboard controller holds one of these instead of calling the engine directly, so the commit
/// table is implemented once and tested against fixtures rather than re-derived per view. Every rule
/// below is a row of that table; the ones marked "measured" came from the pinned build and are
/// covered by `S4InputTests`.
public final class RimeInputDriver {
  private let engine: RimeEngine
  private var lastOutput: RimeOutput?

  public init(engine: RimeEngine) {
    self.engine = engine
  }

  /// The raw input, which is what the marked text shows: librime's own preedit inserts spaces
  /// between syllables (`ni hao`) and the system keyboard shows what the user typed (`nihao`).
  public var rawInput: String? {
    guard let value = try? engine.rawInput(), !value.isEmpty else { return nil }
    return value
  }

  public var isComposing: Bool { rawInput != nil }

  /// Re-reads the engine without processing a key, for the first render of an appearance.
  @discardableResult
  public func refresh() throws -> RimeInputOutcome {
    let output = try engine.refresh()
    lastOutput = output
    return makeOutcome(from: output, effect: output.isComposing ? .composing : .none)
  }

  public func handle(_ intent: RimeInputIntent) throws -> RimeInputOutcome {
    switch intent {
    case .character(let code):
      return try handleCharacter(code)

    case .space:
      // Space is the primary commit path. With no composition it is just a space.
      guard isComposing else {
        return RimeInputOutcome(effect: .literal(" "), insertText: " ",
                                markedText: lastOutput?.preedit == nil ? nil : rawInput)
      }
      let output = try engine.processKey(RimeKey.space)
      lastOutput = output
      if let commit = output.commit, !commit.isEmpty {
        return makeOutcome(from: output, effect: .committed(commit))
      }
      // Measured: an input with no dictionary entry commits the raw letters, and librime returns
      // them as the commit. A schema that declines the space entirely leaves the composition alone,
      // and the keyboard must not pretend something happened.
      return makeOutcome(from: output, effect: .composing)

    case .returnKey:
      guard isComposing else {
        return RimeInputOutcome(effect: .none, markedText: nil)
      }
      // Let the schema handle Return, which commits raw input rather than selecting a candidate.
      let output = try engine.processKey(RimeKey.returnKey)
      lastOutput = output
      if let commit = output.commit, !commit.isEmpty {
        return makeOutcome(from: output, effect: .committed(commit))
      }
      return makeOutcome(from: output, effect: output.isComposing ? .composing : .cleared)

    case .backspace:
      let output = try engine.processKey(RimeKey.backSpace)
      lastOutput = output
      if let commit = output.commit, !commit.isEmpty {
        return makeOutcome(from: output, effect: .committed(commit))
      }
      // Measured: at the start of a composition librime declines the key, which is the signal to
      // delete backwards in the client instead. Anything else would be a backspace that does nothing.
      if !output.handled, !output.isComposing {
        return RimeInputOutcome(effect: .literal(""), deleteBackward: true)
      }
      return makeOutcome(from: output, effect: output.isComposing ? .composing : .none)

    case .escape:
      try engine.clearComposition()
      let output = try engine.refresh()
      lastOutput = output
      return RimeInputOutcome(effect: .cleared, markedText: nil, page: output.page,
                              status: output.status)

    case .selectCandidate(let index):
      let output = try engine.selectCandidate(at: index)
      lastOutput = output
      if let commit = output.commit, !commit.isEmpty {
        return makeOutcome(from: output, effect: .committed(commit))
      }
      return makeOutcome(from: output, effect: output.isComposing ? .composing : .none)

    case .pageBackward:
      let output = try engine.changePage(backward: true)
      lastOutput = output
      return makeOutcome(from: output, effect: .paged)

    case .pageForward:
      let output = try engine.changePage(backward: false)
      lastOutput = output
      return makeOutcome(from: output, effect: .paged)

    case .toggleOption(let name):
      let current = (try? engine.getOption(name)) ?? false
      try engine.setOption(name, !current)
      let output = try engine.refresh()
      lastOutput = output
      return makeOutcome(from: output, effect: .composing)
    }
  }

  private func handleCharacter(_ code: UInt16) throws -> RimeInputOutcome {
    // S4 §4.1's select-key row: while composing, a key whose label a candidate carries selects that candidate.
    // Measured in round 172: librime's own selector does not do it for us — with menu/select_keys and
    // menu/alternative_select_labels both set, a label press still arrives here unhandled — so the label is
    // matched against the page the bar is showing and routed to the API that selects on the page.
    if isComposing, let index = selectIndex(for: code) {
      // Measured (round 172): librime's page-scoped select returned no commit here at all — the outcome stayed
      // composing and the preedit stayed on screen — while the API the bar's taps use commits the same
      // candidate. The behaviour the row asks for is the selection, so the taps' API is what this uses.
      let output = try engine.selectCandidate(at: index)
      lastOutput = output
      if let commit = output.commit, !commit.isEmpty {
        return makeOutcome(from: output, effect: .committed(commit))
      }
      return makeOutcome(from: output, effect: .composing)
    }

    let output = try engine.processKey(Int32(code))
    lastOutput = output
    if let commit = output.commit, !commit.isEmpty {
      return makeOutcome(from: output, effect: .committed(commit))
    }
    if output.handled || output.isComposing {
      return makeOutcome(from: output, effect: .composing)
    }
    // Measured, and the tracer lost a device run to this: a schema with no punctuator declines
    // ".", and a controller that ignores refusals types nothing at all. The literal character is
    // the fallback, and it is what makes every key have a defined outcome.
    let literal = Self.literal(for: code)
    guard let literal else {
      return makeOutcome(from: output, effect: .none)
    }
    return RimeInputOutcome(effect: .literal(literal), insertText: literal,
                            markedText: rawInput, page: output.page, status: output.status)
  }

  /// Which candidate the key selects, if it is a select key: the labels on the page are what the bar draws, so
  /// a key that matches one of them is the key for that candidate.
  private func selectIndex(for code: UInt16) -> Int? {
    guard let literal = Self.literal(for: code) else { return nil }
    // The page the bar is showing: the last one any call reported, because a key press that only composes does
    // not have to carry one for the labels to be current.
    guard let page = lastPage ?? lastOutput?.page else { return nil }
    return page.selectIndex(matching: literal)
  }

  /// The most recent page seen, kept beside the last output so a select key can be matched even when the
  /// keystroke before it reported no page of its own.
  private var lastPage: RimePage?

  private func makeOutcome(from output: RimeOutput, effect: RimeInputEffect) -> RimeInputOutcome {
    if let page = output.page { lastPage = page }
    return RimeInputOutcome(effect: effect,
                     insertText: output.commit,
                     markedText: rawInput,
                     page: output.page,
                     status: output.status)
  }

  /// The literal text for a key code: printable ASCII only, and never a control character.
  static func literal(for code: UInt16) -> String? {
    guard code >= 0x20, code < 0x7F, let scalar = UnicodeScalar(UInt32(code)) else { return nil }
    return String(Character(scalar))
  }
}
