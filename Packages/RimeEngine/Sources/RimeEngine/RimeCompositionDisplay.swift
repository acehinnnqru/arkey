import Foundation

/// Keeps raw spelling boundaries across partial selections, on the engine queue. Rime's preedit
/// reports a converted prefix in UTF-8 bytes, while its input still includes the keys for that prefix.
/// Previous validated boundaries prevent a remaining `a` from being guessed as either `a` or `aa`.
struct RimeCompositionDisplay {
  private var previousInput = ""
  private var previousSchemaID: String?
  private var previousPrefix = ""
  private var previousInputStart: Int?
  private var boundaries: [Int] = []

  mutating func text(input: String?, composition: RimeCompositionInfo?, schemaID: String?) -> String? {
    guard let input, !input.isEmpty, let composition, let preedit = composition.preedit,
          !preedit.isEmpty else {
      self = Self()
      return nil
    }
    let bytes = Array(preedit.utf8)
    let split = composition.selectionStart
    guard (0...bytes.count).contains(split),
          let prefix = String(bytes: bytes[..<split], encoding: .utf8),
          let remaining = String(bytes: bytes[split...], encoding: .utf8) else {
      self = Self()
      return preedit
    }

    let sameSchema = schemaID == previousSchemaID
    let sameInput = sameSchema && input == previousInput
    let start: Int?
    if prefix.isEmpty {
      start = 0
    } else if sameSchema, prefix == previousPrefix, let previousInputStart,
              input.count >= previousInputStart,
              input.prefix(previousInputStart) == previousInput.prefix(previousInputStart) {
      // Typing or deleting within the remaining composition leaves the selected prefix intact.
      start = previousInputStart
    } else if sameInput {
      let matches = boundaries.filter { offset in
        guard offset > 0, offset < input.count else { return false }
        return RimePreeditSegmentation.alignedParts(input: String(input.dropFirst(offset)),
                                                   preedit: remaining, schemaID: schemaID) != nil
      }
      start = matches.count == 1 ? matches[0] : nil
    } else {
      start = nil
    }

    let suffix = start.map { String(input.dropFirst($0)) }
    let parts = suffix.flatMap {
      RimePreeditSegmentation.alignedParts(input: $0, preedit: remaining, schemaID: schemaID)
    }
    if let start {
      let retained = sameSchema && input.prefix(start) == previousInput.prefix(start)
        ? boundaries.filter { $0 <= start } : []
      boundaries = retained
      if !boundaries.contains(start) { boundaries.append(start) }
      var offset = start
      for part in parts ?? [] {
        offset += part.count
        boundaries.append(offset)
      }
    } else if !sameInput {
      boundaries = []
    }
    previousInput = input
    previousSchemaID = schemaID
    previousPrefix = prefix
    previousInputStart = start

    // When alignment is unavailable, keep Rime's selected text visible instead of replacing it
    // with the original keys. No display text is ever sent back to the engine or committed here.
    let tail = parts?.joined(separator: " ") ?? suffix ?? remaining
    return prefix.isEmpty ? tail : prefix + (tail.isEmpty ? "" : " " + tail)
  }
}
