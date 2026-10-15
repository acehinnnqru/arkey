import Foundation
import RimeEngine

/// The keyboard process owns exactly one librime instance: librime keeps process-global state,
/// so the controller reuses this engine rather than building its own.
///
/// S1 §8 lives here: the extension reads `active.json` at every appearance and adopts a profile
/// change before the first keystroke, never during a composition.
enum KeyboardEngine {
  static let appGroupID = "group.com.acehinnnqru.arkey"

  /// Reference type on purpose: `resolved` changes when the app activates another profile, and the
  /// controller holds this object for the life of the process.
  final class Setup {
    let engine: RimeEngine
    let probe: RimeProbeLog?
    let workspace: RimeWorkspace
    let bundledSharedData: URL
    let lease: RimeLeaseStore
    var resolved: RimeResolvedProfile
    private let inputOwnerLock = NSLock()
    private var inputOwner: UUID?

    func claimInputSession(owner: UUID) {
      inputOwnerLock.lock()
      defer { inputOwnerLock.unlock() }
      inputOwner = owner
    }

    func inputSessionBelongsToAnotherController(_ owner: UUID) -> Bool {
      inputOwnerLock.lock()
      defer { inputOwnerLock.unlock() }
      return inputOwner != nil && inputOwner != owner
    }

    func ownsInputSession(_ owner: UUID) -> Bool {
      inputOwnerLock.lock()
      defer { inputOwnerLock.unlock() }
      return inputOwner == owner
    }

    /// A retiring controller must not shut down the next controller's shared engine.
    func releaseInputSession(owner: UUID) {
      inputOwnerLock.lock()
      defer { inputOwnerLock.unlock() }
      guard inputOwner == owner else { return }
      inputOwner = nil
      engine.shutdown()
    }

    init(engine: RimeEngine, probe: RimeProbeLog?, workspace: RimeWorkspace,
         bundledSharedData: URL, lease: RimeLeaseStore, resolved: RimeResolvedProfile) {
      self.engine = engine
      self.probe = probe
      self.workspace = workspace
      self.bundledSharedData = bundledSharedData
      self.lease = lease
      self.resolved = resolved
    }
  }

  /// Resolved once per process. Failures are surfaced, not swallowed: on a device the candidate
  /// bar is the only place a user can read them, and the probe log is the only place we can.
  static let setup: Result<Setup, Error> = makeSetup()

  enum InputSessionError: Error, CustomStringConvertible {
    case noUsableSchema([String])

    var description: String {
      switch self {
      case .noUsableSchema(let schemas):
        return "No usable input schema. Open Arkey and redeploy the active profile. Enabled schemas: "
          + (schemas.isEmpty ? "none" : schemas.joined(separator: ", "))
      }
    }
  }

  /// Creating a Rime session can succeed with a placeholder or a named schema whose
  /// compiled configuration is missing. Both decline letters even when ascii_mode is false.
  /// Recover an enabled schema
  /// before reporting the keyboard as ready; never deploy inside the extension.
  @discardableResult
  static func ensureInputSchema(_ engine: RimeEngine) throws -> RimeStatusSnapshot {
    func usable(_ status: RimeStatusSnapshot?) -> Bool {
      guard let status, let id = status.schemaID else { return false }
      return !status.isDisabled && !id.isEmpty && id != ".default"
        && (try? engine.hasInputProcessors(schemaID: id)) == true
    }
    let current = try engine.refresh().status
    if let current, usable(current) { return current }
    let schemas = try engine.schemaIDs().filter { !$0.isEmpty && $0 != ".default" }
    for id in schemas {
      if let status = try? engine.selectSchema(id).status, usable(status) { return status }
    }
    throw InputSessionError.noUsableSchema(schemas)
  }

  private static func makeSetup() -> Result<Setup, Error> {
    do {
      guard let shared = RimeDirectories.bundledSharedDataURL() else {
        throw RimeEngineError.dataDirectoryMissing("RimeData is missing from the app bundle")
      }
      // Without Full Access the extension can still read the app group, so the workspace resolves
      // and the profile loads. What it cannot do is write, which is S5's degraded mode, not S1's.
      let workspace = RimeWorkspace.locate(appGroupID: appGroupID)
      _ = try? workspace.createDirectories()
      let resolved = RimeWorkspaceResolver.resolve(
        workspace: workspace,
        bundledSharedData: shared,
        appGroupAvailable: workspace.writableRoot == .appGroup)
      let probeURL = workspace.log.appendingPathComponent("probe.jsonl")
      let probe = RimeProbeLog(url: probeURL)
      // min_log_level 0: glog filters before any sink sees a record, and a deploy failure with no
      // captured text is a failure nobody can diagnose.
      let engine = RimeEngine(configuration: RimeConfiguration(directories: resolved.directories,
                                                               minLogLevel: 0),
                              probeLog: probe,
                              dictionaryLeaseStore: RimeLeaseStore(workspace: workspace),
                              dictionaryHost: "keyboard")
      return .success(Setup(engine: engine, probe: probe, workspace: workspace,
                            bundledSharedData: shared,
                            lease: RimeLeaseStore(workspace: workspace),
                            resolved: resolved))
    } catch {
      return .failure(error)
    }
  }

  /// Reads `active.json` and rebinds when the profile or the generation changed.
  ///
  /// The order is S1 §8's: never mid-composition, one rebind, and if the rebind fails fall back to
  /// the bundle rather than leaving the keyboard with no engine at all.
  @discardableResult
  static func adoptProfileIfNeeded(_ setup: Setup, isComposing: Bool) -> RimeResolvedProfile {
    let resolved = RimeWorkspaceResolver.resolve(workspace: setup.workspace,
                                                bundledSharedData: setup.bundledSharedData)

    // The *rule* is the engine's (RimeProfileAdoption), so "never mid-composition" is a tested statement
    // rather than a comment here; this switch only carries it out.
    let target: RimeResolvedProfile
    switch RimeProfileAdoption.decide(resolved: resolved, current: setup.resolved,
                                      isComposing: isComposing) {
    case .unchanged:
      setup.resolved = resolved
      return resolved
    case .deferred:
      setup.probe?.append(RimeProbeRecord(phase: "keyboard.adopt.deferred",
                                          message: "a composition is in progress; deferring to the next "
                                            + "appearance"))
      return setup.resolved
    case .rebind(let next):
      target = next
    }

    let started = DispatchTime.now().uptimeNanoseconds
    do {
      _ = try setup.engine.rebind(to: target.directories)
      try setup.engine.openSession()
      setup.resolved = target
      let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
      let message = "adopted profile=" + (target.profileID ?? "bundled")
        + " generation=" + String(target.generation ?? 0)
        + " origin=" + target.origin.rawValue
      setup.probe?.append(RimeProbeRecord(phase: "keyboard.boot", milliseconds: milliseconds,
                                          message: message))
      return resolved
    } catch {
      let fallback = RimeWorkspaceResolver.resolve(workspace: setup.workspace,
                                                   bundledSharedData: setup.bundledSharedData,
                                                   appGroupAvailable: false)
      _ = try? setup.engine.rebind(to: fallback.directories)
      _ = try? setup.engine.openSession()
      setup.resolved = fallback
      setup.probe?.append(RimeProbeRecord(phase: "keyboard.adopt.failed",
                                          message: String(describing: error)))
      return fallback
    }
  }

  /// Short status for the candidate bar. Deliberately not an error-looking string when things
  /// are fine, because it is the first thing a user sees when the keyboard comes up.
  static func statusLine(_ setup: Setup, hasFullAccess: Bool) -> String {
    let container = setup.workspace.writableRoot == .appGroup ? RimeLocalization.text("Shared container") : RimeLocalization.text("Extension container")
    let profile: String
    switch setup.resolved.origin {
    case .bundled:
      profile = RimeLocalization.text("Built-in data")
    case .appGroup, .container:
      profile = setup.resolved.profileID ?? RimeLocalization.text("Profile")
    }
    var line = RimeLocalization.text("Arkey ready · \(container) · Full Access \((hasFullAccess ? RimeLocalization.text("On") : RimeLocalization.text("Off"))) · \(profile)")
    // S1 §9: a degraded activation says so where the user is already looking, and names the repair. The
    // keyboard cannot deploy, so the message points at the app — which reads the same table.
    if let recovery = RimeProfileRecovery.of(setup.resolved) {
      line += " · " + recovery.message
    }
    return line
  }

  /// Full detail for the probe log and the system log.
  static func detail(_ setup: Setup, hasFullAccess: Bool) -> String {
    let directories = setup.resolved.directories
    var parts = ["librime=" + RimeEngine.librimeVersion]
    parts.append("fullAccess=" + String(hasFullAccess))
    parts.append("root=" + directories.writableRoot.rawValue)
    parts.append("origin=" + setup.resolved.origin.rawValue)
    parts.append("profile=" + (setup.resolved.profileID ?? "bundled"))
    parts.append("generation=" + String(setup.resolved.generation ?? 0))
    if let status = try? setup.engine.refresh().status {
      parts.append("schema=" + (status.schemaID ?? "none"))
      parts.append("asciiMode=" + String(status.isAsciiMode))
      parts.append("disabled=" + String(status.isDisabled))
    }
    if let reason = setup.resolved.fallbackReason {
      parts.append("fallback=" + reason)
    }
    parts.append("groupID=" + (directories.appGroupID ?? "none"))
    parts.append("container=" + (directories.containerPath ?? "unresolved"))
    parts.append("home=" + directories.homePath)
    parts.append("shared=" + directories.sharedDataDir)
    parts.append("prebuilt=" + directories.prebuiltDataDir)
    parts.append("user=" + directories.userDataDir)
    return parts.joined(separator: " ")
  }
}
