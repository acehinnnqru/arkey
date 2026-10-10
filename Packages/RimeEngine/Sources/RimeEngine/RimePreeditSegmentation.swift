import Foundation

/// Maps the engine's displayed syllables back to the original keys. Formatting is presentation only:
/// callers keep the engine's input and commit untouched. Never infer boundaries from key count alone.
enum RimePreeditSegmentation {
  static func syllables(input: String, preedit: String, schemaID: String?) -> [String]? {
    guard let parts = alignedParts(input: input, preedit: preedit, schemaID: schemaID),
          parts.count > 1 else { return nil }
    return parts
  }

  /// Also accepts one syllable, which is needed after earlier syllables have been selected.
  static func alignedParts(input: String, preedit: String, schemaID: String?) -> [String]? {
    let parts = preedit.split(separator: " ").map(String.init)
    guard !parts.isEmpty, !input.isEmpty else { return nil }
    if parts.joined() == input { return parts }
    guard ["pinyin_flypy", "double_pinyin_flypy"].contains(schemaID ?? ""),
          input.utf8.allSatisfy({ (97...122).contains($0) }) else { return nil }

    // A syllable can be abbreviated, and zero-initial syllables can have multiple spellings.
    // Keep only a unique alignment with the actual keys; ambiguous or customized formats fall back.
    var paths: [Int: [[String]]] = [0: [[]]]
    let keys = Array(input)
    for part in parts {
      let spellings = flypySpellings(for: part)
      guard !spellings.isEmpty else { return nil }
      var next: [Int: [[String]]] = [:]
      for (offset, prefixes) in paths {
        for spelling in spellings {
          let end = offset + spelling.count
          guard end <= keys.count, String(keys[offset..<end]) == spelling else { continue }
          // Two paths suffice to mark an ambiguous alignment without exponential growth.
          for prefix in prefixes where (next[end]?.count ?? 0) < 2 {
            next[end, default: []].append(prefix + [spelling])
          }
        }
      }
      paths = next
      if paths.isEmpty { return nil }
    }
    guard let matches = paths[keys.count], matches.count == 1 else { return nil }
    return matches[0]
  }

  /// Flypy's initial/final key layout. Only used to validate the boundaries already supplied by Rime.
  /// The schema remains responsible for deciding which syllables and candidates the input represents.
  private static func flypySpellings(for displayed: String) -> Set<String> {
    let syllable = displayed.replacingOccurrences(of: "ü", with: "v")
    guard !syllable.isEmpty, syllable.utf8.allSatisfy({ (97...122).contains($0) }) else { return [] }
    var result: Set<String> = []
    if syllable.count <= 2 { result.insert(syllable) }

    if ["a", "e", "o"].contains(syllable) {
      result.insert(syllable + syllable)
      return result
    }

    let initial: String
    let final: String
    if let digraph = ["zh", "ch", "sh"].first(where: { syllable.hasPrefix($0) }) {
      initial = ["zh": "v", "ch": "i", "sh": "u"][digraph]!
      final = String(syllable.dropFirst(2))
    } else {
      initial = String(syllable.prefix(1))
      final = "aeo".contains(initial) ? syllable : String(syllable.dropFirst())
    }
    guard !final.isEmpty else {
      result.insert(initial)
      return result
    }
    guard let finalKey = finals[final] else { return result }
    result.insert(initial + finalKey)
    // Rime may expand a one-key abbreviation in its preedit.
    result.insert(initial)
    if "jqxy".contains(initial), final == "u" { result.insert(initial + "v") }
    return result
  }

  private static let finals = [
    "a": "a", "o": "o", "e": "e", "i": "i", "u": "u", "v": "v",
    "iu": "q", "ei": "w", "uan": "r", "ue": "t", "ve": "t", "un": "y",
    "uo": "o", "ie": "p", "ong": "s", "iong": "s", "ing": "k", "uai": "k",
    "ai": "d", "en": "f", "eng": "g", "iang": "l", "uang": "l", "ang": "h",
    "ian": "m", "an": "j", "ou": "z", "ia": "x", "ua": "x", "iao": "n",
    "ao": "c", "ui": "v", "in": "b",
  ]
}
