import Foundation

// Value types handed to the UI. They are deliberately distinct from the C structs with the
// same meaning (RimeCandidate, RimeComposition, RimeStatus) so that neither shadows the other.

public struct RimeCandidateItem: Sendable, Hashable {
  public let text: String
  public let comment: String?

  public init(text: String, comment: String? = nil) {
    self.text = text
    self.comment = comment
  }
}

public struct RimePage: Sendable, Hashable {
  public let candidates: [RimeCandidateItem]
  public let highlightedIndex: Int
  public let pageNumber: Int
  public let pageSize: Int
  public let isLastPage: Bool
  public let selectLabels: [String]

  public init(candidates: [RimeCandidateItem], highlightedIndex: Int, pageNumber: Int,
              pageSize: Int, isLastPage: Bool, selectLabels: [String]) {
    self.candidates = candidates
    self.highlightedIndex = highlightedIndex
    self.pageNumber = pageNumber
    self.pageSize = pageSize
    self.isLastPage = isLastPage
    self.selectLabels = selectLabels
  }
}

public struct RimeCompositionInfo: Sendable, Hashable {
  public let preedit: String?
  public let cursorPosition: Int
  public let selectionStart: Int
  public let selectionEnd: Int

  public init(preedit: String?, cursorPosition: Int, selectionStart: Int, selectionEnd: Int) {
    self.preedit = preedit
    self.cursorPosition = cursorPosition
    self.selectionStart = selectionStart
    self.selectionEnd = selectionEnd
  }
}

public struct RimeStatusSnapshot: Sendable, Hashable {
  public let schemaID: String?
  public let schemaName: String?
  public let isDisabled: Bool
  public let isComposing: Bool
  public let isAsciiMode: Bool
  public let isFullShape: Bool
  public let isSimplified: Bool
  public let isTraditional: Bool
  public let isAsciiPunctuation: Bool

  public init(schemaID: String?, schemaName: String?, isDisabled: Bool, isComposing: Bool,
              isAsciiMode: Bool, isFullShape: Bool, isSimplified: Bool, isTraditional: Bool,
              isAsciiPunctuation: Bool) {
    self.schemaID = schemaID
    self.schemaName = schemaName
    self.isDisabled = isDisabled
    self.isComposing = isComposing
    self.isAsciiMode = isAsciiMode
    self.isFullShape = isFullShape
    self.isSimplified = isSimplified
    self.isTraditional = isTraditional
    self.isAsciiPunctuation = isAsciiPunctuation
  }
}

/// Everything the keyboard needs after one input event.
public struct RimeOutput: Sendable {
  /// librime consumed the key. When false the keyboard should treat it as plain text input.
  public let handled: Bool
  /// Text that must be inserted into the client, if any.
  public let commit: String?
  public let composition: RimeCompositionInfo?
  public let page: RimePage?
  public let status: RimeStatusSnapshot?
  /// What the user typed, without the spaces librime's preedit inserts between syllables.
  public let input: String?

  public init(handled: Bool, commit: String?, composition: RimeCompositionInfo?,
              page: RimePage?, status: RimeStatusSnapshot?, input: String? = nil) {
    self.handled = handled
    self.commit = commit
    self.composition = composition
    self.page = page
    self.status = status
    self.input = input
  }

  public var preedit: String? { composition?.preedit }
  public var candidates: [RimeCandidateItem] { page?.candidates ?? [] }
  public var isComposing: Bool { !(preedit ?? "").isEmpty }

  /// True when librime declined the key and nothing is composing, which is when the keyboard has to produce
  /// the literal character itself (S4-AC4: a key librime declines never means "nothing happened").
  ///
  /// One predicate, because the extension had this expression three times — a character key, an action key
  /// with a fallback, and the error path — and it is the rule, not the expression, that keeps a key from
  /// doing nothing at all.
  public var needsLiteralFallback: Bool {
    !handled && (commit ?? "").isEmpty && !isComposing
  }

  /// The composition divided into syllables — what the expanded panel's syllable row shows — or nil when
  /// there is nothing to divide.
  ///
  /// Measured: librime's preedit *is* the division, "nihao" coming back as "ni hao" and "nihaoshijie" as
  /// "ni hao shi jie", which is the only segmentation this build exposes and the one S4 §6 asks about.
  /// The guard is what makes reading it that way safe: the parts have to join back into exactly what the
  /// user typed, so a translator whose preedit is a hint or a sentence cannot be mistaken for syllables.
  public var syllables: [String]? {
    guard let preedit = composition?.preedit, let input, !input.isEmpty else { return nil }
    let parts = preedit.split(separator: " ").map(String.init)
    guard parts.count > 1, parts.joined() == input else { return nil }
    return parts
  }
}
