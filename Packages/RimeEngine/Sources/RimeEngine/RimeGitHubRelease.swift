import Foundation

public enum RimeGitHubReleaseChannel: String, Sendable, Hashable {
  case stable
  case nightly

  public func apiURL(page: Int = 1) -> URL {
    let path = self == .nightly ? "releases/tags/nightly" : "releases?per_page=100&page=\(page)"
    return URL(string: "https://api.github.com/repos/iDvel/rime-ice/" + path)!
  }
}

/// GitHub's public release response. A moving nightly tag requires asset identity as well as a tag.
public struct RimeGitHubRelease: Decodable, Sendable, Hashable {
  public struct Asset: Decodable, Sendable, Hashable {
    public let id: Int
    public let name: String
    public let size: Int
    public let browserDownloadURL: String
    public let updatedAt: String
    public let digest: String?

    enum CodingKeys: String, CodingKey {
      case id, name, size, digest
      case browserDownloadURL = "browser_download_url"
      case updatedAt = "updated_at"
    }
  }

  public let tagName: String
  public let htmlURL: String
  public let body: String?
  public let draft: Bool
  public let prerelease: Bool
  public let publishedAt: String?
  public let assets: [Asset]

  enum CodingKeys: String, CodingKey {
    case body, draft, prerelease, assets
    case tagName = "tag_name"
    case htmlURL = "html_url"
    case publishedAt = "published_at"
  }

  public var sourceArchive: Asset? {
    assets.first { $0.name == "full.zip" && $0.size > 0 }
  }

  public static func select(from data: Data, channel: RimeGitHubReleaseChannel) throws -> Self? {
    let decoder = JSONDecoder()
    if channel == .nightly {
      let release = try decoder.decode(Self.self, from: data)
      return !release.draft && release.tagName == "nightly" && release.sourceArchive != nil ? release : nil
    }
    // Nightly is not necessarily a GitHub prerelease; tools releases are not configurations.
    return try decoder.decode([Self].self, from: data)
      .filter { !$0.draft && !$0.prerelease && $0.tagName != "nightly" && $0.sourceArchive != nil }
      .max { ($0.publishedAt ?? "") < ($1.publishedAt ?? "") }
  }
}

public enum RimeDownloadURL {
  /// Shared by explicit ZIP URLs and redirects. Credentials must not enter saved provenance.
  public static func validate(_ value: String) throws -> URL {
    guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
          url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
          url.user == nil, url.password == nil else {
      throw RimeCatalogError.insecureURL(value)
    }
    return url
  }

  public static func githubAsset(_ value: String) throws -> URL {
    let url = try validate(value)
    guard url.host?.lowercased() == "github.com",
          url.path.hasPrefix("/iDvel/rime-ice/releases/download/"),
          url.lastPathComponent == "full.zip" else {
      throw RimeCatalogError.unreadable("unexpected GitHub release asset URL")
    }
    return url
  }
}
