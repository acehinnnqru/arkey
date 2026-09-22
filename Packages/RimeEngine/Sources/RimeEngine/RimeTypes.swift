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

  public init(handled: Bool, commit: String?, composition: RimeCompositionInfo?,
              page: RimePage?, status: RimeStatusSnapshot?) {
    self.handled = handled
    self.commit = commit
    self.composition = composition
    self.page = page
    self.status = status
  }

  public var preedit: String? { composition?.preedit }
  public var candidates: [RimeCandidateItem] { page?.candidates ?? [] }
  public var isComposing: Bool { !(preedit ?? "").isEmpty }
}
