import Foundation

/// Where librime reads and writes. Split by mutability, not by convenience:
/// the app bundle is read-only, the container is not, and a keyboard extension only gets the
/// app group container when the user grants full access.
public struct RimeDirectories: Sendable, Equatable {
  public enum WritableRoot: String, Sendable {
    case appGroup
    case container
    case custom
  }

  public let sharedDataDir: String
  public let prebuiltDataDir: String
  public let userDataDir: String
  public let stagingDir: String
  public let logDir: String
  public let writableRoot: WritableRoot
  public let appGroupID: String?
  public let containerPath: String?
  public let homePath: String

  public init(sharedDataDir: String,
              prebuiltDataDir: String,
              userDataDir: String,
              stagingDir: String,
              logDir: String,
              writableRoot: WritableRoot = .custom,
              appGroupID: String? = nil,
              containerPath: String? = nil,
              homePath: String = NSHomeDirectory()) {
    self.sharedDataDir = sharedDataDir
    self.prebuiltDataDir = prebuiltDataDir
    self.userDataDir = userDataDir
    self.stagingDir = stagingDir
    self.logDir = logDir
    self.writableRoot = writableRoot
    self.appGroupID = appGroupID
    self.containerPath = containerPath
    self.homePath = homePath
  }

  /// RimeData as shipped inside the app bundle.
  public static func bundledSharedDataURL(in bundle: Bundle = .main) -> URL? {
    guard let resources = bundle.resourceURL else { return nil }
    return resources.appendingPathComponent("RimeData", isDirectory: true)
  }

  /// Resolves the writable root and creates the directories librime needs.
  /// Returns the app group container when the entitlement resolved, otherwise the process's
  /// own container; the caller records which one it got.
  public static func resolve(appGroupID: String?,
                             sharedDataURL: URL,
                             fileManager: FileManager = .default) throws -> RimeDirectories {
    var root: URL
    var writableRoot: WritableRoot = .container
    var containerPath: String?
    if let appGroupID,
       let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
      root = container.appendingPathComponent("rime", isDirectory: true)
      writableRoot = .appGroup
      containerPath = container.path
    } else {
      let base = try fileManager.url(for: .applicationSupportDirectory,
                                     in: .userDomainMask,
                                     appropriateFor: nil,
                                     create: true)
      root = base.appendingPathComponent("rime", isDirectory: true)
    }

    let userData = root.appendingPathComponent("user", isDirectory: true)
    let staging = root.appendingPathComponent("staging", isDirectory: true)
    let logs = root.appendingPathComponent("log", isDirectory: true)
    for directory in [root, userData, staging, logs] {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    let bundledBuild = sharedDataURL.appendingPathComponent("build", isDirectory: true)
    let prebuilt: URL
    if fileManager.fileExists(atPath: bundledBuild.path) {
      prebuilt = bundledBuild
    } else {
      // Nothing prebuilt: librime will have to deploy into the writable staging directory.
      prebuilt = staging
    }

    try? fileManager.createDirectory(atPath: prebuilt.path, withIntermediateDirectories: true)

    return RimeDirectories(sharedDataDir: sharedDataURL.path,
                           prebuiltDataDir: prebuilt.path,
                           userDataDir: userData.path,
                           stagingDir: staging.path,
                           logDir: logs.path,
                           writableRoot: writableRoot,
                           appGroupID: appGroupID,
                           containerPath: containerPath)
  }
}
