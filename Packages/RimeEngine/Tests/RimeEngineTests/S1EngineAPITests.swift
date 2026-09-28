import XCTest
@testable import RimeEngine

/// S1 §4: the engine surface the profile layer is built on.
///
/// Each test here settles an assumption the spec marks [verify], so that the design above it is
/// never built on a guess: the logsink module, the levers module, list patches through
/// `config_set_item`, and rebinding one process between two sets of directories.
final class S1EngineAPITests: XCTestCase {
  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private var tracerData: URL {
    repositoryRoot.appendingPathComponent("RimeData", isDirectory: true)
  }

  /// The progress callback runs on the deploy's own queue, so the test collects phases behind a lock.
  private final class PhaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RimeDeploymentProgress.Phase] = []
    func append(_ phase: RimeDeploymentProgress.Phase) {
      lock.lock()
      defer { lock.unlock() }
      storage.append(phase)
    }
    var all: [RimeDeploymentProgress.Phase] {
      lock.lock()
      defer { lock.unlock() }
      return storage
    }
  }

  private final class Scratch {
    let root: URL
    init() throws {
      root = FileManager.default.temporaryDirectory
        .appendingPathComponent("arkey-s1-engine", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    /// S1 §6: a profile is deployed with its `build.staging` as both the prebuilt directory and
    /// the staging directory, so librime's deployer writes the tables where the client reads them.
    func directories(shared: URL, build: String = "build") throws -> RimeDirectories {
      let buildURL = root.appendingPathComponent(build, isDirectory: true)
      let user = root.appendingPathComponent("user", isDirectory: true)
      let unpack = root.appendingPathComponent("unpack", isDirectory: true)
      for directory in [buildURL, user, unpack] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      }
      return RimeDirectories(sharedDataDir: shared.path,
                             prebuiltDataDir: buildURL.path,
                             userDataDir: user.path,
                             stagingDir: buildURL.path,
                             logDir: root.appendingPathComponent("log", isDirectory: true).path)
    }
  }

  /// The modules the deploy path leans on, checked rather than assumed.
  func testModulesTheDeployPathNeedsArePresent() {
    XCTAssertEqual(RimeEngine.librimeVersion, "1.17.0")
    XCTAssertTrue(RimeEngine.isLogSinkAvailable, "the logsink module is how a deploy failure carries librime's own text")
    XCTAssertTrue(RimeEngine.isLeversAvailable, "the levers module owns user-dictionary export and backup")
  }

  func testDeployReportsProgressNotificationsAndFiles() throws {
    let scratch = try Scratch()
    let directories = try scratch.directories(shared: tracerData)
    // min_log_level 0 = INFO. glog filters before the sink sees a record, which is why the
    // tracer's default of 2 (ERROR) would make a successful deploy look like a silent one.
    let engine = RimeEngine(configuration: RimeConfiguration(directories: directories, minLogLevel: 0))
    _ = try engine.start()

    let phases = PhaseRecorder()
    let report = try engine.deploySync(binding: directories, fullCheck: true) { progress in
      phases.append(progress.phase)
    }

    XCTAssertTrue(report.succeeded)
    XCTAssertEqual(report.failureReason, nil)
    XCTAssertGreaterThan(report.duration, 0)
    XCTAssertTrue(report.files.contains { $0.relativePath.hasSuffix(".bin") },
                  "a deploy should have produced compiled tables, got \(report.files.map(\.relativePath))")
    XCTAssertTrue(report.files.contains { $0.relativePath == "tracer.table.bin" })

    // The notification handler is the progress source, so a deploy without deploy/start and
    // deploy/success would leave the deploy screen with nothing to show.
    XCTAssertTrue(report.notifications.contains(.deploy(.start)),
                  "expected deploy/start, got \(report.notifications)")
    XCTAssertTrue(report.notifications.contains(.deploy(.success)),
                  "expected deploy/success, got \(report.notifications)")
    XCTAssertEqual(phases.all.first, .binding)
    XCTAssertTrue(phases.all.contains(.running))
    XCTAssertEqual(phases.all.last, .succeeded)

    // The logsink module is what makes a failure legible.
    XCTAssertFalse(engine.logBuffer.snapshot().isEmpty, "the logsink captured nothing during a deploy")
    engine.shutdown()
  }

  /// The claim that de-risks profile switching: one process can move between two data
  /// directories with finalize + setup + initialize, and both type the right thing.
  func testRebindBetweenTwoProfilesTypesWithEach() throws {
    let scratch = try Scratch()
    let first = try scratch.directories(shared: tracerData, build: "build-a")

    // A second profile with the same shape but a different dictionary entry.
    let secondSource = scratch.root.appendingPathComponent("second-source", isDirectory: true)
    try FileManager.default.createDirectory(at: secondSource, withIntermediateDirectories: true)
    for name in ["default.yaml", "tracer.schema.yaml", "tracer.dict.yaml"] {
      try FileManager.default.copyItem(at: tracerData.appendingPathComponent(name),
                                       to: secondSource.appendingPathComponent(name))
    }
    let dictionary = try String(contentsOf: secondSource.appendingPathComponent("tracer.dict.yaml"),
                                encoding: .utf8)
    try dictionary.replacingOccurrences(of: "你好\tni hao", with: "你好\tni hao")
      .write(to: secondSource.appendingPathComponent("tracer.dict.yaml"), atomically: true, encoding: .utf8)
    let second = try scratch.directories(shared: secondSource, build: "build-b")

    let engine = RimeEngine(configuration: RimeConfiguration(directories: first))
    _ = try engine.deploySync(binding: first, fullCheck: true)
    try engine.openSession()
    XCTAssertEqual(try engine.processKeys("nihao").candidates.first?.text, "你好")
    engine.closeSession()

    _ = try engine.deploySync(binding: second, fullCheck: true)
    try engine.openSession()
    XCTAssertEqual(try engine.processKeys("nihao").candidates.first?.text, "你好")
    XCTAssertEqual(engine.directories.sharedDataDir, secondSource.path)

    engine.closeSession()
    _ = try engine.rebind(to: first)
    try engine.openSession()
    XCTAssertEqual(try engine.processKeys("nihao").candidates.first?.text, "你好")
    XCTAssertEqual(engine.directories.sharedDataDir, tracerData.path)
    engine.shutdown()
  }

  /// S1 §4 and S2 §2: a patch is written through librime's own config API, and the next deploy
  /// makes it visible at runtime.
  func testPageSizePatchThroughUserConfigChangesTheDeployedValue() throws {
    let scratch = try Scratch()
    let directories = try scratch.directories(shared: tracerData)
    let engine = RimeEngine(configuration: RimeConfiguration(directories: directories))
    _ = try engine.deploySync(binding: directories, fullCheck: true)

    XCTAssertEqual(try engine.withConfig("default") { $0.int("menu/page_size") }, 5)

    let before = try engine.withUserConfig("default.custom") { $0.value("patch/menu/page_size") }
    XCTAssertNil(before, "a fresh user directory has no patch")

    try engine.withUserConfig("default.custom") { config in
      XCTAssertTrue(config.set(.int(7), at: "patch/menu/page_size"))
    }

    let patchFile = URL(fileURLWithPath: directories.userDataDir)
      .appendingPathComponent("default.custom.yaml")
    let text = try String(contentsOf: patchFile, encoding: .utf8)
    XCTAssertTrue(text.contains("page_size"), "the patch file should name the key, got: \(text)")
    XCTAssertTrue(text.contains("7"), "the patch file should carry the value, got: \(text)")

    _ = try engine.deploySync(binding: directories, fullCheck: true)
    XCTAssertEqual(try engine.withConfig("default") { $0.int("menu/page_size") }, 7)
    engine.shutdown()
  }

  /// S2 §2.1 marks this [verify]: a list or a map is written by loading a YAML fragment into a
  /// detached config and copying the item into the patch.
  func testListItemPatchThroughConfigSetItem() throws {
    let scratch = try Scratch()
    let directories = try scratch.directories(shared: tracerData)
    let engine = RimeEngine(configuration: RimeConfiguration(directories: directories))
    _ = try engine.deploySync(binding: directories, fullCheck: true)
    XCTAssertEqual(try engine.schemaIDs(), ["tracer"])

    let fragment = try engine.configFromYAML("""
    schema_list:
      - schema: tracer
      - schema: tracer
    """)

    try engine.withUserConfig("default.custom") { config in
      XCTAssertTrue(config.setItem(from: fragment, sourceKey: "schema_list", key: "patch/schema_list"),
                    "config_set_item could not copy the list into the patch")
    }
    fragment.close()

    let patchFile = URL(fileURLWithPath: directories.userDataDir)
      .appendingPathComponent("default.custom.yaml")
    let text = try String(contentsOf: patchFile, encoding: .utf8)
    XCTAssertTrue(text.contains("schema_list"), "the patch should hold the list, got: \(text)")

    _ = try engine.deploySync(binding: directories, fullCheck: true)
    XCTAssertEqual(try engine.schemaIDs(), ["tracer", "tracer"])
    engine.shutdown()
  }

  /// Lists can also be written by path, which is the fallback S2 names if config_set_item
  /// misbehaves.
  func testListItemPatchThroughPathSyntax() throws {
    let scratch = try Scratch()
    let directories = try scratch.directories(shared: tracerData)
    let engine = RimeEngine(configuration: RimeConfiguration(directories: directories))
    _ = try engine.deploySync(binding: directories, fullCheck: true)

    try engine.withUserConfig("default.custom") { config in
      XCTAssertTrue(config.set(.list([.map(["schema": .string("tracer")])]), at: "patch/schema_list"))
    }
    _ = try engine.deploySync(binding: directories, fullCheck: true)
    XCTAssertEqual(try engine.schemaIDs(), ["tracer"])
    engine.shutdown()
  }

  /// S2 §3 wants switch labels from the schema, not from us.
  func testStateLabelComesFromTheSchema() throws {
    let scratch = try Scratch()
    let directories = try scratch.directories(shared: tracerData)
    let engine = RimeEngine(configuration: RimeConfiguration(directories: directories))
    _ = try engine.deploySync(binding: directories, fullCheck: true)
    try engine.openSession()

    XCTAssertEqual(try engine.stateLabel(option: "ascii_mode", state: false), "中文")
    XCTAssertEqual(try engine.stateLabel(option: "ascii_mode", state: true), "西文")
    XCTAssertEqual(try engine.currentSchema(), "tracer")
    XCTAssertEqual(try engine.schemas(), [RimeSchema(id: "tracer", name: "Tracer")])

    let output = try engine.selectSchema("tracer")
    XCTAssertEqual(output.status?.schemaID, "tracer")
    engine.shutdown()
  }

  /// S4 §4: the marked text is the raw input, not librime's spaced preedit.
  func testRawInputIsAvailableAlongsideThePreedit() throws {
    let scratch = try Scratch()
    let directories = try scratch.directories(shared: tracerData)
    let engine = RimeEngine(configuration: RimeConfiguration(directories: directories))
    _ = try engine.deploySync(binding: directories, fullCheck: true)
    try engine.openSession()

    let output = try engine.processKeys("nihao")
    XCTAssertEqual(output.preedit, "ni hao")
    XCTAssertEqual(try engine.rawInput(), "nihao")
    XCTAssertEqual(try engine.caretPosition(), 5)
    _ = try engine.setInput("ni")
    XCTAssertEqual(try engine.rawInput(), "ni")
    engine.shutdown()
  }

  /// Two measured corrections to S4 §8, both of which the candidate UI has to design around.
  ///
  /// 1. `highlight_candidate` returns true only when the highlight actually *moves*. Index 0 when
  ///    0 is already highlighted returns false, and so does an out-of-range index: the return value
  ///    is a "did anything change" signal, not a validity check. The UI reads
  ///    `page.highlightedIndex` instead.
  /// 2. `delete_candidate` returns true even though the tracer schema sets
  ///    `enable_user_dict: false`, and the deployed table is read-only, so the entry survives.
  ///    "Was it forgotten?" is a question the UI answers from `enable_user_dict`, not from this
  ///    return value.
  func testCandidateHighlightAndDeletionMeasurements() throws {
    let scratch = try Scratch()
    let directories = try scratch.directories(shared: tracerData)
    let engine = RimeEngine(configuration: RimeConfiguration(directories: directories))
    _ = try engine.deploySync(binding: directories, fullCheck: true)
    try engine.openSession()
    _ = try engine.processKeys("nihao")

    XCTAssertEqual(try engine.candidateList().map(\.text), ["你好", "你"])
    XCTAssertEqual(try engine.refresh().page?.highlightedIndex, 0)

    XCTAssertFalse(try engine.highlightCandidate(at: 0), "0 is already highlighted: nothing moved")
    XCTAssertTrue(try engine.highlightCandidate(at: 1), "moving the highlight reports true")
    XCTAssertEqual(try engine.refresh().page?.highlightedIndex, 1)
    XCTAssertFalse(try engine.highlightCandidate(at: 99), "an out-of-range index changes nothing")
    XCTAssertEqual(try engine.refresh().page?.highlightedIndex, 1, "and leaves the highlight alone")

    XCTAssertEqual(try engine.withSchemaConfig("tracer") { $0.bool("translator/enable_user_dict") }, false,
                   "the tracer schema keeps no user dictionary")
    XCTAssertTrue(try engine.deleteCandidate(at: 0),
                  "measured: librime accepts the delete even without a user dictionary")

    try engine.clearComposition()
    _ = try engine.processKeys("nihao")
    XCTAssertEqual(try engine.candidateList().first?.text, "你好",
                   "a deployed table is read-only, so the entry is still there afterwards")
    engine.shutdown()
  }
}
