import XCTest
import RimeEngine

private final class ProfileDownloadProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let status = Int(request.url!.lastPathComponent) ?? 200
    let data = request.url!.path.contains("/empty/") ? Data() : Data(repeating: 65, count: 4096)
    let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
      headerFields: ["Content-Length": String(data.count)])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

final class ProfileDownloaderTests: XCTestCase {
  func testSuccessfulTransferProducesTheArchiveAndResolvedURL() async throws {
    let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
    defer { try? FileManager.default.removeItem(at: destination) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ProfileDownloadProtocol.self]
    let url = URL(string: "https://example.invalid/archive")!
    let resolved = try await RimeProfileDownloader(destination: destination, maxBytes: 8192,
      configuration: configuration).fetch(url)
    XCTAssertEqual(resolved, url.absoluteString)
    XCTAssertEqual(try Data(contentsOf: destination), Data(repeating: 65, count: 4096))
  }

  func testHTTPFailureAndSizeLimitLeaveNoPayload() async throws {
    for (path, limit) in [("/404", 8192), ("/500", 8192), ("/502", 8192),
                          ("/503", 8192), ("/empty/500", 8192), ("/empty/502", 8192),
                          ("/archive", 1024)] {
      let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
      defer { try? FileManager.default.removeItem(at: destination) }
      let configuration = URLSessionConfiguration.ephemeral
      configuration.protocolClasses = [ProfileDownloadProtocol.self]
      do {
        _ = try await RimeProfileDownloader(destination: destination, maxBytes: limit,
          configuration: configuration).fetch(URL(string: "https://example.invalid" + path)!)
        XCTFail("the transfer should fail")
      } catch {
        if let status = Int(URL(string: path)!.lastPathComponent) {
          guard case RimeProfileDownloadError.http(let actual) = error else { return XCTFail("unexpected error: \(error)") }
          XCTAssertEqual(actual, status)
        } else {
          guard case RimeCatalogError.tooLarge = error else { return XCTFail("unexpected error: \(error)") }
        }
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
  }
}
