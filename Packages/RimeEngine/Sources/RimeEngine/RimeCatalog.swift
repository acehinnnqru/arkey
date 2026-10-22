import Foundation

// MARK: - Catalog

/// Curated upstream configurations. Fetching and installation are explicit host-app actions;
/// the keyboard extension never downloads, and installation never deploys or activates.
public struct RimeCatalogEntry: Sendable, Hashable {
  public struct Requirements: Sendable, Hashable {
    /// The config runs Lua translators or filters. librime-lua is merged into the pinned framework.
    public let needsLua: Bool
    /// The optional grammar model, which is a separate and very large download.
    public let needsGrammarModel: Bool
    public let needsPredict: Bool
    public let schemaCount: Int

    public init(needsLua: Bool, needsGrammarModel: Bool = false, needsPredict: Bool = false,
                schemaCount: Int = 1) {
      self.needsLua = needsLua
      self.needsGrammarModel = needsGrammarModel
      self.needsPredict = needsPredict
      self.schemaCount = schemaCount
    }

    /// What the user is told before anything is fetched.
    public var summary: String {
      var parts = [RimeLocalization.text("\(String(schemaCount)) schemes")]
      if needsLua { parts.append(RimeLocalization.text("Includes Lua scripts")) }
      if needsGrammarModel { parts.append(RimeLocalization.text("Optional grammar model requires a separate download (about 400 MB)")) }
      if needsPredict { parts.append(RimeLocalization.text("Optional prediction dictionary")) }
      return parts.joined(separator: " · ")
    }
  }

  public let id: String
  public let displayName: String
  public let license: RimeProfileLicense
  /// The upstream release page, shown alongside the preset's license and source.
  public let pageURL: String
  public let approximateBytes: Int
  public let requirements: Requirements
  public let notes: String
  public let releaseChannel: RimeGitHubReleaseChannel?
  public let removedImportTables: [String]

  public init(id: String, displayName: String, license: RimeProfileLicense, pageURL: String,
              approximateBytes: Int, requirements: Requirements, notes: String,
              releaseChannel: RimeGitHubReleaseChannel? = nil, removedImportTables: [String] = []) {
    self.id = id
    self.displayName = displayName
    self.license = license
    self.pageURL = pageURL
    self.approximateBytes = approximateBytes
    self.requirements = requirements
    self.notes = notes
    self.releaseChannel = releaseChannel
    self.removedImportTables = removedImportTables
  }

  public var isSecure: Bool { pageURL.hasPrefix("https://") }
}

public struct RimeCatalog: Sendable {
  public let entries: [RimeCatalogEntry]

  public init(entries: [RimeCatalogEntry]) {
    self.entries = entries
  }

  public func entry(id: String) -> RimeCatalogEntry? {
    entries.first { $0.id == id }
  }

  public static var standard: RimeCatalog {
    let license = RimeProfileLicense(spdx: "GPL-3.0-only",
      name: "GNU General Public License v3.0",
      url: "https://www.gnu.org/licenses/gpl-3.0.html",
      sourceURL: "https://github.com/iDvel/rime-ice", noticePath: "LICENSE")
    return RimeCatalog(entries: [
      RimeCatalogEntry(id: "rime-ice-full",
        displayName: RimeLocalization.text("Rime Ice · Release · Full"), license: license,
        pageURL: "https://github.com/iDvel/rime-ice/releases",
        approximateBytes: 15_290_000, requirements: .init(needsLua: true, schemaCount: 9),
        notes: RimeLocalization.text("Full dictionary with broader coverage, slower deployment, and more storage."),
        releaseChannel: .stable),
      RimeCatalogEntry(id: "rime-ice-lite",
        displayName: RimeLocalization.text("Rime Ice · Release · Slim"), license: license,
        pageURL: "https://github.com/iDvel/rime-ice/releases",
        approximateBytes: 15_290_000, requirements: .init(needsLua: true, schemaCount: 9),
        notes: RimeLocalization.text("Recommended for faster deployment and less storage, with reduced candidate coverage."),
        releaseChannel: .stable, removedImportTables: ["cn_dicts/tencent"]),
      RimeCatalogEntry(id: "rime-ice-nightly-full",
        displayName: RimeLocalization.text("Rime Ice · Nightly · Full"), license: license,
        pageURL: "https://github.com/iDvel/rime-ice/releases/tag/nightly",
        approximateBytes: 15_290_000, requirements: .init(needsLua: true, schemaCount: 9),
        notes: RimeLocalization.text("Full dictionary with broader coverage and development-build compatibility risks."),
        releaseChannel: .nightly),
      RimeCatalogEntry(id: "rime-ice-nightly-slim",
        displayName: RimeLocalization.text("Rime Ice · Nightly · Slim"), license: license,
        pageURL: "https://github.com/iDvel/rime-ice/releases/tag/nightly",
        approximateBytes: 15_290_000, requirements: .init(needsLua: true, schemaCount: 9),
        notes: RimeLocalization.text("Faster deployment with reduced coverage and development-build compatibility risks."),
        releaseChannel: .nightly, removedImportTables: ["cn_dicts/tencent"])
    ])
  }
}

// MARK: - Receipts

/// What was actually fetched, recorded so the licence screen and the audit trail have facts rather
/// than intentions.
public struct RimeCatalogDownloadReceipt: Sendable, Hashable {
  public let entryID: String
  public let pageURL: String
  public let resolvedURL: String?
  public let bytes: Int
  public let sha256: String
  public let retrievedAt: Date

  public init(entryID: String, pageURL: String, resolvedURL: String?, bytes: Int, sha256: String,
              retrievedAt: Date = Date()) {
    self.entryID = entryID
    self.pageURL = pageURL
    self.resolvedURL = resolvedURL
    self.bytes = bytes
    self.sha256 = sha256
    self.retrievedAt = retrievedAt
  }

  public var profileSource: RimeProfileSource {
    RimeProfileSource(kind: .download, url: pageURL, resolvedURL: resolvedURL,
                      retrievedAt: retrievedAt, bytes: bytes, sha256: sha256)
  }
}

public enum RimeCatalogError: Error, CustomStringConvertible, Sendable {
  case unknownEntry(String)
  case insecureURL(String)
  case tooLarge(Int, Int)
  case tooSmall(Int)
  case unreadable(String)

  public var description: String {
    switch self {
    case .unknownEntry(let id):
      return "the catalog has no entry '" + id + "'"
    case .insecureURL(let url):
      return "the catalog entry points at a non-HTTPS URL: " + url
    case .tooLarge(let bytes, let limit):
      return "the download is " + RimeFileScan.megabytes(bytes) + " MB, above the "
        + RimeFileScan.megabytes(limit) + " MB limit"
    case .tooSmall(let bytes):
      return "the download is " + String(bytes) + " bytes: not a config archive"
    case .unreadable(let path):
      return "the downloaded file could not be read: " + path
    }
  }
}

public struct RimeCatalogLimits: Sendable, Equatable {
  /// The whole archive, compressed. A config that ships more than this is not one we offer.
  public var maxBytes: Int
  public var minBytes: Int

  public init(maxBytes: Int = 256 << 20, minBytes: Int = 1024) {
    self.maxBytes = maxBytes
    self.minBytes = minBytes
  }

  public static let standard = RimeCatalogLimits()
}

/// S1 §5: "the app downloads over HTTPS, checks the size, records the digest".
public enum RimeCatalogValidation {
  public static func receipt(for entry: RimeCatalogEntry,
                             fileURL: URL,
                             resolvedURL: String? = nil,
                             limits: RimeCatalogLimits = .standard,
                             retrievedAt: Date = Date(),
                             fileManager: FileManager = .default) throws -> RimeCatalogDownloadReceipt {
    guard entry.isSecure else { throw RimeCatalogError.insecureURL(entry.pageURL) }
    guard let data = try? Data(contentsOf: fileURL) else {
      throw RimeCatalogError.unreadable(fileURL.path)
    }
    guard data.count >= limits.minBytes else { throw RimeCatalogError.tooSmall(data.count) }
    guard data.count <= limits.maxBytes else {
      throw RimeCatalogError.tooLarge(data.count, limits.maxBytes)
    }
    return RimeCatalogDownloadReceipt(entryID: entry.id,
                                      pageURL: entry.pageURL,
                                      resolvedURL: resolvedURL,
                                      bytes: data.count,
                                      sha256: RimeDigest.sha256(of: data),
                                      retrievedAt: retrievedAt)
  }

  /// Resolves an entry before anything is fetched: an unknown id is an error, not a silent no-op.
  public static func entry(id: String, in catalog: RimeCatalog = .standard) throws -> RimeCatalogEntry {
    guard let entry = catalog.entry(id: id) else { throw RimeCatalogError.unknownEntry(id) }
    guard entry.isSecure else { throw RimeCatalogError.insecureURL(entry.pageURL) }
    return entry
  }
}
