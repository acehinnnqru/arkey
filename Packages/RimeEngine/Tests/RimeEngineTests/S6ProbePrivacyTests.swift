import XCTest
@testable import RimeEngine

/// S6 §3: the probe log records phases, milliseconds and footprints — and never what the user typed.
/// That is a property of the log rather than of one call site, so it is checked against a live session
/// that types a distinctive string and commits a candidate.
final class S6ProbePrivacyTests: XCTestCase {
  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private var tracerData: URL { repositoryRoot.appendingPathComponent("RimeData", isDirectory: true) }

  private var scratch: URL!
  private var workspace: RimeWorkspace!
  private var engine: RimeEngine!
  private var probeURL: URL!

  override func setUpWithError() throws {
    scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkey-s6-probe", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    workspace = try RimeWorkspace(root: scratch.appendingPathComponent("rime", isDirectory: true))
      .createDirectories()

    let source = scratch.appendingPathComponent("profile", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    for file in ["default.yaml", "tracer.schema.yaml", "tracer.dict.yaml"] {
      try FileManager.default.copyItem(at: tracerData.appendingPathComponent(file),
                                       to: source.appendingPathComponent(file))
    }

    probeURL = scratch.appendingPathComponent("probe.jsonl")
    let directories = RimeDirectories(sharedDataDir: tracerData.path,
                                      prebuiltDataDir: tracerData.appendingPathComponent("build").path,
                                      userDataDir: workspace.userData.path,
                                      stagingDir: workspace.staging.path,
                                      logDir: workspace.log.path)
    engine = RimeEngine(configuration: RimeConfiguration(directories: directories),
                        probeLog: RimeProbeLog(url: probeURL))
    _ = try engine.start()

    let importer = RimeImporter(workspace: workspace, engine: engine)
    let profileID = try importer.import(payload: source,
                                        options: RimeImportOptions(displayName: "Tracer",
                                                                   origin: RimeProfileSource(kind: .files))).profileID
    _ = try RimeDeploymentCoordinator(workspace: workspace, engine: engine).deploySync(profileID: profileID)
  }

  override func tearDownWithError() throws {
    engine?.shutdown()
    try? FileManager.default.removeItem(at: scratch)
  }

  /// S2 §5.5's record: the config, the key, and both sides of the change.
  func testAConfigChangeIsOneProbeLineWithItsKeyAndBothValues() throws {
    let change = RimeConfigChange(configID: "tracer", key: "menu/page_size",
                                  oldValue: .int(5), newValue: .int(7))
    let record = RimeProbeRecord.configApplied(change)
    XCTAssertEqual(record.phase, "config.applied")
    let message = try XCTUnwrap(record.message)
    XCTAssertTrue(message.contains("tracer"), message)
    XCTAssertTrue(message.contains("menu/page_size"), message)
    XCTAssertTrue(message.contains("5") && message.contains("7"),
                  "both sides of the change: " + message)
  }

  /// The invariant, against a live session: type, commit, and then read every byte the engine wrote.
  func testTheProbeNeverRecordsWhatTheUserTyped() throws {
    try engine.openSession()
    _ = try engine.processKeys("shurufa")
    _ = try engine.selectCandidate(at: 0)
    engine.closeSession()

    let text = try String(contentsOf: probeURL, encoding: .utf8)
    XCTAssertFalse(text.isEmpty, "the log has to be written for this check to mean anything")
    XCTAssertTrue(text.contains("engine.start"),
                  "an engine phase is the positive control: " + text)
    XCTAssertFalse(text.contains("shurufa"), "the raw input reached the probe log:\n" + text)
    XCTAssertFalse(text.contains("输入法"), "the committed candidate reached the probe log:\n" + text)

    // Every line is one record with only the fields the type declares — no place for a keystroke to
    // hide, and a new field cannot appear without this test being updated on purpose.
    let allowed: Set<String> = ["timestamp", "phase", "milliseconds", "footprintBytes", "message"]
    for line in text.split(separator: "\n") where !line.isEmpty {
      let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                                 "not a JSON object: " + line)
      XCTAssertEqual(Set(object.keys).subtracting(allowed), [], "unexpected field in " + line)
      XCTAssertNotNil(object["phase"] as? String, "no phase in " + line)
    }

    let records = RimeProbeLog(url: probeURL).readAll()
    XCTAssertTrue(records.contains { $0.phase == "engine.start" })
    XCTAssertFalse(records.contains { ($0.message ?? "").contains("shurufa") })
  }
}
