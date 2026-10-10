import XCTest
@testable import RimeEngine

/// S6-AC5: networking is confined to the host's explicit download service.
/// The keyboard extension and shared engine cannot acquire configurations themselves.
final class S6NetworkTests: XCTestCase {
  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  /// Every place our code lives. The tests are left out on purpose: a test may talk about these names.
  private static let sourceDirectories = ["Packages/RimeEngine/Sources", "arkey", "ARKeyboard", "KeyboardUI"]

  private static let forbidden = ["URLSession", "URLRequest", "NSURLConnection", "NSURLSession",
                                  "WKWebView", "SFSafariViewController", "dataTask", "NWConnection",
                                  "CFNetwork", "CFHTTP", "getaddrinfo", "NWPathMonitor"]

  func testNetworkAPIsAreConfinedToTheExplicitHostDownloader() throws {
    let fileManager = FileManager.default
    var findings: [String] = []
    var scanned = 0

    for directory in Self.sourceDirectories {
      let root = repositoryRoot.appendingPathComponent(directory, isDirectory: true)
      guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) else {
        continue
      }
      for case let url as URL in enumerator where url.pathExtension == "swift" {
        scanned += 1
        // User-initiated acquisition is the only allowed networking implementation. In particular,
        // the shared engine package and keyboard extension continue to have no networking APIs.
        if url.lastPathComponent == "RimeProfileDownloader.swift", directory == "arkey" { continue }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
          let line = Self.withoutComment(String(raw))
          for api in Self.forbidden where line.contains(api) {
            findings.append(url.lastPathComponent + ":" + String(index + 1) + " uses " + api)
          }
        }
      }
    }

    XCTAssertGreaterThan(scanned, 50, "the scan has to have found the sources")
    XCTAssertEqual(findings, [], findings.joined(separator: "; "))
  }

  /// Drops a line comment, and nothing else: a URL in a string literal contains "//" too, and cutting the
  /// line at it would hide whatever follows.
  private static func withoutComment(_ line: String) -> String {
    guard let range = line.range(of: "//") else { return line }
    let before = line[line.startIndex..<range.lowerBound]
    if before.hasSuffix(":") { return line }
    return String(before)
  }
}
