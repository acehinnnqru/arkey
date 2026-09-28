import Foundation

/// S6's mechanical licence check: "a Release bundle contains no third-party config data, checked
/// mechanically — the release script walks the built `.app` and `.appex` and fails if anything other
/// than our own tracer data is present."
///
/// The check is content-based rather than name-based: a file is ours when it exists in the
/// repository's `RimeData` with the same bytes. A renamed copy of someone else's dictionary is
/// therefore still a finding, which is the whole point — S1's licensing posture is that third-party
/// data is imported by the user at runtime and never travels inside a build.
public enum RimeReleaseCheck {
  public struct Finding: Sendable, Hashable, CustomStringConvertible {
    public enum Severity: String, Sendable {
      case error
      /// Something that should be there and is not, which is a broken build rather than a licence
      /// problem.
      case warning
    }

    public let severity: Severity
    public let path: String
    public let reason: String

    public var description: String {
      severity.rawValue + ": " + path + ": " + reason
    }
  }

  public struct Result: Sendable {
    public let bundle: String
    public let dataDirectories: [String]
    public let fileCount: Int
    public let findings: [Finding]

    public var errors: [Finding] { findings.filter { $0.severity == .error } }
    public var warnings: [Finding] { findings.filter { $0.severity == .warning } }
    public var isClean: Bool { errors.isEmpty }

    public var summary: String {
      var parts = [String(fileCount) + " Rime data files in "
                   + String(dataDirectories.count) + " data directories"]
      if findings.isEmpty {
        parts.append("no findings")
      } else {
        parts.append(String(errors.count) + " errors, " + String(warnings.count) + " warnings")
      }
      return parts.joined(separator: "; ")
    }

    public var report: String {
      var lines = ["release check: " + bundle, "  " + summary]
      for directory in dataDirectories {
        lines.append("  data directory: " + directory)
      }
      for finding in findings {
        lines.append("  " + finding.description)
      }
      return lines.joined(separator: "\n")
    }
  }

  /// Names that must never appear in a shipped bundle, whatever their content: a local development
  /// copy, an imported profile, or a learned dictionary.
  public static let forbiddenNames: [String] = ["RimeData.local", "profiles", "staging", "user"]

  public static func check(bundle: URL, tracerData: URL, fileManager: FileManager = .default) -> Result {
    var findings: [Finding] = []
    var dataDirectories: [String] = []
    var fileCount = 0

    let tracer = RimeFileScan.scan(root: tracerData, fileManager: fileManager)
    var tracerDigests: [String: String] = [:]
    for path in tracer.paths {
      if let data = try? Data(contentsOf: tracerData.appendingPathComponent(path)) {
        tracerDigests[path] = RimeDigest.sha256(of: data)
      }
    }

    guard let enumerator = fileManager.enumerator(at: bundle,
                                                  includingPropertiesForKeys: [.isDirectoryKey],
                                                  options: []) else {
      return Result(bundle: bundle.path, dataDirectories: [], fileCount: 0,
                    findings: [Finding(severity: .error, path: bundle.path,
                                       reason: "the bundle could not be read")])
    }

    for case let url as URL in enumerator {
      let name = url.lastPathComponent
      let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true

      if forbiddenNames.contains(name) {
        findings.append(Finding(severity: .error, path: relative(url, to: bundle),
                                reason: isDirectory
                                  ? "a shipped bundle must not contain '" + name + "'"
                                  : "a shipped bundle must not contain a file named '" + name + "'"))
        if isDirectory { enumerator.skipDescendants() }
        continue
      }

      guard isDirectory, name == "RimeData" else { continue }
      dataDirectories.append(relative(url, to: bundle))
      let contents = RimeFileScan.scan(root: url, fileManager: fileManager)
      fileCount += contents.paths.count
      for path in contents.paths {
        let digest = (try? Data(contentsOf: url.appendingPathComponent(path)))
          .map { RimeDigest.sha256(of: $0) }
        guard let expected = tracerDigests[path] else {
          findings.append(Finding(severity: .error,
                                  path: relative(url.appendingPathComponent(path), to: bundle),
                                  reason: "not part of this repository's tracer data: a Release bundle "
                                    + "must carry no third-party config"))
          continue
        }
        if digest != expected {
          findings.append(Finding(severity: .error,
                                  path: relative(url.appendingPathComponent(path), to: bundle),
                                  reason: "the file differs from the repository's tracer data, so its "
                                    + "content is not ours"))
        }
      }
    }

    if dataDirectories.isEmpty {
      findings.append(Finding(severity: .warning, path: bundle.lastPathComponent,
                              reason: "no RimeData directory was found; a keyboard with no data cannot "
                                + "type at all"))
    }

    return Result(bundle: bundle.path, dataDirectories: dataDirectories.sorted(),
                  fileCount: fileCount, findings: findings)
  }

  static func relative(_ url: URL, to root: URL) -> String {
    let base = root.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    if path == base { return "." }
    return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
  }
}
