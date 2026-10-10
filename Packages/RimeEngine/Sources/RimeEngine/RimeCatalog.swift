import Foundation

// MARK: - Catalog

/// S1 §5's "short static catalog, with hardcoded links".
///
/// There is no catalog protocol and nothing to fetch: the app resolves entries from its own compiled
/// list and never from a URL a page hands it. The page URL is the update channel — the project's page
/// redirects to the current release, so the target version can move without an App Store release.
///
/// Nothing here downloads, deploys or activates anything. A receipt is produced from bytes the user
/// asked for, and the import pipeline takes it from there.
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
  /// The project's own page. It redirects to the current release asset; the app never reads a URL
  /// out of a page it fetched.
  public let pageURL: String
  public let approximateBytes: Int
  public let requirements: Requirements
  public let notes: String

  public init(id: String, displayName: String, license: RimeProfileLicense, pageURL: String,
              approximateBytes: Int, requirements: Requirements, notes: String) {
    self.id = id
    self.displayName = displayName
    self.license = license
    self.pageURL = pageURL
    self.approximateBytes = approximateBytes
    self.requirements = requirements
    self.notes = notes
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

  /// What ships compiled in. One entry, because S1 asks for a *short* catalog and because a config
  /// nobody has measured has no business being offered.
  public static var standard: RimeCatalog { RimeCatalog(entries: [
    RimeCatalogEntry(
      id: "rime-ice-full",
      displayName: RimeLocalization.text("Rime Ice (full)"),
      license: RimeProfileLicense(spdx: "GPL-3.0-only",
                                  name: "GNU General Public License v3.0",
                                  url: "https://www.gnu.org/licenses/gpl-3.0.html",
                                  sourceURL: "https://github.com/iDvel/rime-ice",
                                  noticePath: "others/docs/Credits.md"),
      pageURL: "https://acehinnnqru.github.io/arkey/download/rime-ice",
      approximateBytes: 15_290_000,
      requirements: .init(needsLua: true, schemaCount: 9),
      notes: RimeLocalization.text("Source release, about 15 MB. Deployment is slower but compatible with this app’s pinned librime 1.17.0. The official full_compiled.zip uses upstream librime and may be incompatible.")),
    RimeCatalogEntry(
      id: "rime-ice-lite",
      displayName: RimeLocalization.text("Rime Ice (lite)"),
      license: RimeProfileLicense(spdx: "GPL-3.0-only",
                                  name: "GNU General Public License v3.0",
                                  url: "https://www.gnu.org/licenses/gpl-3.0.html",
                                  sourceURL: "https://github.com/iDvel/rime-ice",
                                  noticePath: "others/docs/Credits.md"),
      pageURL: "https://acehinnnqru.github.io/arkey/download/rime-ice-lite",
      approximateBytes: 5_900_000,
      requirements: .init(needsLua: true, schemaCount: 9),
      notes: RimeLocalization.text("Skips the 16.5 MB embedding dictionary (cn_dicts/tencent.dict.yaml) for much faster deployment. Candidate quality is slightly lower.")),
  ]) }
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
