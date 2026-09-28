import Foundation

// MARK: - Manifest

/// What travels with a settings export: the patch files and the custom phrases, plus what they were
/// written against.
///
/// S2 §7: settings move between the phone and Squirrel as plain text the user can read — never the
/// third-party sources themselves, which is S1's import and a licensing question of its own.
public struct RimeSettingsManifest: Codable, Sendable, Hashable {
  public static let currentSchemaVersion = 1

  public struct Entry: Codable, Sendable, Hashable {
    public var path: String
    public var bytes: Int
    public var sha256: String
    public var modifiedAt: Date?

    public init(path: String, bytes: Int, sha256: String, modifiedAt: Date? = nil) {
      self.path = path
      self.bytes = bytes
      self.sha256 = sha256
      self.modifiedAt = modifiedAt
    }
  }

  public var schemaVersion: Int
  public var createdAt: Date
  public var engineVersion: String
  /// The schema ids the export was written against, so an import can say when it is from another
  /// config.
  public var schemaIDs: [String]
  public var files: [Entry]

  public init(createdAt: Date = Date(), engineVersion: String = RimeEngineVersion.pinned,
              schemaIDs: [String] = [], files: [Entry] = []) {
    self.schemaVersion = Self.currentSchemaVersion
    self.createdAt = createdAt
    self.engineVersion = engineVersion
    self.schemaIDs = schemaIDs
    self.files = files
  }

  public var isCompatible: Bool { schemaVersion <= Self.currentSchemaVersion }
}

// MARK: - Files

public struct RimeSettingsFile: Sendable, Hashable {
  public let path: String
  public let contents: Data
  public let modifiedAt: Date?

  public init(path: String, contents: Data, modifiedAt: Date? = nil) {
    self.path = path
    self.contents = contents
    self.modifiedAt = modifiedAt
  }

  public var bytes: Int { contents.count }
  public var sha256: String { RimeDigest.sha256(of: contents) }
  public var text: String? { String(data: contents, encoding: .utf8) }
}

/// The names a settings export may contain. Anything else is refused on import: this path exists to
/// move settings, not to install a config.
public enum RimeSettingsFileKind: Sendable, Hashable {
  case patch
  case customPhrase
  case manifest

  public static func classify(_ path: String) -> RimeSettingsFileKind? {
    if path == "manifest.json" { return .manifest }
    guard !path.contains("/") else { return nil }
    if path.hasSuffix(".custom.yaml") { return .patch }
    if path == "custom_phrase.txt" || path == "custom_phrase.yaml" { return .customPhrase }
    return nil
  }
}

// MARK: - Errors

public enum RimeSettingsError: Error, CustomStringConvertible, Sendable {
  case manifestMissing
  case manifestUnreadable(String)
  case incompatibleVersion(Int)
  case unsafePath(String)
  case notASetting(String)
  case fileMissing(String)
  case archive(RimeArchiveError)

  public var description: String {
    switch self {
    case .manifestMissing:
      return "the import holds no manifest.json, so it is not a settings export"
    case .manifestUnreadable(let reason):
      return "the manifest could not be read: " + reason
    case .incompatibleVersion(let version):
      return "the export was written by a newer version (manifest schemaVersion " + String(version) + ")"
    case .unsafePath(let path):
      return "the export contains an unsafe path: '" + path + "'"
    case .notASetting(let path):
      return "the export contains '" + path + "', which is not a patch file or a custom phrase file"
    case .fileMissing(let path):
      return "the export does not contain '" + path + "'"
    case .archive(let error):
      return error.description
    }
  }
}

// MARK: - Bundle

public struct RimeSettingsBundle: Sendable {
  public let manifest: RimeSettingsManifest
  public let files: [RimeSettingsFile]
  public let data: Data

  public var fileNames: [String] { files.map(\.path) }
}

public enum RimeSettingsMerge: Sendable, Hashable {
  /// The imported file wins.
  case replace
  /// The file already in the user directory wins; the import is reported but not applied.
  case keepExisting
}

public struct RimeSettingsImportResult: Sendable, Hashable {
  public let path: String
  public let kind: RimeSettingsFileKind
  public let applied: Bool
  public let reason: String?
}

// MARK: - Portability

/// S2 §7: export the patch files and the custom phrases, import them back with a per-file merge.
public struct RimeSettingsPortability {
  public let workspace: RimeWorkspace
  public let engine: RimeEngine
  private let fileManager: FileManager

  public init(workspace: RimeWorkspace, engine: RimeEngine, fileManager: FileManager = .default) {
    self.workspace = workspace
    self.engine = engine
    self.fileManager = fileManager
  }

  public var userDirectory: URL { workspace.userData }

  // MARK: Export

  /// Everything the user has written by hand: one patch file per config, plus the phrases.
  ///
  /// `user.yaml` is deliberately not here. It is per-device option state — which schema was last
  /// used, which switches are on — and copying it between devices is how a phone silently changes
  /// what the Mac is typing.
  public func collect() throws -> [RimeSettingsFile] {
    let names = (try? fileManager.contentsOfDirectory(atPath: userDirectory.path)) ?? []
    var files: [RimeSettingsFile] = []
    for name in names.sorted() {
      guard let kind = RimeSettingsFileKind.classify(name), kind != .manifest else { continue }
      let url = userDirectory.appendingPathComponent(name)
      guard let data = try? Data(contentsOf: url) else { continue }
      let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
      files.append(RimeSettingsFile(path: name, contents: data, modifiedAt: modified))
    }
    return files
  }

  public func export(schemaIDs: [String] = []) throws -> RimeSettingsBundle {
    let settings = try collect()
    let manifest = RimeSettingsManifest(
      schemaIDs: schemaIDs.isEmpty ? ((try? engine.schemaIDs()) ?? []) : schemaIDs,
      files: settings.map { RimeSettingsManifest.Entry(path: $0.path, bytes: $0.bytes,
                                                       sha256: $0.sha256, modifiedAt: $0.modifiedAt) })
    var writer = RimeZipWriter()
    for file in settings {
      try writer.addFile(path: file.path, contents: file.contents)
    }
    try writer.addFile(path: "manifest.json", contents: try RimeJSON.encode(manifest))
    return RimeSettingsBundle(manifest: manifest, files: settings, data: writer.data())
  }

  @discardableResult
  public func export(to url: URL, schemaIDs: [String] = []) throws -> RimeSettingsBundle {
    let bundle = try export(schemaIDs: schemaIDs)
    try bundle.data.write(to: url, options: .atomic)
    return bundle
  }

  // MARK: Import

  /// Reads an export without applying anything, so the UI can offer a per-file merge.
  public func inspect(_ url: URL) throws -> RimeSettingsBundle {
    let staging = workspace.staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: staging) }

    let unpacked = staging.appendingPathComponent("unpack", isDirectory: true)
    do {
      let archive = try RimeZipArchive(url: url)
      try archive.extract(to: unpacked)
    } catch let error as RimeArchiveError {
      throw RimeSettingsError.archive(error)
    }

    let manifestURL = unpacked.appendingPathComponent("manifest.json")
    guard fileManager.fileExists(atPath: manifestURL.path) else {
      throw RimeSettingsError.manifestMissing
    }
    let manifest: RimeSettingsManifest
    do {
      manifest = try RimeJSON.decode(RimeSettingsManifest.self, from: try Data(contentsOf: manifestURL))
    } catch {
      throw RimeSettingsError.manifestUnreadable(String(describing: error))
    }
    guard manifest.isCompatible else {
      throw RimeSettingsError.incompatibleVersion(manifest.schemaVersion)
    }

    let entries = (try? fileManager.contentsOfDirectory(atPath: unpacked.path)) ?? []
    var files: [RimeSettingsFile] = []
    for name in entries.sorted() {
      guard let kind = RimeSettingsFileKind.classify(name) else {
        throw RimeSettingsError.notASetting(name)
      }
      guard kind != .manifest else { continue }
      guard !name.contains("..") else { throw RimeSettingsError.unsafePath(name) }
      let data = try Data(contentsOf: unpacked.appendingPathComponent(name))
      files.append(RimeSettingsFile(path: name, contents: data))
    }
    return RimeSettingsBundle(manifest: manifest, files: files, data: Data())
  }

  /// Applies the selected files. Every touched patch is snapshotted first, so the import is
  /// reversible in one action (S2 §5).
  @discardableResult
  public func importSettings(from url: URL,
                             files selected: [String]? = nil,
                             merge: RimeSettingsMerge = .replace) throws -> [RimeSettingsImportResult] {
    let bundle = try inspect(url)
    let wanted = selected ?? bundle.fileNames
    var results: [RimeSettingsImportResult] = []

    // Snapshot the whole user directory's settings once, before the first write.
    let backup = workspace.root.appendingPathComponent("backups", isDirectory: true)
      .appendingPathComponent("settings-" + ISO8601DateFormatter().string(from: Date())
        .replacingOccurrences(of: ":", with: "-"), isDirectory: true)
    if try !collect().isEmpty {
      try fileManager.createDirectory(at: backup, withIntermediateDirectories: true)
      for file in try collect() {
        try file.contents.write(to: backup.appendingPathComponent(file.path), options: .atomic)
      }
    }

    for path in wanted {
      guard !path.contains("/"), !path.contains("..") else {
        throw RimeSettingsError.unsafePath(path)
      }
      guard let kind = RimeSettingsFileKind.classify(path), kind != .manifest else {
        throw RimeSettingsError.notASetting(path)
      }
      guard let file = bundle.files.first(where: { $0.path == path }) else {
        throw RimeSettingsError.fileMissing(path)
      }
      let target = userDirectory.appendingPathComponent(path)
      if fileManager.fileExists(atPath: target.path), merge == .keepExisting {
        results.append(RimeSettingsImportResult(path: path, kind: kind, applied: false,
                                                reason: "已存在的文件保持不变"))
        continue
      }
      try fileManager.createDirectory(at: userDirectory, withIntermediateDirectories: true)
      try file.contents.write(to: target, options: .atomic)
      results.append(RimeSettingsImportResult(path: path, kind: kind, applied: true, reason: nil))
    }
    return results
  }
}
