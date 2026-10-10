import Foundation
import RimeEngine

enum RimeProfileDownloadError: Error, CustomStringConvertible {
  case http(Int)
  case releaseUnavailable
  case digestMismatch
  case invalidResponse

  var description: String {
    switch self {
    case .http(let status): return "Download server returned HTTP \(status)"
    case .releaseUnavailable: return "No matching release with full.zip was found"
    case .digestMismatch: return "The archive does not match the release asset SHA-256 digest"
    case .invalidResponse: return "The server did not return an HTTPS HTTP response"
    }
  }
}

/// One bounded transfer per instance. Only the host app instantiates this service after a user action.
/// Ephemeral sessions avoid persisting cookies and caches, and redirects may not downgrade to HTTP.
final class RimeProfileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  private let destination: URL
  private let maxBytes: Int
  private let configuration: URLSessionConfiguration
  private let progress: @Sendable (Int64, Int64) -> Void
  private let lock = NSLock()
  private var continuation: CheckedContinuation<String, Error>?
  private var session: URLSession?
  private var failure: Error?
  private var task: URLSessionDownloadTask?
  private var cancelled = false

  init(destination: URL, maxBytes: Int, configuration: URLSessionConfiguration = .ephemeral,
       progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) {
    self.destination = destination
    self.maxBytes = maxBytes
    self.configuration = configuration
    self.progress = progress
  }

  func fetch(_ url: URL, githubAPI: Bool = false) async throws -> String {
    _ = try RimeDownloadURL.validate(url.absoluteString)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        lock.lock()
        self.continuation = continuation
        let configuration = self.configuration
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        var request = URLRequest(url: url)
        request.setValue("Arkey", forHTTPHeaderField: "User-Agent")
        if githubAPI { request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept") }
        let task = session.downloadTask(with: request)
        self.task = task
        let cancelled = self.cancelled
        lock.unlock()
        task.resume()
        if cancelled { task.cancel() }
      }
    } onCancel: {
      self.lock.lock()
      self.cancelled = true
      let task = self.task
      self.lock.unlock()
      task?.cancel()
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask,
                  willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest,
                  completionHandler: @escaping (URLRequest?) -> Void) {
    guard let url = request.url, (try? RimeDownloadURL.validate(url.absoluteString)) != nil else {
      failure = RimeProfileDownloadError.invalidResponse
      completionHandler(nil)
      task.cancel()
      return
    }
    completionHandler(request)
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                  didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                  totalBytesExpectedToWrite: Int64) {
    if totalBytesWritten > maxBytes || totalBytesExpectedToWrite > maxBytes {
      failure = RimeCatalogError.tooLarge(Int(max(totalBytesWritten, totalBytesExpectedToWrite)), maxBytes)
      downloadTask.cancel()
    } else {
      progress(totalBytesWritten, totalBytesExpectedToWrite)
    }
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                  didFinishDownloadingTo location: URL) {
    do {
      guard failure == nil else { return }
      guard let response = downloadTask.response as? HTTPURLResponse,
            let url = response.url, (try? RimeDownloadURL.validate(url.absoluteString)) != nil else {
        throw RimeProfileDownloadError.invalidResponse
      }
      guard response.statusCode == 200 else { throw RimeProfileDownloadError.http(response.statusCode) }
      let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard size <= maxBytes else { throw RimeCatalogError.tooLarge(size, maxBytes) }
      try FileManager.default.moveItem(at: location, to: destination)
    } catch { failure = error }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    lock.lock()
    let continuation = self.continuation
    self.continuation = nil
    self.task = nil
    self.session = nil
    lock.unlock()
    session.finishTasksAndInvalidate()
    if let error = failure ?? error {
      try? FileManager.default.removeItem(at: destination)
      continuation?.resume(throwing: error)
    } else if let url = task.response?.url {
      continuation?.resume(returning: url.absoluteString)
    } else {
      continuation?.resume(throwing: RimeProfileDownloadError.invalidResponse)
    }
  }

  static func release(channel: RimeGitHubReleaseChannel, staging: URL) async throws -> RimeGitHubRelease {
    // Follow pages when necessary so a busy nightly history cannot hide the newest stable release.
    for page in 1...10 {
      let file = staging.appendingPathComponent("release-\(page).json")
      _ = try await RimeProfileDownloader(destination: file, maxBytes: 8 << 20)
        .fetch(channel.apiURL(page: page), githubAPI: true)
      let data = try Data(contentsOf: file)
      if let release = try RimeGitHubRelease.select(from: data, channel: channel) { return release }
      if channel == .nightly { break }
      let count = (try JSONSerialization.jsonObject(with: data) as? [Any])?.count ?? 0
      if count < 100 {
        break
      }
    }
    throw RimeProfileDownloadError.releaseUnavailable
  }
}
