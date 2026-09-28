import Foundation
import Rime

// MARK: - The levers module

/// librime's levers API: the schema list and, more importantly for S5, user-dictionary export,
/// import, backup and enumeration.
///
/// It is a module API rather than part of `rime_api_t`, so it is fetched once from
/// `RimeFindModule("levers")` and every call checks availability before use.
public enum RimeLevers {
  public static var pointer: UnsafeMutablePointer<RimeLeversApi>? {
    guard let module = RimeFindModule("levers"), let getAPI = module.pointee.get_api,
          let custom = getAPI() else { return nil }
    return UnsafeMutableRawPointer(custom).assumingMemoryBound(to: RimeLeversApi.self)
  }

  public static var isAvailable: Bool { pointer != nil }
}

public enum RimeUserDictionaryError: Error, CustomStringConvertible, Sendable {
  case leversUnavailable
  case engineNotStarted
  case operationFailed(String, String)
  case keyboardHoldsTheLease(pid: Int32)
  case fileMissing(String)
  /// The dictionary has no user database yet: nothing has ever been committed, so there is nothing to
  /// export, change and import back. librime creates the database on the first commit, and only then.
  case noUserDictionary(String)

  public var description: String {
    switch self {
    case .leversUnavailable:
      return "the levers module is not available in this librime build"
    case .engineNotStarted:
      return "librime is not initialised, so it has no user directory to work in"
    case .operationFailed(let operation, let name):
      return operation + " failed for '" + name + "'"
    case .keyboardHoldsTheLease(let pid):
      return "the keyboard is using the user dictionary (pid " + String(pid)
        + "); close it and try again"
    case .fileMissing(let path):
      return "the file does not exist: " + path
    case .noUserDictionary(let name):
      return "'" + name + "' has no user dictionary yet: type a few words first, or import a snapshot"
    }
  }
}

// MARK: - Engine surface

extension RimeEngine {
  /// The dictionary names librime has a user dictionary for. This is the list S5 shows, and it is
  /// keyed by dictionary name rather than by profile — which is what makes learning survive a
  /// profile switch.
  public func userDictionaryNames() throws -> [String] {
    try perform {
      guard isStarted else { throw RimeUserDictionaryError.engineNotStarted }
      guard let levers = RimeLevers.pointer,
            let initialize = levers.pointee.user_dict_iterator_init,
            let next = levers.pointee.next_user_dict,
            let destroy = levers.pointee.user_dict_iterator_destroy else {
        throw RimeUserDictionaryError.leversUnavailable
      }
      var iterator = RimeUserDictIterator()
      guard initialize(&iterator) else { return [] }
      defer { destroy(&iterator) }
      var names: [String] = []
      while let name = next(&iterator) {
        names.append(String(cString: name))
      }
      return names
    }
  }

  /// librime's own snapshot of one dictionary into the sync directory. Part of the sync task, but
  /// usable on its own when the user asks for a backup.
  @discardableResult
  public func backupUserDictionary(_ name: String) throws -> Bool {
    try perform {
      guard isStarted else { throw RimeUserDictionaryError.engineNotStarted }
      guard let levers = RimeLevers.pointer, let backup = levers.pointee.backup_user_dict else {
        throw RimeUserDictionaryError.leversUnavailable
      }
      let box = CStringBox(name)
      return backup(box.raw)
    }
  }

  /// Writes the levers text export — a different shape from the sync snapshot, for our own
  /// file import/export UI. Returns the number of entries written, or throws.
  @discardableResult
  public func exportUserDictionary(_ name: String, to url: URL) throws -> Int {
    try perform {
      guard isStarted else { throw RimeUserDictionaryError.engineNotStarted }
      guard let levers = RimeLevers.pointer, let export = levers.pointee.export_user_dict else {
        throw RimeUserDictionaryError.leversUnavailable
      }
      let nameBox = CStringBox(name)
      let pathBox = CStringBox(url.path)
      let count = Int(export(nameBox.raw, pathBox.raw))
      guard count > 0 else { throw RimeUserDictionaryError.operationFailed("export_user_dict", name) }
      return count
    }
  }

  /// The reverse: the levers export format back into a dictionary.
  @discardableResult
  public func importUserDictionary(_ name: String, from url: URL) throws -> Int {
    try perform {
      guard isStarted else { throw RimeUserDictionaryError.engineNotStarted }
      guard let levers = RimeLevers.pointer, let importEntries = levers.pointee.import_user_dict else {
        throw RimeUserDictionaryError.leversUnavailable
      }
      let nameBox = CStringBox(name)
      let pathBox = CStringBox(url.path)
      // Zero is a legitimate answer: forgiving the last entry leaves a file with none, and librime
      // reports zero entries imported. Only a missing file is a failure, and that is checked here.
      guard FileManager.default.fileExists(atPath: url.path) else {
        throw RimeUserDictionaryError.fileMissing(url.path)
      }
      return Int(importEntries(nameBox.raw, pathBox.raw))
    }
  }

  /// Squirrel's 同步用户数据 menu, in one call: it schedules Rime's own tasks and starts
  /// maintenance. Asynchronous — the files are on disk only after the deploy notification.
  @discardableResult
  public func syncUserData() throws -> Bool {
    try perform {
      guard isStarted else { throw RimeUserDictionaryError.engineNotStarted }
      let api = try requireAPI()
      guard let sync = api.pointee.sync_user_data else { throw RimeEngineError.apiUnavailable }
      return sync()
    }
  }

  /// `<sync_dir>/<installation_id>`, which is where this device writes its snapshots.
  public func userDataSyncDirectory() -> String? {
    perform {
      guard let api = RimeAPI.pointer, let get = api.pointee.get_user_data_sync_dir else { return nil }
      var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
      get(&buffer, buffer.count)
      let value = String(cString: buffer)
      return value.isEmpty ? nil : value
    }
  }

  /// librime's own user id, which the snapshots carry as `#@/user_id`.
  public func userID() -> String? {
    perform {
      guard let api = RimeAPI.pointer, let get = api.pointee.get_user_id else { return nil }
      guard let value = get() else { return nil }
      return String(cString: value)
    }
  }

  /// Forgets the notifications collected so far, so a caller can wait for the next deploy event.
  public func clearNotifications() {
    notificationRelay.removeAll()
  }
}

// MARK: - The two text formats

/// The sync snapshot Squirrel's folder holds: `<sync_dir>/<installation_id>/<dict>.userdb.txt`.
///
/// Measured against the pinned build: a `# Rime user dictionary` header, `#@/key value` metadata, then
/// `<code>\t<text>\tc=<commits> d=<deletions> t=<tick>` rows. It is **not** the same shape as the
/// levers export, which is why the two have different types here.
public struct RimeUserDictionarySnapshot: Sendable {
  public struct Entry: Sendable, Hashable {
    public let code: String
    public let text: String
    public let commits: Int
    public let deletions: Int
    public let tick: Int
  }

  public let dictionary: String?
  public let databaseType: String?
  public let rimeVersion: String?
  public let tick: Int?
  public let userID: String?
  public let entries: [Entry]

  public init(dictionary: String?, databaseType: String?, rimeVersion: String?, tick: Int?,
              userID: String?, entries: [Entry]) {
    self.dictionary = dictionary
    self.databaseType = databaseType
    self.rimeVersion = rimeVersion
    self.tick = tick
    self.userID = userID
    self.entries = entries
  }

  /// Parses the file. Nil when the header is not the sync snapshot's, which is how a levers export
  /// dropped into the folder is refused instead of half-read.
  public static func parse(text: String, dictionaryName: String? = nil) -> RimeUserDictionarySnapshot? {
    var dictionary = dictionaryName
    var databaseType: String?
    var rimeVersion: String?
    var tick: Int?
    var userID: String?
    var entries: [Entry] = []
    var sawHeader = false

    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      if line == "# Rime user dictionary" || line == "# Rime user dictionary\r" {
        sawHeader = true
        continue
      }
      if line.hasPrefix("#@/") {
        // librime writes these as "#@/db_name\ttracer"; the spec's prose shows a space. Both work.
        let body = line.dropFirst(3)
        guard let separator = body.firstIndex(where: { $0 == "\t" || $0 == " " }) else { continue }
        let key = String(body[..<separator])
        let value = String(body[body.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        switch key {
        case "db_name": dictionary = value
        case "db_type": databaseType = value
        case "rime_version": rimeVersion = value
        case "tick": tick = Int(value)
        case "user_id": userID = value
        default: break
        }
        continue
      }
      if line.hasPrefix("#") || line.isEmpty { continue }

      let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
      guard fields.count >= 2 else { continue }
      let code = String(fields[0])
      let text = String(fields[1])
      var commits = 0
      var deletions = 0
      var entryTick = 0
      if fields.count >= 3 {
        for token in fields[2].split(separator: " ") {
          let pair = token.split(separator: "=", maxSplits: 1)
          guard pair.count == 2 else { continue }
          let value = Int(pair[1]) ?? 0
          switch pair[0] {
          case "c": commits = value
          case "d": deletions = value
          case "t": entryTick = value
          default: break
          }
        }
      }
      entries.append(Entry(code: code, text: text, commits: commits, deletions: deletions,
                           tick: entryTick))
    }
    guard sawHeader else { return nil }
    return RimeUserDictionarySnapshot(dictionary: dictionary, databaseType: databaseType,
                                      rimeVersion: rimeVersion, tick: tick, userID: userID,
                                      entries: entries)
  }
}

/// The levers export: a "Rime user dictionary export" header and `<text>\t<code>\t<weight>` rows.
public struct RimeUserDictionaryExport: Sendable {
  public struct Entry: Sendable, Hashable {
    public let text: String
    public let code: String
    public let weight: Int
  }

  public let entries: [Entry]

  public init(entries: [Entry]) {
    self.entries = entries
  }

  /// The header librime writes, so a rewritten file is still recognisable as this format.
  public static let header = "# Rime user dictionary export"

  /// Writes the format librime's @B@import_user_dict@B@ reads: text, code, weight, tab-separated.
  public func serialize() -> String {
    var lines = [Self.header]
    for entry in entries {
      lines.append(entry.text + "\t" + entry.code + "\t" + String(entry.weight))
    }
    return lines.joined(separator: "\n") + "\n"
  }

  public static func parse(text: String) -> RimeUserDictionaryExport? {
    var entries: [Entry] = []
    var sawHeader = false
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      if line.hasPrefix("# Rime user dictionary export") {
        sawHeader = true
        continue
      }
      if line.hasPrefix("#") || line.isEmpty { continue }
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
      guard fields.count >= 3 else { continue }
      entries.append(Entry(text: String(fields[0]), code: String(fields[1]),
                           weight: Int(fields[2]) ?? 0))
    }
    guard sawHeader else { return nil }
    return RimeUserDictionaryExport(entries: entries)
  }
}

/// One snapshot file found in the sync folder, from this device or another.
public struct RimeSyncSnapshot: Sendable, Hashable {
  public let dictionary: String
  /// The `installation_id` directory the file sits in: one per device, which is why merging is
  /// "read every directory except mine".
  public let deviceID: String
  public let url: URL
  public let bytes: Int
  public let modifiedAt: Date
  /// iCloud has been observed creating "… 2.txt" instead of overwriting, so a conflict copy is a
  /// normal file to read, not an error to raise.
  public let isConflictCopy: Bool
  public let userID: String?
  public let entryCount: Int
}

public enum RimeSyncDiscovery {
  /// The dictionary name in a snapshot file name, tolerating iCloud's conflict-copy suffixes:
  /// `rime_ice.userdb 2.txt`, `rime_ice.userdb (1).txt`, `rime_ice-2.userdb.txt`.
  public static func dictionaryName(fromFileName name: String) -> String? {
    var base = name
    guard base.hasSuffix(".txt") else { return nil }
    base.removeLast(4)
    // iCloud's two observed shapes: "rime_ice.userdb 2.txt" and "rime_ice.userdb (1).txt". A name
    // that merely ends in a number ("rime_ice-2") is a legitimate dictionary name, not a copy, and
    // guessing otherwise would merge two dictionaries the user keeps apart.
    for pattern in [" (", " "] {
      guard let range = base.range(of: pattern, options: .backwards) else { continue }
      let suffix = base[range.upperBound...]
      let isCopySuffix = suffix.hasSuffix(")")
        ? suffix.dropLast().allSatisfy { $0.isNumber || $0 == "(" }
        : suffix.allSatisfy { $0.isNumber }
      if isCopySuffix {
        base = String(base[..<range.lowerBound])
        break
      }
    }
    guard base.hasSuffix(".userdb") else { return nil }
    base.removeLast(".userdb".count)
    return base.isEmpty ? nil : base
  }

  public static func isConflictCopy(fileName: String) -> Bool {
    guard let name = dictionaryName(fromFileName: fileName) else { return false }
    return !fileName.hasPrefix(name + ".userdb.txt")
  }

  /// Every snapshot under a sync directory, device by device. The directory is the user's own:
  /// iCloud Drive, a folder they picked, or the app container — never a server of ours.
  public static func snapshots(in syncDirectory: URL, fileManager: FileManager = .default) -> [RimeSyncSnapshot] {
    guard let devices = try? fileManager.contentsOfDirectory(at: syncDirectory,
                                                             includingPropertiesForKeys: [.isDirectoryKey],
                                                             options: [.skipsHiddenFiles]) else { return [] }
    var result: [RimeSyncSnapshot] = []
    for device in devices {
      guard (try? device.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
      let files = (try? fileManager.contentsOfDirectory(at: device,
                                                        includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                                                        options: [.skipsHiddenFiles])) ?? []
      for file in files {
        guard let dictionary = dictionaryName(fromFileName: file.lastPathComponent) else { continue }
        let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let parsed = RimeUserDictionarySnapshot.parse(text: text, dictionaryName: dictionary)
        result.append(RimeSyncSnapshot(dictionary: dictionary,
                                       deviceID: device.lastPathComponent,
                                       url: file,
                                       bytes: values?.fileSize ?? 0,
                                       modifiedAt: values?.contentModificationDate ?? Date.distantPast,
                                       isConflictCopy: isConflictCopy(fileName: file.lastPathComponent),
                                       userID: parsed?.userID,
                                       entryCount: parsed?.entries.count ?? 0))
      }
    }
    return result.sorted { $0.dictionary == $1.dictionary ? $0.deviceID < $1.deviceID : $0.dictionary < $1.dictionary }
  }
}
