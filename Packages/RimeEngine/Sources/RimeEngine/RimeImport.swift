import Foundation
import CryptoKit

// MARK: - Digests

public enum RimeDigest {
  public static func sha256(of data: Data) -> String {
    "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// A digest over the tree's contents, not its timestamps: the same config imported twice has the
  /// same id, which is what makes a re-import an update rather than a second copy (S1 §3.2).
  public static func sha256(ofTree root: URL, fileManager: FileManager = .default) -> String {
    var hasher = SHA256()
    let scan = RimeFileScan.scan(root: root, fileManager: fileManager)
    for path in scan.paths {
      hasher.update(data: Data(path.utf8))
      if let data = try? Data(contentsOf: root.appendingPathComponent(path)) {
        hasher.update(data: data)
      }
    }
    return "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

// MARK: - Config root

/// S1 §5.1 stage 3: the directory that holds `default.yaml` and at least one `*.schema.yaml`.
public enum RimeConfigRootLocator {
  public static func matches(_ directory: URL, fileManager: FileManager = .default) -> Bool {
    guard let contents = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return false }
    let hasDefault = contents.contains("default.yaml")
    let hasSchema = contents.contains { $0.hasSuffix(".schema.yaml") }
    return hasDefault && hasSchema
  }

  public static func locate(in tree: URL, fileManager: FileManager = .default) throws -> URL {
    // Three levels at most: the root, one level down, two. A stray archive nested deeper must not
    // be mistaken for the config the user meant.
    let children = childDirectories(of: tree, fileManager: fileManager)
    var grandchildren: [URL] = []
    for child in children {
      grandchildren.append(contentsOf: childDirectories(of: child, fileManager: fileManager))
    }
    let levels = [[tree], children, grandchildren]

    // A complete config first: it is the stronger signal, and a tree that holds one is never
    // mistaken for the schema-only shape.
    for level in levels {
      let found = level.filter { matches($0, fileManager: fileManager) }
      if found.count == 1 { return found[0] }
      if found.count > 1 {
        throw RimeImportError.configRootAmbiguous(found.map(\.lastPathComponent))
      }
    }
    // A tree with schemas and no default.yaml is accepted too: §5.3 generates the missing file.
    for level in levels {
      let found = level.filter { matchesSchemaOnly($0, fileManager: fileManager) }
      if found.count == 1 { return found[0] }
      if found.count > 1 {
        throw RimeImportError.configRootAmbiguous(found.map(\.lastPathComponent))
      }
    }
    // An archive created with `zip -r backup.zip ~/Library/Rime` includes parent folders and can put
    // a valid config below the depth limit. Report where it was found while keeping the limit in
    // S1 §5.1 stage 3.
    if let buried = firstMatchBelowCap(in: tree, fileManager: fileManager) {
      throw RimeImportError.configRootTooDeep(buried.path, buried.depth)
    }
    throw RimeImportError.configRootNotFound
  }

  /// The shallowest config root below the cap, for the message only — nothing is imported from it.
  static func firstMatchBelowCap(in tree: URL,
                                 fileManager: FileManager = .default) -> (path: String, depth: Int)? {
    let rootPath = tree.standardizedFileURL.path
    var level = [tree]
    var depth = 0
    // A stop for a pathological tree: a config ten folders down is not something to keep walking for.
    while depth < 12, !level.isEmpty {
      var next: [URL] = []
      for directory in level {
        next.append(contentsOf: childDirectories(of: directory, fileManager: fileManager))
      }
      depth += 1
      if depth > 2 {
        let complete = next.filter { matches($0, fileManager: fileManager) }
        let found = complete.isEmpty ? next.filter { matchesSchemaOnly($0, fileManager: fileManager) } : complete
        if let match = found.first {
          let path = match.standardizedFileURL.path
          let relative = path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : path
          return (relative, depth)
        }
      }
      level = next
    }
    return nil
  }

  /// A directory with schemas but no `default.yaml` is still a config: §5.3 accepts it and the
  /// importer generates the missing file.
  public static func matchesSchemaOnly(_ directory: URL, fileManager: FileManager = .default) -> Bool {
    guard let contents = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return false }
    return !contents.contains("default.yaml") && contents.contains { $0.hasSuffix(".schema.yaml") }
  }

  private static func childDirectories(of directory: URL, fileManager: FileManager) -> [URL] {
    guard let contents = try? fileManager.contentsOfDirectory(at: directory,
                                                              includingPropertiesForKeys: [.isDirectoryKey],
                                                              options: [.skipsHiddenFiles]) else { return [] }
    return contents.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }
}

// MARK: - Classification

/// S1 §5.3: a real user directory is both a profile and a user directory, so an import splits it.
public struct RimeTreeClassification: Sendable {
  /// Files that become `profiles/<id>/source/`.
  public var profilePaths: [String] = []
  /// Files that belong to the shared user directory and are only ever offered.
  public var userData: [RimeUserDataCandidate] = []
  /// Files that are deliberately not copied, with the reason.
  public var skipped: [SkippedFile] = []
  public var schemaIDs: [String] = []
  public var hasDefaultYAML = false

  public struct SkippedFile: Sendable, Hashable {
    public let path: String
    public let reason: String

    public init(path: String, reason: String) {
      self.path = path
      self.reason = reason
    }
  }

  public var isUserDataOnly: Bool { profilePaths.isEmpty && !userData.isEmpty }

  /// The `default.yaml` generated for a tree that has schemas but no default, per §5.3.
  public var generatedDefaultYAML: String? {
    guard !hasDefaultYAML, !schemaIDs.isEmpty else { return nil }
    var lines = ["# Generated by Arkey: the imported config listed no default.yaml.",
                 "# It lists the schemas that were found, in the order they appeared.",
                 "config_version: \"1\"",
                 "",
                 "schema_list:"]
    for id in schemaIDs {
      lines.append("  - schema: " + id)
    }
    return lines.joined(separator: "\n") + "\n"
  }

  public init() {}
}

public enum RimeTreeClassifier {
  public static func classify(root: URL, fileManager: FileManager = .default) -> RimeTreeClassification {
    var classification = RimeTreeClassification()
    let scan = RimeFileScan.scan(root: root, fileManager: fileManager)
    classification.hasDefaultYAML = scan.paths.contains("default.yaml")
    classification.schemaIDs = scan.paths
      .filter { !$0.contains("/") && $0.hasSuffix(".schema.yaml") }
      .map { String($0.dropLast(".schema.yaml".count)) }

    for path in scan.paths {
      let top = path.split(separator: "/").first.map(String.init) ?? path
      let bytes = scan.bytes[path] ?? 0

      if top == "installation.yaml" {
        classification.skipped.append(.init(path: path,
                                            reason: "an installation id is per install and must not travel"))
      } else if top == "sync" {
        classification.skipped.append(.init(path: path,
                                            reason: "Rime's snapshot folder is S5's transport, not an import"))
      } else if top == "build" {
        classification.skipped.append(.init(path: path, reason: "we deploy from the sources ourselves"))
      } else if top.hasSuffix(".userdb") || path.contains(".userdb/") {
        classification.skipped.append(.init(path: path,
                                            reason: "a leveldb user dictionary is not portable; S5's snapshots are"))
      } else if path.hasSuffix(".custom.yaml") {
        classification.userData.append(RimeUserDataCandidate(kind: .patch, relativePath: path, bytes: bytes))
      } else if path == "custom_phrase.txt" {
        classification.userData.append(RimeUserDataCandidate(kind: .customPhrase, relativePath: path, bytes: bytes))
      } else if path == "user.yaml" {
        classification.userData.append(RimeUserDataCandidate(kind: .userYAML, relativePath: path, bytes: bytes))
      } else {
        classification.profilePaths.append(path)
      }
    }
    return classification
  }

  /// Copies the profile half of a classified tree into a fresh source directory.
  ///
  /// The user half is left behind: it goes to the shared user directory, and only when the user
  /// says so.
  @discardableResult
  public static func materialize(root: URL,
                                 classification: RimeTreeClassification,
                                 into destination: URL,
                                 fileManager: FileManager = .default) throws -> String? {
    try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
    for path in classification.profilePaths {
      let source = root.appendingPathComponent(path)
      let target = destination.appendingPathComponent(path)
      try fileManager.createDirectory(at: target.deletingLastPathComponent(),
                                      withIntermediateDirectories: true)
      do {
        try fileManager.copyItem(at: source, to: target)
      } catch {
        throw RimeImportError.copyFailed(path)
      }
    }
    if let generated = classification.generatedDefaultYAML {
      try generated.write(to: destination.appendingPathComponent("default.yaml"),
                          atomically: true, encoding: .utf8)
      return generated
    }
    return nil
  }
}

// MARK: - Import

public struct RimeImportOptions: Sendable {
  public var displayName: String?
  public var tag: String?
  public var origin: RimeProfileSource
  public var license: RimeProfileLicense?
  public var limits: RimeArchiveLimits
  public var validationBudgets: RimeValidationBudgets
  /// Tables removed from staging before validation; used by curated slim variants.
  public var removedImportTables: [String]
  /// Copies the user-data candidates into the shared user directory. Off by default: these are the
  /// user's own settings, and S1 §5.3 says they are offered, never applied silently.
  public var adoptUserData: Bool

  public init(displayName: String? = nil,
              tag: String? = nil,
              origin: RimeProfileSource,
              license: RimeProfileLicense? = nil,
              limits: RimeArchiveLimits = .standard,
              validationBudgets: RimeValidationBudgets = .standard,
              adoptUserData: Bool = false, removedImportTables: [String] = []) {
    self.displayName = displayName
    self.tag = tag
    self.origin = origin
    self.license = license
    self.limits = limits
    self.validationBudgets = validationBudgets
    self.adoptUserData = adoptUserData
    self.removedImportTables = removedImportTables
  }
}

public struct RimeImportOutcome: Sendable {
  public let metadata: RimeProfileMetadata
  public let userDataCandidates: [RimeUserDataCandidate]
  public let warnings: [RimeValidationIssue]
  public let sourceDigest: String
  /// True when identical content reused an existing profile, preserving its deployed generations.
  public let replacedExisting: Bool
  public let generatedDefaultYAML: String?

  public var profileID: String { metadata.id }
}

public enum RimeImportError: Error, CustomStringConvertible, Sendable {
  case unsupportedPayload(String)
  case configRootNotFound
  case configRootTooDeep(String, Int)
  case configRootAmbiguous([String])
  case userDataOnly([RimeUserDataCandidate])
  case archive(RimeArchiveError)
  case validation(RimeValidationResult)
  case copyFailed(String)
  case installFailed(String)

  public var description: String {
    switch self {
    case .unsupportedPayload(let name):
      return "'" + name + "' is neither a folder nor a zip archive"
    case .configRootNotFound:
      return "no folder in the import holds default.yaml and a schema; this is not a Rime config"
    case .configRootTooDeep(let path, let depth):
      return "the config is at '" + path + "', " + String(depth) + " folders inside the import, and a config "
        + "root may be at most two (S1 §5.1): an archive that stores the path to the Rime folder buries it "
        + "like this. Pack the Rime folder itself — the one holding default.yaml."
    case .configRootAmbiguous(let names):
      return "more than one folder could be the config root: " + names.joined(separator: ", ")
    case .userDataOnly(let candidates):
      return "the import holds only user data (" + candidates.map(\.relativePath).joined(separator: ", ")
        + "), which is a settings import, not a profile"
    case .archive(let error):
      return error.description
    case .validation(let result):
      return result.errors.map(\.description).joined(separator: "; ")
    case .copyFailed(let path):
      return "could not copy '" + path + "' into staging"
    case .installFailed(let reason):
      return "the profile could not be installed: " + reason
    }
  }
}

/// A staged snapshot held while the caller asks whether to include its user settings.
/// Its immutable paths and classification cross tasks; the file manager is used only for cleanup
/// after the final owner releases the snapshot, never concurrently through this object.
public final class RimePreparedImport: @unchecked Sendable {
  fileprivate let staging: URL
  fileprivate let root: URL
  fileprivate let classification: RimeTreeClassification
  private let fileManager: FileManager

  public var userDataCandidates: [RimeUserDataCandidate] { classification.userData }

  fileprivate init(staging: URL, root: URL, classification: RimeTreeClassification,
                   fileManager: FileManager) {
    self.staging = staging
    self.root = root
    self.classification = classification
    self.fileManager = fileManager
  }

  deinit { try? fileManager.removeItem(at: staging) }
}

/// S1 §5.1's pipeline, one path for every entry point. Nothing is installed until the last stage,
/// and staging is removed on success, failure, or when the prepared snapshot is abandoned.
public struct RimeImporter {
  public let workspace: RimeWorkspace
  public let engine: RimeEngine
  private let fileManager: FileManager

  public init(workspace: RimeWorkspace, engine: RimeEngine, fileManager: FileManager = .default) {
    self.workspace = workspace
    self.engine = engine
    self.fileManager = fileManager
  }

  public func `import`(payload: URL, options: RimeImportOptions) throws -> RimeImportOutcome {
    let prepared = try prepare(payload: payload, options: options)
    return try self.import(prepared: prepared, options: options)
  }

  /// Unpack and classify without installing a profile or applying user settings. The prepared
  /// snapshot owns its staging directory until the caller finishes or abandons the import.
  public func prepare(payload: URL, options: RimeImportOptions) throws -> RimePreparedImport {
    try workspace.createDirectories(fileManager: fileManager)
    let staging = workspace.staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
    var preparedSuccessfully = false
    defer { if !preparedSuccessfully { try? fileManager.removeItem(at: staging) } }

    // 1 and 2. Acquire and unpack. The caller holds any security-scoped access; by the time we are
    // here the payload is a plain file URL.
    let tree = try acquire(payload: payload, into: staging, options: options)

    // 3. Locate the config root.
    let root = try RimeConfigRootLocator.locate(in: tree, fileManager: fileManager)

    // 4. Classify.
    let classification = RimeTreeClassifier.classify(root: root, fileManager: fileManager)
    if classification.profilePaths.isEmpty {
      if classification.isUserDataOnly {
        throw RimeImportError.userDataOnly(classification.userData)
      }
      throw RimeImportError.configRootNotFound
    }

    preparedSuccessfully = true
    return RimePreparedImport(staging: staging, root: root, classification: classification,
                              fileManager: fileManager)
  }

  public func `import`(prepared: RimePreparedImport, options: RimeImportOptions) throws -> RimeImportOutcome {
    let staging = prepared.staging
    let root = prepared.root
    let classification = prepared.classification
    defer { try? fileManager.removeItem(at: staging) }

    // 5 and 6. Materialise the profile half, then ask librime whether it will load.
    let source = staging.appendingPathComponent("source", isDirectory: true)
    let generated = try RimeTreeClassifier.materialize(root: root, classification: classification,
                                                       into: source, fileManager: fileManager)
    if !options.removedImportTables.isEmpty {
      let result = try RimeProfileSlimming.removeImportTables(options.removedImportTables,
        from: source, engine: engine, fileManager: fileManager)
      guard result.missingTables.isEmpty else {
        throw RimeSlimmingError.tableNotFound(result.missingTables.joined(separator: ", "))
      }
    }
    let validation = RimeConfigValidation.validate(source: source, engine: engine,
                                                   budgets: options.validationBudgets,
                                                   fileManager: fileManager)
    guard validation.isAcceptable else {
      throw RimeImportError.validation(validation)
    }

    // 7. Install.
    let digest = RimeDigest.sha256(ofTree: source, fileManager: fileManager)
    let displayName = options.displayName ?? root.lastPathComponent
    let id = RimeProfileIdentifier.make(displayName: displayName, tag: options.tag, digest: digest)
    let layout = workspace.profile(id)
    let replaced = fileManager.fileExists(atPath: layout.source.path)
    if replaced, let existing = try workspace.loadMetadata(for: id),
       RimeDigest.sha256(ofTree: layout.source, fileManager: fileManager) == digest {
      if options.adoptUserData { try adopt(classification.userData, from: root) }
      return RimeImportOutcome(metadata: existing, userDataCandidates: classification.userData,
        warnings: validation.warnings, sourceDigest: digest, replacedExisting: true,
        generatedDefaultYAML: generated)
    }
    guard !replaced else { throw RimeImportError.installFailed("profile identity collision") }
    do {
      try fileManager.createDirectory(at: layout.directory, withIntermediateDirectories: true)
      try fileManager.moveItem(at: source, to: layout.source)
    } catch {
      throw RimeImportError.installFailed(String(describing: error))
    }

    let metadata = RimeProfileMetadata(
      id: id,
      displayName: displayName,
      source: RimeProfileSource(kind: options.origin.kind,
                                url: options.origin.url,
                                resolvedURL: options.origin.resolvedURL,
                                releaseTag: options.tag,
                                retrievedAt: Date(),
                                bytes: options.origin.bytes,
                                sha256: options.origin.sha256 ?? digest,
                                catalogEntryID: options.origin.catalogEntryID,
                                releaseAssetID: options.origin.releaseAssetID,
                                releaseAssetUpdatedAt: options.origin.releaseAssetUpdatedAt,
                                transformationVersion: options.origin.transformationVersion),
      license: options.license,
      stats: RimeProfileStats(fileCount: validation.fileCount,
                              sourceBytes: validation.sourceBytes,
                              buildBytes: 0,
                              schemaIDs: validation.schemaIDs))
    try workspace.writeMetadata(metadata, fileManager: fileManager)

    if options.adoptUserData {
      try adopt(classification.userData, from: root)
    }

    return RimeImportOutcome(metadata: metadata,
                             userDataCandidates: classification.userData,
                             warnings: validation.warnings,
                             sourceDigest: digest,
                             replacedExisting: replaced,
                             generatedDefaultYAML: generated)
  }

  /// Copies the user half of a Squirrel-shaped tree into the shared user directory. Only called when
  /// the user asked for it; each file is reported by the caller either way.
  public func adopt(_ candidates: [RimeUserDataCandidate], from root: URL) throws {
    for candidate in candidates {
      let source = root.appendingPathComponent(candidate.relativePath)
      let target = workspace.userData.appendingPathComponent(candidate.relativePath)
      try fileManager.createDirectory(at: target.deletingLastPathComponent(),
                                      withIntermediateDirectories: true)
      if fileManager.fileExists(atPath: target.path) {
        try fileManager.removeItem(at: target)
      }
      do {
        try fileManager.copyItem(at: source, to: target)
      } catch {
        throw RimeImportError.copyFailed(candidate.relativePath)
      }
    }
  }

  private func acquire(payload: URL, into staging: URL, options: RimeImportOptions) throws -> URL {
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: payload.path, isDirectory: &isDirectory) else {
      throw RimeImportError.unsupportedPayload(payload.lastPathComponent)
    }
    if isDirectory.boolValue {
      let tree = staging.appendingPathComponent("tree", isDirectory: true)
      do {
        try fileManager.copyItem(at: payload, to: tree)
      } catch {
        throw RimeImportError.copyFailed(payload.lastPathComponent)
      }
      return tree
    }
    guard payload.pathExtension.lowercased() == "zip" else {
      throw RimeImportError.unsupportedPayload(payload.lastPathComponent)
    }
    let unpack = staging.appendingPathComponent("unpack", isDirectory: true)
    do {
      let archive = try RimeZipArchive(url: payload, limits: options.limits)
      try archive.extract(to: unpack, limits: options.limits)
    } catch let error as RimeArchiveError {
      throw RimeImportError.archive(error)
    }
    return unpack
  }
}
