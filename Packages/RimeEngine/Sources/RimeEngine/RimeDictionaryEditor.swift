import Foundation

// MARK: - Editing entries

/// S5-AC5 asks that a user can add an entry and forgive one. librime's levers API has no
/// per-entry writer — only export, import, backup and restore — so both operations are the same
/// machinery: export the dictionary, change the list, import it back.
///
/// Two properties make that safe rather than clever. The export is the *levers* format, which is ours
/// to rewrite and which Squirrel never reads, so a round trip cannot disturb the sync snapshot. And
/// every call goes through `RimeDictionaryAccess`, so it refuses while the keyboard holds the
/// dictionaries and closes the app's own session for the duration — the two preconditions measured in
/// S5 §3.2.
public struct RimeDictionaryEditor {
  public let workspace: RimeWorkspace
  public let engine: RimeEngine
  private let fileManager: FileManager

  private let leaseStore: RimeLeaseStore?

  public init(workspace: RimeWorkspace, engine: RimeEngine, leaseStore: RimeLeaseStore? = nil,
              fileManager: FileManager = .default) {
    self.workspace = workspace
    self.engine = engine
    self.leaseStore = leaseStore
    self.fileManager = fileManager
  }

  /// Rewrites one dictionary through the levers format. Returns the number of entries the dictionary
  /// has afterwards — not librime's import count, which is the number it *newly added* and is
  /// therefore zero whenever the entries were already there (measured: re-importing the same list
  /// reports 0).
  @discardableResult
  public func edit(_ name: String,
                   _ transform: (inout [RimeUserDictionaryExport.Entry]) -> Void) throws -> Int {
    // A dictionary nothing has ever been committed to has no database to export: librime creates it
    // on the first commit, and the levers API cannot create one. Saying so is better than a generic
    // export failure the user cannot act on.
    let database = workspace.userData.appendingPathComponent(name + ".userdb", isDirectory: true)
    guard fileManager.fileExists(atPath: database.path) else {
      throw RimeUserDictionaryError.noUserDictionary(name)
    }

    let access = RimeDictionaryAccess(workspace: workspace, engine: engine, leaseStore: leaseStore)
    if let holder = access.blocker() {
      throw RimeSyncError.refused(RimeDictionaryAccessError
        .keyboardIsUsingIt(pid: holder.pid, since: holder.openedAt).description)
    }
    let directory = workspace.staging.appendingPathComponent("dictionary-edit", isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: directory) }
    let url = directory.appendingPathComponent(name + ".export.txt")

    return try access.perform {
      let count = try engine.exportUserDictionary(name, to: url)
      guard let text = try? String(contentsOf: url, encoding: .utf8),
            var export = RimeUserDictionaryExport.parse(text: text) else {
        throw RimeSyncError.notASnapshot(url.path)
      }
      var entries = export.entries
      transform(&entries)
      if entries == export.entries {
        return count
      }
      export = RimeUserDictionaryExport(entries: entries)
      try export.serialize().write(to: url, atomically: true, encoding: .utf8)
      _ = try engine.importUserDictionary(name, from: url)
      return entries.count
    }
  }

  /// A per-word "forget" would go here, and it is deliberately absent: see the measurement below
  /// `removeDictionary`. `delete_candidate` is the only per-word deletion this build has, and after it
  /// `export_user_dict` fails in the same process — so the app cannot both delete a word and confirm it.
  /// The keyboard's long press (S4 §8) does the deletion and has nothing to verify.

  /// Removes the whole dictionary.
  ///
  /// The heavier deletion, for "reset the user dictionary" rather than "forget this word": the leveldb
  /// directory goes, and the next commit creates a new one. `forget(_:text:code:schemaID:)` is the
  /// per-entry door, and `edit` is the one that cannot delete (`import_user_dict` is additive).
  @discardableResult
  public func removeDictionary(_ name: String) throws -> Bool {
    let access = RimeDictionaryAccess(workspace: workspace, engine: engine, leaseStore: leaseStore)
    if let holder = access.blocker() {
      throw RimeSyncError.refused(RimeDictionaryAccessError
        .keyboardIsUsingIt(pid: holder.pid, since: holder.openedAt).description)
    }
    let database = workspace.userData.appendingPathComponent(name + ".userdb", isDirectory: true)
    guard fileManager.fileExists(atPath: database.path) else { return false }
    try fileManager.removeItem(at: database)
    return true
  }

  /// Adds an entry with the weight the user asked for, or replaces the weight of one that is there.
  @discardableResult
  public func add(_ name: String, text: String, code: String, weight: Int = 1) throws -> Int {
    try edit(name) { entries in
      if let index = entries.firstIndex(where: { $0.text == text && $0.code == code }) {
        entries[index] = RimeUserDictionaryExport.Entry(text: text, code: code, weight: weight)
      } else {
        entries.append(RimeUserDictionaryExport.Entry(text: text, code: code, weight: weight))
      }
    }
  }
}
