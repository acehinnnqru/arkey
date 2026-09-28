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

  /// S6 §3's other added record: which profile and generation the app moved the keyboard to.
  func testAProfileActivationIsOneProbeLine() throws {
    let record = RimeProbeRecord.profileActivated(profileID: "rime-ice-2", generation: 7)
    XCTAssertEqual(record.phase, "profile.activate")
    let message = try XCTUnwrap(record.message)
    XCTAssertTrue(message.contains("rime-ice-2"), message)
    XCTAssertTrue(message.contains("7"), "the generation belongs in the line: " + message)

    XCTAssertEqual(RimeProbeRecord.profileActivated(profileID: "tracer", generation: nil).message,
                   "tracer", "a profile that has never been deployed has no generation to name")
  }

  /// The probe log has two writers in two processes — the keyboard extension and the app — so an append
  /// has to be one at the OS level, not a seek-to-end plus a write. This drives several instances from
  /// several threads at once and requires every line to survive: with the seek-based version, writers
  /// that seek to the same offset overwrite each other's record.
  func testConcurrentAppendsFromManyWritersAllSurvive() throws {
    let writers = 6
    let perWriter = 40
    let group = DispatchGroup()
    for writer in 0..<writers {
      DispatchQueue.global().async(group: group) {
        // A separate instance each time, the way a second process would have one.
        let log = RimeProbeLog(url: self.probeURL)
        for index in 0..<perWriter {
          log.append(RimeProbeRecord(phase: "writer.\(writer)",
                                     message: String(index)))
        }
      }
    }
    XCTAssertEqual(group.wait(timeout: .now() + 30), .success)

    let records = RimeProbeLog(url: probeURL).readAll()
    let written = records.filter { $0.phase.hasPrefix("writer.") }
    XCTAssertEqual(written.count, writers * perWriter,
                   "lines were lost or overwritten: \(written.count) of \(writers * perWriter)")
    let perWriterSeen = Dictionary(grouping: written, by: \.phase).mapValues { $0.count }
    XCTAssertEqual(Set(perWriterSeen.values), [perWriter], "every writer's lines are all there")
    for (phase, entries) in Dictionary(grouping: written, by: \.phase) {
      XCTAssertEqual(Set(entries.compactMap(\.message)).count, perWriter,
                     phase + " lost distinct messages")
    }
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
