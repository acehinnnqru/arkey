import XCTest
import RimeEngine

/// S4 §4.1's select-key row, on the extension's own path.
///
/// The engine's input path is covered in the package; the keyboard does not go through it — it calls the engine
/// directly — so the routing that makes a select key select lives in two places and this is the second one,
/// driven through the view controller with a profile that actually has select keys.
@MainActor
final class KeyboardSelectKeyTests: XCTestCase {
  private var imported: String?

  override func tearDownWithError() throws {
    let model = RimeAppModel()
    if let imported {
      try? RimeDeploymentCoordinator(workspace: model.workspace, engine: model.engine)
        .delete(profileID: imported)
      try? FileManager.default.removeItem(at: model.workspace.activeRecord)
    }
    // The select-key patch is a real user file, and the settings-export test counts the files in this
    // directory: leaving it behind made that test see three where it expects two.
    try? FileManager.default.removeItem(
      at: model.workspace.userData.appendingPathComponent("default.custom.yaml"))
    imported = nil
  }

  func testTheExtensionSelectsOnASelectKey() async throws {
    let model = RimeAppModel()
    await model.bootstrap()
    await model.importPayload(at: try sourceFolder(), displayName: "Select key test", adoptUserData: false)
    let profile = try XCTUnwrap(model.profiles.first { $0.displayName == "Select key test" },
                                "the import is not listed")
    imported = profile.id
    await model.deploy(profileID: profile.id)

    // A schema with select keys: the labels the bar draws and the keys librime matches them against.
    let patch = RimePatch(engine: model.engine, configID: "default")
    try patch.set(.list(["1", "2", "3"].map { .string($0) }), at: "menu/alternative_select_labels")
    try patch.set(.string("123"), at: "menu/select_keys")
    _ = try RimeDeploymentCoordinator(workspace: model.workspace, engine: model.engine)
      .deploySync(profileID: profile.id)

    let controller = KeyboardViewController()
    controller.loadViewIfNeeded()
    controller.view.frame = CGRect(x: 0, y: 0, width: 430, height: 420)
    controller.viewWillAppear(false)
    controller.view.setNeedsLayout()
    controller.view.layoutIfNeeded()

    let grid = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? KeyboardKeyGrid }.first,
                             "no key grid")
    for character in ["n", "i", "h", "a", "o"] {
      try tap(.character(character), in: grid)
    }
    guard case .success(let setup) = KeyboardEngine.setup else {
      return XCTFail("the keyboard did not start")
    }
    let composing = try setup.engine.refresh()
    XCTAssertNotNil(composing.preedit, "the keyboard is not composing after typing nihao")

    // The select key is a digit, so the board has to be on the numbers layer to press it.
    try tap(.numbers, in: grid)
    try tap(.character("1"), in: grid)

    let after = try setup.engine.refresh()
    let remaining = try setup.engine.candidateList()
    XCTAssertNil(after.preedit, "the select key left the composition in place")
    XCTAssertTrue(remaining.isEmpty,
                  "the bar still offers candidates after the select key: "
                    + remaining.map { $0.text }.joined(separator: ", "))
  }

  private func tap(_ key: KeyboardKey, in grid: KeyboardKeyGrid) throws {
    grid.setNeedsLayout()
    grid.layoutIfNeeded()
    let button = try XCTUnwrap(grid.subviews.compactMap { $0 as? KeyButton }.first { $0.key == key },
                               "no key " + String(describing: key))
    button.sendActions(for: .primaryActionTriggered)
  }

  private func sourceFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkey-select-key", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    // The same lookup the app itself uses: the data ships with the app, not with the test bundle.
    let data = try XCTUnwrap(RimeDirectories.bundledSharedDataURL(in: .main), "no bundled RimeData")
    for name in ["default.yaml", "tracer.schema.yaml", "tracer.dict.yaml"] {
      try FileManager.default.copyItem(at: data.appendingPathComponent(name),
                                       to: folder.appendingPathComponent(name))
    }
    return folder
  }
}
