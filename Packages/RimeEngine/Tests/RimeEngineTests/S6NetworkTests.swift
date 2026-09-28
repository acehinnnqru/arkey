import XCTest
@testable import RimeEngine

/// S6-AC5: "the only network use is the download the user starts" — and today there is no network use of
/// our own at all. A sentence in a document cannot fail a build, so this is the claim as a check: every
/// Swift file under the engine, the app, the extension and the keyboard UI is scanned for the APIs that
/// would open a connection, and the failure names the file and the line.
///
/// The list is a decision rather than a heuristic. Adding one of these is exactly how a future download
/// would arrive, so the list is where that decision gets made deliberately: either the API is added here
/// with a reason (and the privacy manifest and the App Privacy answers change with it), or the request is
/// left out.
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

  func testNoSourceOpensANetworkConnection() throws {
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
