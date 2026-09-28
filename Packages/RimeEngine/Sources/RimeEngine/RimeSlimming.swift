import Foundation

// MARK: - Slate

/// S1 §12's "lite install": the catalog offers a slimmer profile that skips the embedding table,
/// because `cn_dicts/tencent.dict.yaml` alone is 16.5 MB of a 44 MB dictionary set and upstream warns
/// about its deploy time.
///
/// The transformation is deliberately text-level and then **verified by parsing**: Rime's
/// `import_tables` is a list of scalars, so the lines that reference a removed table can be dropped
/// exactly, and the result is re-read through librime's own parser before it is accepted. A
/// transformation that produced a config librime cannot load would be worse than the slower deploy it
/// avoids.
public struct RimeSlimmingResult: Sendable, Hashable {
  /// Files deleted from the source, relative to it.
  public let removedFiles: [String]
  /// Dictionary files whose `import_tables` was rewritten.
  public let rewrittenFiles: [String]
  /// Entries that were asked for and were not found, with the file that would have held them.
  public let missingTables: [String]

  public var summary: String {
    var parts = ["removed " + String(removedFiles.count) + " files",
                 "rewrote " + String(rewrittenFiles.count) + " dictionary imports"]
    if !missingTables.isEmpty { parts.append("missing: " + missingTables.joined(separator: ", ")) }
    return parts.joined(separator: "; ")
  }
}

public enum RimeSlimmingError: Error, CustomStringConvertible, Sendable {
  case tableNotFound(String)
  case verificationFailed(String, String)

  public var description: String {
    switch self {
    case .tableNotFound(let name):
      return "the profile has no table named '" + name + "' to remove"
    case .verificationFailed(let path, let reason):
      return "the rewritten dictionary '" + path + "' no longer parses: " + reason
    }
  }
}

public enum RimeProfileSlimming {
  /// Removes the named import tables from a profile's sources, in place.
  ///
  /// Call it on a **copy** in staging, before the profile is installed: the profile the user
  /// installed stays whole, and the slim one is what gets deployed.
  @discardableResult
  public static func removeImportTables(_ tables: [String],
                                        from source: URL,
                                        engine: RimeEngine,
                                        fileManager: FileManager = .default) throws -> RimeSlimmingResult {
    let wanted = Set(tables.map { normalise($0) })
    let scan = RimeFileScan.scan(root: source, fileManager: fileManager)
    var removed: [String] = []
    var rewritten: [String] = []
    var found = Set<String>()

    for path in scan.paths where path.hasSuffix(".dict.yaml") {
      let url = source.appendingPathComponent(path)
      guard let text = RimeFileScan.text(url) else { continue }
      guard text.contains("import_tables") else { continue }

      let (updated, hit) = strip(text: text, tables: wanted)
      let referenced = hit.intersection(wanted)
      guard !referenced.isEmpty else { continue }
      found.formUnion(referenced)

      // The rewrite is verified **before** it is written: a transformation that produced a config
      // librime cannot load would be worse than the slower deploy it avoids, and a rejected rewrite
      // must leave the file exactly as it was.
      let parsed: [String]
      do {
        parsed = try engine.configFromYAML(updated).value("import_tables")?.listValue?
          .compactMap { entry in
            switch entry {
            case .string(let value): return value
            case .map(let map): return map["table"]?.stringValue
            default: return nil
            }
          } ?? []
      } catch {
        throw RimeSlimmingError.verificationFailed(path, String(describing: error))
      }
      for table in parsed where wanted.contains(normalise(table)) {
        throw RimeSlimmingError.verificationFailed(path, "it still imports '" + table + "'")
      }

      try updated.write(to: url, atomically: true, encoding: .utf8)
      rewritten.append(path)
    }

    // The table files themselves, wherever they live.
    for path in scan.paths {
      let name = normalise(path)
      guard wanted.contains(name) else { continue }
      try fileManager.removeItem(at: source.appendingPathComponent(path))
      removed.append(path)
      found.insert(name)
    }

    let missing = Array(wanted.subtracting(found)).sorted()
    return RimeSlimmingResult(removedFiles: removed, rewrittenFiles: rewritten,
                              missingTables: missing)
  }

  /// Drops the list entries that name one of `tables`, keeping every other character of the file —
  /// including the comments a config author wrote about them.
  ///
  /// Returns the rewritten text and the table names it saw referenced.
  static func strip(text: String, tables: Set<String>) -> (String, Set<String>) {
    var output: [String] = []
    var referenced = Set<String>()
    var inImportTables = false

    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed == "import_tables:" {
        inImportTables = true
        output.append(String(line))
        continue
      }
      if inImportTables {
        if trimmed.hasPrefix("- ") {
          let value = normalise(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
          referenced.insert(value)
          if tables.contains(value) {
            // A removed entry takes its own line and nothing else: the list stays a list.
            continue
          }
          output.append(String(line))
          continue
        }
        if !trimmed.isEmpty, !trimmed.hasPrefix("#") {
          inImportTables = false
        }
      }
      output.append(String(line))
    }
    return (output.joined(separator: "\n"), referenced)
  }

  /// Rime writes import entries without the extension and without a leading `./`.
  static func normalise(_ value: String) -> String {
    var name = value
    if name.hasPrefix("./") { name.removeFirst(2) }
    if name.hasSuffix(".dict.yaml") { name.removeLast(".dict.yaml".count) }
    else if name.hasSuffix(".yaml") { name.removeLast(".yaml".count) }
    return name
  }
}
