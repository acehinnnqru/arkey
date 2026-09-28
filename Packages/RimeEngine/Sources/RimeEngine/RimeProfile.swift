import Foundation

// MARK: - Profile identity

/// A profile id: `<slug>-<tag-or-date>-<short-digest>`.
///
/// Chosen so that two imports of different content never collide, and the same content imported
/// twice shares a name — which is what makes re-importing a config an update rather than a copy.
public enum RimeProfileIdentifier {
  public static func slug(_ text: String) -> String {
    let allowed = CharacterSet.alphanumerics
    var pieces: [String] = []
    var current = ""
    for scalar in text.unicodeScalars {
      if allowed.contains(scalar) {
        current.unicodeScalars.append(scalar)
      } else if !current.isEmpty {
        pieces.append(current)
        current = ""
      }
    }
    if !current.isEmpty { pieces.append(current) }
    let joined = pieces.joined(separator: "-").lowercased()
    return joined.isEmpty ? "profile" : String(joined.prefix(48))
  }

  public static func make(displayName: String, tag: String?, digest: String) -> String {
    let short = String(digest.prefix(8))
    var parts = [slug(displayName)]
    if let tag, !tag.isEmpty {
      parts.append(slug(tag))
    } else {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(identifier: "UTC")
      formatter.dateFormat = "yyyyMMdd"
      parts.append(formatter.string(from: Date()))
    }
    parts.append(short)
    return parts.joined(separator: "-")
  }
}

// MARK: - Provenance

public struct RimeProfileSource: Codable, Sendable, Hashable {
  public enum Kind: String, Codable, Sendable {
    case download
    case files
    case shareSheet
    case bundled
    case debugBundled
    case generated
  }

  public var kind: Kind
  /// The URL the user picked or the catalog named.
  public var url: String?
  /// Where the bytes actually came from, after a redirect.
  public var resolvedURL: String?
  public var releaseTag: String?
  public var retrievedAt: Date?
  public var bytes: Int?
  public var sha256: String?

  public init(kind: Kind, url: String? = nil, resolvedURL: String? = nil, releaseTag: String? = nil,
              retrievedAt: Date? = nil, bytes: Int? = nil, sha256: String? = nil) {
    self.kind = kind
    self.url = url
    self.resolvedURL = resolvedURL
    self.releaseTag = releaseTag
    self.retrievedAt = retrievedAt
    self.bytes = bytes
    self.sha256 = sha256
  }
}

public struct RimeProfileLicense: Codable, Sendable, Hashable {
  public var spdx: String
  public var name: String
  public var url: String?
  public var sourceURL: String?
  /// A path inside `source/` that carries the attribution, when the config shipped one.
  public var noticePath: String?

  public init(spdx: String, name: String, url: String? = nil, sourceURL: String? = nil,
              noticePath: String? = nil) {
    self.spdx = spdx
    self.name = name
    self.url = url
    self.sourceURL = sourceURL
    self.noticePath = noticePath
  }

  /// The licence the user's own imported file carries when nothing better is known. Deliberately
  /// not a permissive default: an unknown licence is `NOASSERTION` (SPDX's own word for it).
  public static let unknown = RimeProfileLicense(spdx: "NOASSERTION", name: "Unknown")
}

public struct RimeProfileStats: Codable, Sendable, Hashable {
  public var fileCount: Int
  public var sourceBytes: Int
  public var buildBytes: Int
  public var schemaIDs: [String]

  public init(fileCount: Int = 0, sourceBytes: Int = 0, buildBytes: Int = 0, schemaIDs: [String] = []) {
    self.fileCount = fileCount
    self.sourceBytes = sourceBytes
    self.buildBytes = buildBytes
    self.schemaIDs = schemaIDs
  }
}

public struct RimeProfileDeployRecord: Codable, Sendable, Hashable {
  public var generation: Int
  public var deployedAt: Date
  public var engineVersion: String
  public var durationSeconds: Double
  public var warnings: [String]

  public init(generation: Int, deployedAt: Date, engineVersion: String, durationSeconds: Double,
              warnings: [String] = []) {
    self.generation = generation
    self.deployedAt = deployedAt
    self.engineVersion = engineVersion
    self.durationSeconds = durationSeconds
    self.warnings = warnings
  }
}

/// `profiles/<id>/meta.json`: provenance, not state. It survives a re-deploy, and it is what the
/// licence screen and the diagnostics read.
public struct RimeProfileMetadata: Codable, Sendable, Hashable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var id: String
  public var displayName: String
  public var source: RimeProfileSource
  public var license: RimeProfileLicense?
  public var stats: RimeProfileStats
  public var deploy: RimeProfileDeployRecord?

  public init(id: String, displayName: String, source: RimeProfileSource,
              license: RimeProfileLicense? = nil, stats: RimeProfileStats = RimeProfileStats(),
              deploy: RimeProfileDeployRecord? = nil) {
    self.schemaVersion = Self.currentSchemaVersion
    self.id = id
    self.displayName = displayName
    self.source = source
    self.license = license
    self.stats = stats
    self.deploy = deploy
  }

  /// True when this metadata was written by a version whose layout we do not understand.
  public var isCompatible: Bool { schemaVersion <= Self.currentSchemaVersion }
}

/// `active.json`: the only pointer the keyboard extension reads.
public struct RimeActiveProfile: Codable, Sendable, Hashable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var profileID: String
  public var generation: Int
  public var deployedAt: Date
  public var engineVersion: String
  public var sourceDigest: String?
  public var previousProfileID: String?

  public init(profileID: String, generation: Int, deployedAt: Date = Date(),
              engineVersion: String = RimeEngineVersion.pinned,
              sourceDigest: String? = nil, previousProfileID: String? = nil) {
    self.schemaVersion = Self.currentSchemaVersion
    self.profileID = profileID
    self.generation = generation
    self.deployedAt = deployedAt
    self.engineVersion = engineVersion
    self.sourceDigest = sourceDigest
    self.previousProfileID = previousProfileID
  }

  public var isCompatible: Bool { schemaVersion <= Self.currentSchemaVersion }
}

public enum RimeEngineVersion {
  /// The engine version the deployed tables were compiled by. Tables built by another librime are
  /// not interchangeable, which is why the profile records it.
  public static let pinned = "1.17.0"
}

// MARK: - A profile on disk

/// The paths inside one profile. Everything a profile owns is under one directory, so deleting the
/// profile is deleting one directory (and asking about the user dictionary separately).
public struct RimeProfileLayout: Sendable, Hashable {
  public let directory: URL

  public init(directory: URL) {
    self.directory = directory
  }

  public var source: URL { directory.appendingPathComponent("source", isDirectory: true) }
  public var build: URL { directory.appendingPathComponent("build", isDirectory: true) }
  public var buildPrevious: URL { directory.appendingPathComponent("build.previous", isDirectory: true) }
  public var buildStaging: URL { directory.appendingPathComponent("build.staging", isDirectory: true) }
  public var metadata: URL { directory.appendingPathComponent("meta.json") }

  public var exists: Bool {
    FileManager.default.fileExists(atPath: directory.path)
  }

  /// A build directory is usable when it holds at least one compiled table: an empty directory is
  /// what a killed deploy leaves behind, and binding the engine to it produces a keyboard with no
  /// candidates rather than an error.
  public func buildIsUsable(_ url: URL) -> Bool {
    guard let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
      return false
    }
    return contents.contains { $0.hasSuffix(".bin") || $0 == "default.yaml" }
  }
}

// MARK: - User-data candidates found during an import

/// A file found in an imported tree that belongs to the shared user directory rather than to the
/// profile, per S1 §5.3. Never applied silently: these are the user's own settings.
public struct RimeUserDataCandidate: Sendable, Hashable {
  public enum Kind: String, Sendable {
    case patch
    case customPhrase
    case userYAML
  }

  public let kind: Kind
  /// Path relative to the imported tree's root.
  public let relativePath: String
  public let bytes: Int

  public init(kind: Kind, relativePath: String, bytes: Int) {
    self.kind = kind
    self.relativePath = relativePath
    self.bytes = bytes
  }
}
