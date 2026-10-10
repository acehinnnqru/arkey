import Foundation

// MARK: - Local development data

/// S1-AC6: a Debug build may carry `RimeData.local/`, and the app starts with that profile installed. The
/// release check refuses the directory in a bundle (S6-AC3), so the two halves of the criterion are "it can
/// never ship" and "it installs when it is there" — this is the second one, kept in the engine so that it
/// can be tested without a build.
public enum RimeLocalDataInstaller {
  public static let directoryName = "RimeData.local"

  /// Imports the directory as a profile and activates it, then returns the profile id. Returns nil when
  /// there is nothing at `url`, and when the same tree is already the active profile: the id is
  /// content-addressed, so a Debug build that launches twenty times gets one profile, not twenty.
  ///
  /// Activation goes through the deployer rather than writing `active.json` by hand, because a profile is
  /// only usable once it has a build — the keyboard reads the deployed generation, not the sources.
  @discardableResult
  public static func installIfPresent(at url: URL,
                                      workspace: RimeWorkspace,
                                      engine: RimeEngine,
                                      displayName: String = RimeLocalization.text("Local data"),
                                      fileManager: FileManager = .default) throws -> String? {
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    let id = try RimeImporter(workspace: workspace, engine: engine)
      .import(payload: url,
              options: RimeImportOptions(displayName: displayName,
                                         origin: RimeProfileSource(kind: .files))).profileID
    if try workspace.loadActiveProfile()?.profileID == id { return nil }
    _ = try RimeDeploymentCoordinator(workspace: workspace, engine: engine).deploySync(profileID: id)
    return id
  }
}
