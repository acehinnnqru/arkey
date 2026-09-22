import Foundation
import RimeEngine

/// The keyboard process owns exactly one librime instance: librime keeps process-global state,
/// so the controller reuses this engine rather than building its own.
enum KeyboardEngine {
  static let appGroupID = "group.com.acehinnnqru.arkey"

  struct Setup {
    let engine: RimeEngine
    let directories: RimeDirectories
    let probe: RimeProbeLog?
  }

  /// Resolved once per process. Failures are surfaced, not swallowed: on a device the candidate
  /// bar is the only place a user can read them, and the probe log is the only place we can.
  static let setup: Result<Setup, Error> = makeSetup()

  private static func makeSetup() -> Result<Setup, Error> {
    do {
      guard let shared = RimeDirectories.bundledSharedDataURL() else {
        throw RimeEngineError.dataDirectoryMissing("RimeData is missing from the app bundle")
      }
      let directories = try RimeDirectories.resolve(appGroupID: appGroupID, sharedDataURL: shared)
      let probeURL = URL(fileURLWithPath: directories.logDir, isDirectory: true)
        .appendingPathComponent("probe.jsonl")
      let probe = RimeProbeLog(url: probeURL)
      let engine = RimeEngine(configuration: RimeConfiguration(directories: directories),
                              probeLog: probe)
      return .success(Setup(engine: engine, directories: directories, probe: probe))
    } catch {
      return .failure(error)
    }
  }

  /// Short status for the candidate bar. Deliberately not an error-looking string when things
  /// are fine, because it is the first thing a user sees when the keyboard comes up.
  static func statusLine(_ setup: Setup, hasFullAccess: Bool) -> String {
    let container = setup.directories.writableRoot == .appGroup ? "共享容器" : "扩展容器"
    return "Arkey 就绪 · " + container + " · 完全访问" + (hasFullAccess ? "开" : "关")
  }

  /// Full detail for the probe log and the system log.
  static func detail(_ setup: Setup, hasFullAccess: Bool) -> String {
    let directories = setup.directories
    var parts = ["librime=" + RimeEngine.librimeVersion]
    parts.append("fullAccess=" + String(hasFullAccess))
    parts.append("root=" + directories.writableRoot.rawValue)
    parts.append("groupID=" + (directories.appGroupID ?? "none"))
    parts.append("container=" + (directories.containerPath ?? "unresolved"))
    parts.append("home=" + directories.homePath)
    parts.append("shared=" + directories.sharedDataDir)
    parts.append("prebuilt=" + directories.prebuiltDataDir)
    parts.append("user=" + directories.userDataDir)
    return parts.joined(separator: " ")
  }
}
