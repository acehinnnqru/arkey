import XCTest
import RimeEngine

/// The iOS build of librime, put through the app's first-run sequence: import the bundled profile, deploy it,
/// activate it, type a letter, and read the candidate back.
///
/// The package's tests cover this flow on macOS. The framework the app ships is a **different binary**, built
/// for iOS, and until this test nothing on this machine had asked it to load our own config at all — the
/// keyboard tests boot the engine but their workspace is undeployed, so they type into an empty session.
///
/// It runs in a workspace of its own under the temporary directory, so the keyboard's container is left
/// exactly as it was for the other tests.
final class RimeEngineDeployTests: XCTestCase {
  private var root = URL(fileURLWithPath: NSTemporaryDirectory())

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkey-deploy-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  func testTheBundledProfileDeploysOnIOSAndAnswersACandidate() throws {
    let bundled = try XCTUnwrap(RimeDirectories.bundledSharedDataURL(in: .main),
                                "the app bundle carries no RimeData")
    for file in ["default.yaml", "tracer.schema.yaml", "tracer.dict.yaml"] {
      XCTAssertTrue(FileManager.default.fileExists(atPath: bundled.appendingPathComponent(file).path),
                    "the bundled profile has no " + file)
    }

    // 1. Bootstrap, as the app does it. appGroupAvailable is "can this process see the workspace the app
    // writes": here it can, so the resolver looks for a deployed profile and finds none — which is the state
    // the keyboard is in before the app has ever run.
    let workspace = try RimeWorkspace(root: root.appendingPathComponent("rime", isDirectory: true),
                                      writableRoot: .custom).createDirectories()
    let sync = root.appendingPathComponent("sync", isDirectory: true)
    try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: true)
    _ = try workspace.seedInstallation(syncDirectory: sync)
    try workspace.applyStoragePolicy()

    let resolved = RimeWorkspaceResolver.resolve(workspace: workspace, bundledSharedData: bundled,
                                                 appGroupAvailable: true)
    XCTAssertNil(resolved.profileID, "nothing should be deployed yet")
    let engine = RimeEngine(configuration: RimeConfiguration(directories: resolved.directories))
    // No shutdown: librime's state is process-global, so finalising this engine would take the keyboard
    // tests' engine down with it — the language key stops resolving, which is how this was found (round 148).
    // Process exit is the boundary; the workspace is still removed by tearDown.
    _ = try engine.start()

    // 2. Import the profile from a folder — a clean copy of the three files the bundled tree ships, the same
    // shape the app's importer is given — then deploy and activate it. This is the step that makes the iOS
    // build of librime compile our schema, load our dictionary and answer with our candidate.
    let source = root.appendingPathComponent("profile", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    for file in ["default.yaml", "tracer.schema.yaml", "tracer.dict.yaml"] {
      try FileManager.default.copyItem(at: bundled.appendingPathComponent(file),
                                       to: source.appendingPathComponent(file))
    }
    let profileID = try RimeImporter(workspace: workspace, engine: engine)
      .import(payload: source,
              options: RimeImportOptions(displayName: "iOS deploy",
                                         origin: RimeProfileSource(kind: .files))).profileID
    let deployed = try RimeDeploymentCoordinator(workspace: workspace, engine: engine)
      .deploySync(profileID: profileID)
    XCTAssertTrue(deployed.report.succeeded, deployed.report.failureReason ?? "the deploy failed")
    XCTAssertEqual(try workspace.loadActiveProfile()?.profileID, profileID, "the deploy did not activate it")

    // 3. The keyboard appears: resolve again and adopt what the app wrote.
    let next = RimeWorkspaceResolver.resolve(workspace: workspace, bundledSharedData: bundled,
                                             appGroupAvailable: true)
    XCTAssertEqual(next.profileID, profileID, "the resolver does not see the deployed profile")
    _ = try engine.rebind(to: next.directories)
    try engine.openSession()

    // 4. Type. The tracer's 你好 is the first candidate for nihao.
    let output = try engine.processKeys("nihao")
    XCTAssertEqual(output.candidates.first?.text, "你好",
                   "the iOS engine answered: "
                     + output.candidates.map { $0.text }.joined(separator: ", "))
  }
}
