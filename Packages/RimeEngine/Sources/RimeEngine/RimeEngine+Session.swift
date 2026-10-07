import Foundation
import Rime

/// The session-level surface S1's keyboard adoption, S2's configuration screens and S4's input
/// path are built on. Everything runs on the engine's serial queue, like the rest of the engine.
extension RimeEngine {
  // MARK: - State labels

  /// The schema's own word for a switch state, e.g. 中文 / 西文 for `ascii_mode`.
  /// S2 generates its switch list from this instead of hard-coding labels.
  public func stateLabel(option: String, state: Bool) throws -> String? {
    try perform {
      let api = try requireAPI()
      let session = try requireSession(api: api)
      guard let getLabel = api.pointee.get_state_label else { throw RimeEngineError.apiUnavailable }
      let box = CStringBox(option)
      guard let label = getLabel(session, box.raw, state) else { return nil }
      return String(cString: label)
    }
  }

  /// The compact form, which is what a key cap shows when the full label does not fit.
  public func abbreviatedStateLabel(option: String, state: Bool, abbreviated: Bool = true) throws -> String? {
    try perform {
      let api = try requireAPI()
      let session = try requireSession(api: api)
      guard let getLabel = api.pointee.get_state_label_abbreviated else { throw RimeEngineError.apiUnavailable }
      let box = CStringBox(option)
      let slice = getLabel(session, box.raw, state, abbreviated)
      guard let text = slice.str else { return nil }
      return String(decoding: UnsafeRawBufferPointer(start: text, count: slice.length), as: UTF8.self)
    }
  }

  /// True when the schema the session is on declares this switch.
  ///
  /// The keyboard asks this to decide whether its 中/英 key has anything to toggle: a schema with no
  /// `ascii_mode` switch has no 中英 state, and a key that pretends otherwise is a key that lies.
  public func schemaDeclaresSwitch(_ name: String) -> Bool {
    guard let schemaID = (try? currentSchema()) ?? nil else { return false }
    let switches = (try? withSchemaConfig(schemaID) { $0.value("switches") }?.listValue) ?? []
    return switches.contains { $0.mapValue?["name"]?.stringValue == name }
  }

  // MARK: - Raw input and caret

  /// The raw input, which is what the marked text must show: librime's own preedit inserts spaces
  /// between syllables (`ni hao`), and the system keyboard shows what the user typed.
  public func rawInput() throws -> String? {
    try perform {
      let api = try requireAPI()
      let session = try requireSession(api: api)
      guard let getInput = api.pointee.get_input else { throw RimeEngineError.apiUnavailable }
      guard let input = getInput(session) else { return nil }
      return String(cString: input)
    }
  }

  public func caretPosition() throws -> Int {
    try perform {
      let api = try requireAPI()
      let session = try requireSession(api: api)
      guard let getCaret = api.pointee.get_caret_pos else { throw RimeEngineError.apiUnavailable }
      return Int(getCaret(session))
    }
  }

  public func setCaretPosition(_ position: Int) throws {
    try perform {
      let api = try requireAPI()
      let session = try requireSession(api: api)
      guard let setCaret = api.pointee.set_caret_pos else { throw RimeEngineError.apiUnavailable }
      setCaret(session, position)
    }
  }

  // MARK: - Editing the composition

  /// Replaces the whole input. Used by tests and by S4's mid-composition cursor work.
  @discardableResult
  public func setInput(_ input: String) throws -> RimeOutput {
    try perform {
      let api = try requireAPI()
      let session = try requireSession(api: api)
      guard let setInput = api.pointee.set_input else { throw RimeEngineError.apiUnavailable }
      let box = CStringBox(input)
      _ = setInput(session, box.raw)
      return readOutput(api: api, session: session, handled: true)
    }
  }

  /// The return key's semantics when a composition is live: commit the whole thing.
  @discardableResult
  public func commitComposition() throws -> RimeOutput {
    try perform {
      let api = try requireAPI()
      let session = try requireSession(api: api)
      guard let commit = api.pointee.commit_composition else { throw RimeEngineError.apiUnavailable }
      _ = commit(session)
      return readOutput(api: api, session: session, handled: true)
    }
  }

  // MARK: - Candidates

  /// Selection by the label shown on the current page (digit or letter select keys).
  @discardableResult
  public func selectCandidateOnCurrentPage(at index: Int) throws -> RimeOutput {
    try perform {
      let api = try requireAPI()
      let session = try requireSession(api: api)
      guard let select = api.pointee.select_candidate_on_current_page else {
        throw RimeEngineError.apiUnavailable
      }
      _ = select(session, index)
      return readOutput(api: api, session: session, handled: true)
    }
  }

  /// Highlights without committing: the candidate bar's hover state.
  @discardableResult
  public func highlightCandidate(at index: Int) throws -> Bool {
    try perform {
      let api = try requireAPI()
      let session = try requireSession(api: api)
      guard let highlight = api.pointee.highlight_candidate else {
        throw RimeEngineError.apiUnavailable
      }
      return highlight(session, index)
    }
  }

  /// Forgets a candidate — the desktop Shift+Delete gesture. librime returns false when the
  /// candidate did not come from the user dictionary, and the UI must say so rather than pretend.
  @discardableResult
  public func deleteCandidate(at index: Int) throws -> Bool {
    try perform {
      let api = try requireAPI()
      let session = try requireSession(api: api)
      guard let delete = api.pointee.delete_candidate else { throw RimeEngineError.apiUnavailable }
      return delete(session, index)
    }
  }

  /// Deletes a candidate using the index shown in the current page's candidate bar.
  @discardableResult
  public func deleteCandidateOnCurrentPage(at index: Int) throws -> Bool {
    try perform {
      let api = try requireAPI()
      let session = try requireSession(api: api)
      guard let delete = api.pointee.delete_candidate_on_current_page else {
        throw RimeEngineError.apiUnavailable
      }
      return delete(session, index)
    }
  }

  /// The whole candidate list, not just the current page. S3's expanded panel is a grid over it.
  public func candidateList(shouldContinue: () -> Bool = { true }) throws -> [RimeCandidateItem] {
    try perform {
      let api = try requireAPI()
      let session = try requireSession(api: api)
      guard let begin = api.pointee.candidate_list_begin,
            let next = api.pointee.candidate_list_next,
            let end = api.pointee.candidate_list_end else {
        throw RimeEngineError.apiUnavailable
      }
      var iterator = RimeCandidateListIterator()
      guard begin(session, &iterator) else { return [] }
      defer { end(&iterator) }
      var items: [RimeCandidateItem] = []
      while shouldContinue() && next(&iterator) {
        let candidate = iterator.candidate
        items.append(RimeCandidateItem(text: candidate.text.map { String(cString: $0) } ?? "",
                                       comment: candidate.comment.map { String(cString: $0) }))
      }
      return items
    }
  }

  // MARK: - Diagnostics

  /// What the resolved directories are, as one line. The tracer's rule is that a failure on a
  /// device has to be readable from the device.
  public var directorySummary: String {
    let directories = self.directories
    return "shared=" + directories.sharedDataDir
      + " prebuilt=" + directories.prebuiltDataDir
      + " user=" + directories.userDataDir
      + " root=" + directories.writableRoot.rawValue
  }
}
