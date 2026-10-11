import Foundation

/// Lossless source records live outside profiles and native user databases. The portable index is
/// derived from those records; it never replaces them and never guesses a pronunciation from text.
public struct RimePersonalDictionary: Codable, Sendable {
  public struct Source: Codable, Sendable {
    public let dictionary: String
    public let capturedAt: Date
    public let digest: String
    public let snapshot: String
    public let isPlainMandarin: Bool
  }

  public struct Word: Sendable, Hashable {
    public let text: String
    public let syllables: String
    public let isDeleted: Bool
  }

  public var formatVersion = 1
  public private(set) var sources: [Source] = []
  /// Clearing a native dictionary must not make automatic compatibility immediately refill it.
  public var pausedDictionaries: Set<String> = []
  public init() {}

  public mutating func retain(dictionary: String, snapshot: String, isPlainMandarin: Bool,
                              now: Date = Date()) throws {
    guard let parsed = RimeUserDictionarySnapshot.parse(text: snapshot),
          parsed.dictionary == dictionary, parsed.databaseType == "userdb" else {
      throw RimePersonalDictionaryError.invalidSource(dictionary)
    }
    let digest = RimeDigest.sha256(of: Data(snapshot.utf8))
    // Only consecutive duplicates are skipped. Returning to an older state is a new observation.
    if let previous = sources.last(where: { $0.dictionary == dictionary }),
       previous.digest == digest, previous.isPlainMandarin == isPlainMandarin { return }
    sources.append(Source(dictionary: dictionary, capturedAt: now, digest: digest,
                          snapshot: snapshot, isPlainMandarin: isPlainMandarin))
  }

  public var latestSources: [Source] {
    var latest: [String: Source] = [:]
    for source in sources { latest[source.dictionary] = source }
    return latest.values.sorted { $0.dictionary < $1.dictionary }
  }

  public var words: [Word] {
    struct Key: Hashable { let text: String; let code: String }
    let compatible = Set(latestSources.filter(\.isPlainMandarin).map(\.dictionary))
    var perSource: [String: [Key: Bool]] = [:]
    // Absence from a later native snapshot is not a deletion: native databases can be reset or
    // rebuilt. Only an explicit marker updates a retained word to deleted.
    for source in sources where source.isPlainMandarin && compatible.contains(source.dictionary) {
      guard let parsed = RimeUserDictionarySnapshot.parse(text: source.snapshot) else { continue }
      for entry in parsed.entries {
        guard let code = RimeMandarinCode.normalize(entry.code), !entry.text.isEmpty else { continue }
        perSource[source.dictionary, default: [:]][Key(text: entry.text, code: code)] = entry.commits < 0
      }
    }
    var deletedByKey: [Key: Bool] = [:]
    for records in perSource.values {
      for (key, deleted) in records {
        // A deletion in any current source prevents a stale source from resurrecting the word.
        deletedByKey[key] = (deletedByKey[key] ?? false) || deleted
      }
    }
    return deletedByKey.map { Word(text: $0.key.text, syllables: $0.key.code, isDeleted: $0.value) }
      .sorted { ($0.text, $0.syllables) < ($1.text, $1.syllables) }
  }

  public var unconvertedCount: Int {
    let compatible = Set(latestSources.filter(\.isPlainMandarin).map(\.dictionary))
    var unconverted: Set<String> = []
    for source in sources {
      let entries = RimeUserDictionarySnapshot.parse(text: source.snapshot)?.entries ?? []
      for entry in entries where !compatible.contains(source.dictionary) || RimeMandarinCode.normalize(entry.code) == nil {
        unconverted.insert(source.dictionary + "\t" + entry.text + "\t" + entry.code)
      }
    }
    return unconverted.count
  }

  public func additions(to snapshot: RimeUserDictionarySnapshot) -> [RimeUserDictionaryExport.Entry] {
    let existing = Set(snapshot.entries.map { $0.text + "\t" + (RimeMandarinCode.normalize($0.code) ?? $0.code) })
    return words.filter { !$0.isDeleted && !existing.contains($0.text + "\t" + $0.syllables) }
      .map { RimeUserDictionaryExport.Entry(text: $0.text, code: $0.syllables, weight: 1) }
  }
}

/// A native database is prepared under a separate name. The original is never imported into.
/// The journal survives the staging janitor and is recovered before any process opens a session.
struct RimePersonalDictionaryTransaction {
  enum Phase: String, Codable { case preparing, publishing, committed }
  struct Record: Codable {
    let dictionary: String
    let temporaryName: String
    let hadOriginal: Bool
    var phase: Phase
  }
  let userData: URL
  let fileManager: FileManager
  private var root: URL { userData.appendingPathComponent("arkey-personal-transactions") }

  func perform<T>(dictionary: String, _ prepare: (String, URL) throws -> T) throws -> T {
    let id = UUID().uuidString
    let temporaryName = "arkey_personal_" + id.replacingOccurrences(of: "-", with: "")
    let directory = root.appendingPathComponent("personal-merge-" + id)
    let target = userData.appendingPathComponent(dictionary + ".userdb")
    let temporary = userData.appendingPathComponent(temporaryName + ".userdb")
    let original = directory.appendingPathComponent("original.userdb")
    var record = Record(dictionary: dictionary, temporaryName: temporaryName,
                        hadOriginal: fileManager.fileExists(atPath: target.path), phase: .preparing)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let journal = directory.appendingPathComponent("transaction.json")
    do {
      try RimeJSON.encode(record).write(to: journal, options: .atomic)
      if record.hadOriginal { try fileManager.copyItem(at: target, to: temporary) }
      let result = try prepare(temporaryName, directory)
      record.phase = .publishing
      try RimeJSON.encode(record).write(to: journal, options: .atomic)
      if record.hadOriginal { try fileManager.moveItem(at: target, to: original) }
      try fileManager.moveItem(at: temporary, to: target)
      var committed = record
      committed.phase = .committed
      try RimeJSON.encode(committed).write(to: journal, options: .atomic)
      record = committed
      // Once committed, failed cleanup cannot turn a successful publication into a rollback.
      try? recover(directory: directory, record: record)
      return result
    } catch {
      let originalError = error
      do { try recover(directory: directory, record: record) }
      catch { throw RimePersonalDictionaryError.recoveryFailed(String(describing: originalError), String(describing: error)) }
      throw originalError
    }
  }

  func recoverAll() throws {
    guard fileManager.fileExists(atPath: root.path) else { return }
    for directory in try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
      guard directory.lastPathComponent.hasPrefix("personal-merge-") else { continue }
      let journal = directory.appendingPathComponent("transaction.json")
      guard fileManager.fileExists(atPath: journal.path) else {
        // An interruption before writing the journal cannot have touched a native database.
        continue
      }
      let record = try RimeJSON.decode(Record.self, from: Data(contentsOf: journal))
      guard validName(record.dictionary), record.temporaryName.hasPrefix("arkey_personal_"),
            validName(record.temporaryName), record.dictionary != record.temporaryName else {
        throw RimePersonalDictionaryError.invalidSource("transaction")
      }
      try recover(directory: directory, record: record)
    }
  }

  private func validName(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
      && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
  }

  private func recover(directory: URL, record: Record) throws {
    let target = userData.appendingPathComponent(record.dictionary + ".userdb")
    let temporary = userData.appendingPathComponent(record.temporaryName + ".userdb")
    let original = directory.appendingPathComponent("original.userdb")
    if record.phase == .publishing {
      if record.hadOriginal, fileManager.fileExists(atPath: original.path) {
        if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
        try fileManager.moveItem(at: original, to: target)
      } else if !record.hadOriginal, fileManager.fileExists(atPath: target.path) {
        try fileManager.removeItem(at: target)
      }
    }
    if fileManager.fileExists(atPath: temporary.path) { try fileManager.removeItem(at: temporary) }
    try fileManager.removeItem(at: directory)
  }
}

/// Only syllable spellings are normalized. Tone digits, auxiliary codes, abbreviations and unknown
/// spellings remain in the raw sources until a tested adapter exists for them.
public enum RimeMandarinCode {
  private static let syllables: Set<String> = Set("""
    a ai an ang ao ba bai ban bang bao bei ben beng bi bian biao bie bin bing bo bu
    ca cai can cang cao ce cen ceng cha chai chan chang chao che chen cheng chi chong chou
    chu chua chuai chuan chuang chui chun chuo ci cong cou cu cuan cui cun cuo
    da dai dan dang dao de dei den deng di dia dian diao die ding diu dong dou du duan dui dun duo
    e ei en eng er fa fan fang fei fen feng fo fou fu ga gai gan gang gao ge gei gen geng
    gong gou gu gua guai guan guang gui gun guo ha hai han hang hao he hei hen heng
    hong hou hu hua huai huan huang hui hun huo ji jia jian jiang jiao jie jin jing jiong jiu
    ju juan jue jun ka kai kan kang kao ke kei ken keng kong kou ku kua kuai kuan kuang kui kun kuo
    la lai lan lang lao le lei leng li lia lian liang liao lie lin ling liu lo long lou lu
    luan lun luo lv lve ma mai man mang mao me mei men meng mi mian miao mie min ming miu mo mou mu
    na nai nan nang nao ne nei nen neng ni nian niang niao nie nin ning niu nong nou nu nuan nuo nv nve
    o ou pa pai pan pang pao pei pen peng pi pian piao pie pin ping po pou pu
    qi qia qian qiang qiao qie qin qing qiong qiu qu quan que qun
    ran rang rao re ren reng ri rong rou ru ruan rui run ruo
    sa sai san sang sao se sen seng sha shai shan shang shao she shei shen sheng shi
    shou shu shua shuai shuan shuang shui shun shuo si song sou su suan sui sun suo
    ta tai tan tang tao te teng ti tian tiao tie ting tong tou tu tuan tui tun tuo
    wa wai wan wang wei wen weng wo wu xi xia xian xiang xiao xie xin xing xiong xiu xu xuan xue xun
    ya yan yang yao ye yi yin ying yo yong you yu yuan yue yun za zai zan zang zao ze zei zen zeng
    zha zhai zhan zhang zhao zhe zhei zhen zheng zhi zhong zhou zhu zhua zhuai zhuan zhuang
    zhui zhun zhuo zi zong zou zu zuan zui zun zuo m n ng hm hng
    """.split(whereSeparator: { $0.isWhitespace }).map(String.init))

  public static func normalize(_ code: String) -> String? {
    let parts = code.lowercased().replacingOccurrences(of: "ü", with: "v")
      .split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard !parts.isEmpty, parts.allSatisfy({ syllables.contains($0) }) else { return nil }
    return parts.joined(separator: " ")
  }
}

public enum RimePersonalDictionaryError: Error, CustomStringConvertible {
  case invalidSource(String)
  case unsupportedVersion(Int)
  case verificationFailed(String)
  case recoveryFailed(String, String)

  public var description: String {
    switch self {
    case .invalidSource(let name): return "invalid personal dictionary source: " + name
    case .unsupportedVersion(let version): return "unsupported personal dictionary format: " + String(version)
    case .verificationFailed(let name): return "personal word import could not be verified: " + name
    case .recoveryFailed(let original, let recovery): return original + "; dictionary recovery failed: " + recovery
    }
  }
}

/// All native reads and writes use the existing cross-process dictionary lock. Exporting retained
/// sources does not open librime and remains possible while the keyboard is using a native database.
public struct RimePersonalDictionaryService {
  public struct Outcome: Sendable {
    public let library: RimePersonalDictionary
    public let imported: Int
    public let failures: [String]
    public let unsupportedTargets: [String]
  }

  public let workspace: RimeWorkspace
  public let engine: RimeEngine
  private let fileManager: FileManager
  private let compatibleBaseDictionaries: Set<String>
  public static let supportedBaseDictionaries: Set<String> = ["rime_ice", "rime_frost", "luna_pinyin", "clover"]

  public init(workspace: RimeWorkspace, engine: RimeEngine, fileManager: FileManager = .default,
              compatibleBaseDictionaries: Set<String> = Self.supportedBaseDictionaries) {
    self.workspace = workspace
    self.engine = engine
    self.fileManager = fileManager
    self.compatibleBaseDictionaries = compatibleBaseDictionaries
  }

  public var storeURL: URL { workspace.root.appendingPathComponent("personal-dictionary/sources.json") }

  public func load() throws -> RimePersonalDictionary {
    guard fileManager.fileExists(atPath: storeURL.path) else { return RimePersonalDictionary() }
    let library = try RimeJSON.decode(RimePersonalDictionary.self, from: Data(contentsOf: storeURL))
    guard library.formatVersion == 1 else { throw RimePersonalDictionaryError.unsupportedVersion(library.formatVersion) }
    for source in library.sources {
      guard source.digest == RimeDigest.sha256(of: Data(source.snapshot.utf8)),
            RimeUserDictionarySnapshot.parse(text: source.snapshot)?.dictionary == source.dictionary else {
        throw RimePersonalDictionaryError.invalidSource(source.dictionary)
      }
    }
    return library
  }

  public func save(_ library: RimePersonalDictionary) throws {
    try fileManager.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try RimeJSON.encode(library).write(to: storeURL, options: .atomic)
  }

  private struct Binding {
    let name: String
    let isCompatible: Bool
  }

  private func binding(_ config: RimeConfigRef) -> Binding? {
    guard config.bool("translator/enable_user_dict") != false,
          let base = config.string("translator/dictionary"), !base.isEmpty else { return nil }
    let name = config.string("translator/user_dict") ?? String(base.split(separator: ".").first ?? "")
    guard Self.safeName(name) else { return nil }
    let translators = config.listPaths("engine/translators").compactMap { config.string($0) }
    let databaseClass = config.string("translator/db_class") ?? "userdb"
    return Binding(name: name, isCompatible: compatibleBaseDictionaries.contains(base)
                   && databaseClass == "userdb" && translators.contains("script_translator"))
  }

  private static func safeName(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
      && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
  }

  /// Read compiled schemas, including patches. Sharing a user dictionary with an incompatible
  /// schema makes that source unsuitable for automatic conversion, even if its name looks familiar.
  private func sourceCompatibility() throws -> [String: Bool] {
    var result: [String: Bool] = [:]
    for id in try workspace.profileIDs() {
      let build = workspace.profile(id).build
      let files = (try? fileManager.contentsOfDirectory(at: build, includingPropertiesForKeys: nil)) ?? []
      for file in files where file.lastPathComponent.hasSuffix(".schema.yaml") {
        let config = try engine.configFromYAML(String(contentsOf: file, encoding: .utf8))
        defer { config.close() }
        if let binding = binding(config) {
          result[binding.name] = (result[binding.name] ?? true) && binding.isCompatible
        }
      }
    }
    return result
  }

  private func activeBindings() throws -> [Binding] {
    let build = URL(fileURLWithPath: engine.directories.prebuiltDataDir)
    let defaults = try engine.configFromYAML(String(contentsOf: build.appendingPathComponent("default.yaml"), encoding: .utf8))
    defer { defaults.close() }
    let ids = defaults.value("schema_list")?.listValue?.compactMap { $0.mapValue?["schema"]?.stringValue } ?? []
    var result: [String: Bool] = [:]
    for id in ids {
      guard Self.safeName(id) else { continue }
      let config = try engine.configFromYAML(String(contentsOf: build.appendingPathComponent(id + ".schema.yaml"), encoding: .utf8))
      defer { config.close() }
      if let binding = binding(config) {
        result[binding.name] = (result[binding.name] ?? true) && binding.isCompatible
      }
    }
    return result.keys.sorted().map { Binding(name: $0, isCompatible: result[$0] == true) }
  }

  private func capture(_ name: String, compatible: Bool, library: inout RimePersonalDictionary) throws -> String {
    var isDirectory: ObjCBool = false
    let database = workspace.userData.appendingPathComponent(name + ".userdb")
    guard Self.safeName(name), fileManager.fileExists(atPath: database.path, isDirectory: &isDirectory),
          isDirectory.boolValue, try engine.backupUserDictionary(name),
          let directory = RimeSyncService(workspace: workspace, engine: engine, fileManager: fileManager).deviceDirectory else {
      throw RimePersonalDictionaryError.invalidSource(name)
    }
    let text = try String(contentsOf: directory.appendingPathComponent(name + ".userdb.txt"), encoding: .utf8)
    var next = library
    try next.retain(dictionary: name, snapshot: text, isPlainMandarin: compatible)
    // Persist each successful source before attempting anything that can change a native database.
    try save(next)
    library = next
    return text
  }

  public func synchronize(applyWords: Bool = true) throws -> Outcome {
    try RimeDictionaryAccess(workspace: workspace, engine: engine).perform {
      try RimePersonalDictionaryTransaction(userData: workspace.userData, fileManager: fileManager).recoverAll()
      _ = try engine.start()
      var library = try load()
      let compatibility = try sourceCompatibility()
      let targets = try activeBindings()
      let names = Set(try engine.userDictionaryNames())
        .union(RimeSyncService(workspace: workspace, engine: engine, fileManager: fileManager).discoveredDatabaseNames()).sorted()
      var failures: [String] = []
      var fresh: [String: String] = [:]
      for name in names {
        // An archived adapter remains usable after its profile is uninstalled.
        let compatible = compatibility[name] ?? library.latestSources.first { $0.dictionary == name }?.isPlainMandarin ?? false
        do { fresh[name] = try capture(name, compatible: compatible, library: &library) }
        catch { failures.append(name + ": " + String(describing: error)) }
      }
      var imported = 0
      // A failed capture could hide a new deletion. Preserve successful sources, but defer all
      // automatic additions until every live source can be read safely.
      for target in targets where applyWords && failures.isEmpty && target.isCompatible && compatibility[target.name] != false
        && !library.pausedDictionaries.contains(target.name) {
        // Do not overwrite a database whose current state could not be preserved.
        if names.contains(target.name), fresh[target.name] == nil { continue }
        do {
          let added = try apply(library, to: target.name, original: fresh[target.name])
          imported += added
          if added > 0 {
            _ = try capture(target.name, compatible: true, library: &library)
          }
        } catch { failures.append(target.name + ": " + String(describing: error)) }
      }
      return Outcome(library: library, imported: imported, failures: failures,
                     unsupportedTargets: targets.filter { !$0.isCompatible || compatibility[$0.name] == false }.map(\.name))
    }
  }

  private func apply(_ library: RimePersonalDictionary, to name: String, original: String?) throws -> Int {
    let empty = RimeUserDictionarySnapshot(dictionary: name, databaseType: "userdb", rimeVersion: nil,
                                           tick: nil, userID: nil, entries: [])
    let previous = original.flatMap { RimeUserDictionarySnapshot.parse(text: $0) } ?? empty
    let additions = library.additions(to: previous)
    guard !additions.isEmpty else { return 0 }
    return try RimePersonalDictionaryTransaction(userData: workspace.userData, fileManager: fileManager)
      .perform(dictionary: name) { temporaryName, directory in
        let input = directory.appendingPathComponent("additions.txt")
        try RimeUserDictionaryExport(entries: additions).serialize().write(to: input, atomically: true, encoding: .utf8)
        let count = try engine.importUserDictionary(temporaryName, from: input)
        let output = directory.appendingPathComponent("verified.txt")
        _ = try engine.exportUserDictionary(temporaryName, to: output)
        let exported = RimeUserDictionaryExport.parse(text: try String(contentsOf: output, encoding: .utf8))
        let actual = Set((exported?.entries ?? []).map { $0.text + "\t" + (RimeMandarinCode.normalize($0.code) ?? $0.code) })
        // Verify preservation too, rather than assuming a native import kept previous entries.
        let expected = additions + previous.entries.filter { $0.commits >= 0 }.map {
          RimeUserDictionaryExport.Entry(text: $0.text, code: RimeMandarinCode.normalize($0.code) ?? $0.code, weight: $0.commits)
        }
        guard count >= 0, expected.allSatisfy({ actual.contains($0.text + "\t" + $0.code) }) else {
          throw RimePersonalDictionaryError.verificationFailed(name)
        }
        return additions.count
      }
  }

  /// Preserve the current source first; if that fails, clearing must not discard the only copy.
  public func pauseBeforeClearing(_ name: String) throws {
    try RimeDictionaryAccess(workspace: workspace, engine: engine).perform {
      var library = try load()
      let compatible = try sourceCompatibility()[name] ?? false
      _ = try capture(name, compatible: compatible, library: &library)
      library.pausedDictionaries.insert(name)
      try save(library)
    }
  }

  public func resume(_ name: String) throws {
    try RimeDictionaryAccess(workspace: workspace, engine: engine).perform {
      var library = try load()
      library.pausedDictionaries.remove(name)
      try save(library)
    }
  }

  public func export(to url: URL) throws {
    let library = try load()
    var writer = RimeZipWriter()
    try writer.addFile(path: "sources.json", contents: RimeJSON.encode(library))
    var written: Set<String> = []
    for source in library.sources {
      let hash = String(source.digest.dropFirst("sha256:".count))
      if written.insert(hash).inserted {
        try writer.addFile(path: "raw/" + hash + ".userdb.txt", text: source.snapshot)
      }
    }
    let rows = library.words.map { $0.text + "\t" + $0.syllables + "\t" + ($0.isDeleted ? "deleted" : "active") }
    try writer.addFile(path: "personal-words.tsv", text: "text\tpinyin\tstatus\n" + rows.joined(separator: "\n") + "\n")
    try writer.addFile(path: "README.txt", text: """
      Arkey personal dictionary source export (version 1)

      sources.json retains original Rime snapshots, source dictionary names, capture dates and digests.
      raw/ contains the original UTF-8 snapshots, including native codes and deletion markers.
      personal-words.tsv is a derived index of recognized Mandarin words, not a Rime import file.
      Unrecognized codes remain in the raw records. No pronunciation is guessed from word text.
      Native learning scores are retained in the sources; they are not combined across dictionaries.
      Automatic compatibility adds missing words with initial weight 1 and preserves existing entries.
      Deletion markers prevent automatic reintroduction; they do not delete entries in other databases.
      Clearing a scheme dictionary keeps these sources and pauses automatic restoration to that dictionary.
      This export contains private learned words. Share it only with recipients you choose.
      To use a raw snapshot with Squirrel, follow Rime's user-data import/sync procedure for its dictionary.
      This ZIP is an Arkey source archive, not a ZIP to unzip directly into a Rime sync folder.
      """ + "\n")
    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try writer.data().write(to: url, options: .atomic)
  }
}
