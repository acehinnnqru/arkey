import Foundation

// MARK: - Notices

/// S6's licence screen, as data: what this install contains, who wrote it, and under what terms.
///
/// The posture S1 §3.6 fixes is that third-party configs arrive only when the user imports or
/// downloads them, and that the licence travels with those files rather than with the program. This
/// type therefore renders what the profiles themselves say — it never asserts a licence on someone
/// else's behalf, and an imported config with no licence recorded shows as @B@NOASSERTION@B@ rather than as
/// something permissive.
public struct RimeNoticeEntry: Sendable, Hashable {
  public let profileID: String
  public let displayName: String
  public let license: RimeProfileLicense
  public let source: RimeProfileSource
  /// The attribution file inside the profile's own sources, when the config shipped one, with
  /// whether it is actually there: a path in @B@meta.json@B@ that does not resolve is a broken notice,
  /// not a notice.
  public let noticePath: String?
  public let noticeExists: Bool

  public var licenseLine: String {
    license.spdx + (license.name.isEmpty ? "" : " (" + license.name + ")")
  }

  /// Where the bytes came from, including the redirect the catalog pointed through: the resolved
  /// URL is the one worth auditing, and the difference between the two is the whole point of the
  /// "a redirect is not a distribution" posture in S1 §3.6.
  public var provenanceLine: String {
    var parts: [String] = [source.kind.rawValue]
    if let url = source.url { parts.append(url) }
    if let resolved = source.resolvedURL, resolved != source.url {
      parts.append("→ " + resolved)
    }
    if let tag = source.releaseTag { parts.append("tag " + tag) }
    return parts.joined(separator: " · ")
  }
}

public struct RimeNotices: Sendable {
  public let entries: [RimeNoticeEntry]
  public let engineVersion: String
  /// S6's mechanical claim, carried here so the screen can state it instead of implying it.
  public let bundleContainsThirdPartyData: Bool

  public var isEmpty: Bool { entries.isEmpty }

  /// Plain text for the share sheet and for the clipboard: the same content the screen renders.
  public var text: String {
    var lines = [RimeLocalization.text("Arkey — Third-party profiles and licenses"), ""]
    if entries.isEmpty {
      lines.append(RimeLocalization.text("No third-party profiles are installed. The keyboard uses only this project’s tracer data (MIT)."))
    } else {
      for entry in entries {
        lines.append(entry.displayName + "（" + entry.profileID + "）")
        lines.append(RimeLocalization.text("  License: \(entry.licenseLine)"))
        if let url = entry.license.url { lines.append(RimeLocalization.text("  Full license: \(url)")) }
        if let url = entry.license.sourceURL { lines.append(RimeLocalization.text("  Source: \(url)")) }
        lines.append(RimeLocalization.text("  Acquisition: \(entry.provenanceLine)"))
        if let notice = entry.noticePath {
          lines.append(RimeLocalization.text("  Attribution: \(notice)\((entry.noticeExists ? "" : RimeLocalization.text(" (not found in files)")))"))
        }
        lines.append("")
      }
    }
    lines.append(RimeLocalization.text("—— Engine and components ——"))
    for component in RimeEngineNotices.components(engineVersion: engineVersion) {
      lines.append("  " + component.line)
      lines.append("    " + component.url)
      if let note = component.note { lines.append("    " + note) }
    }
    lines.append("")
    lines.append(RimeLocalization.text("Arkey is released under MIT. Profiles above are imported or downloaded by the user and carry their own licenses."))
    lines.append(bundleContainsThirdPartyData
                 ? RimeLocalization.text("Warning: the release bundle contains profile data from outside this project.")
                 : RimeLocalization.text("This release bundle contains no third-party profile data."))
    return lines.joined(separator: "\n")
  }
}

public enum RimeNoticesBuilder {
  /// Builds the notices from the installed profiles. @B@bundleThirdPartyData@B@ comes from
  /// @B@RimeReleaseCheck@B@, so the statement on the screen is the one the release script enforces.
  public static func build(workspace: RimeWorkspace,
                           engine: RimeEngine,
                           bundleContainsThirdPartyData: Bool = false,
                           fileManager: FileManager = .default) -> RimeNotices {
    let profiles = (try? workspace.loadMetadataList(fileManager: fileManager)) ?? []
    var entries: [RimeNoticeEntry] = []
    for metadata in profiles {
      let layout = workspace.profile(metadata.id)
      var noticeExists = false
      if let path = metadata.license?.noticePath {
        noticeExists = fileManager.fileExists(atPath: layout.source.appendingPathComponent(path).path)
      }
      entries.append(RimeNoticeEntry(profileID: metadata.id,
                                     displayName: metadata.displayName,
                                     license: metadata.license ?? .unknown,
                                     source: metadata.source,
                                     noticePath: metadata.license?.noticePath,
                                     noticeExists: noticeExists))
    }
    return RimeNotices(entries: entries.sorted { $0.displayName < $1.displayName },
                       engineVersion: RimeEngine.librimeVersion,
                       bundleContainsThirdPartyData: bundleContainsThirdPartyData)
  }
}
