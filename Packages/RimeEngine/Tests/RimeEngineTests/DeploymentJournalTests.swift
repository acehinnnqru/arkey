import XCTest
@testable import RimeEngine

final class DeploymentJournalTests: XCTestCase {
  private var directory: URL!
  private var journal: RimeDeploymentJournal!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    journal = RimeDeploymentJournal(url: directory.appendingPathComponent("deployment-state.json"))
  }

  override func tearDownWithError() throws {
    if FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.removeItem(at: directory)
    }
  }

  func testUnfinishedAttemptIsDetectedAcrossLaunchesUntilRetried() throws {
    let id = UUID()
    let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
    try journal.begin(id: id, profileID: "profile-a", profileName: "Profile A", startedAt: startedAt)
    let nextLaunch = RimeDeploymentJournal(url: journal.url)
    let interrupted = try XCTUnwrap(nextLaunch.recoverInterrupted())
    XCTAssertEqual(interrupted.state, .interrupted)
    XCTAssertEqual(interrupted.id, id)
    XCTAssertEqual(interrupted.profileID, "profile-a")
    XCTAssertEqual(interrupted.startedAt, startedAt)
    XCTAssertNil(interrupted.finishedAt)
    XCTAssertEqual(try RimeDeploymentJournal(url: journal.url).recoverInterrupted(), interrupted)
    let retry = UUID()
    try nextLaunch.begin(id: retry, profileID: "profile-a", profileName: "Profile A", startedAt: Date())
    try nextLaunch.finish(id: retry, succeeded: true)
    XCTAssertNil(try RimeDeploymentJournal(url: journal.url).recoverInterrupted())
    XCTAssertEqual(try journal.load()?.state, .succeeded)
  }

  func testKnownFailureIsDistinctFromAnInterruptedAttemptAndLateCompletionIsIgnored() throws {
    let first = UUID()
    let second = UUID()
    try journal.begin(id: first, profileID: "first", profileName: "First", startedAt: Date())
    try journal.begin(id: second, profileID: "second", profileName: "Second", startedAt: Date())
    try journal.finish(id: first, succeeded: true)
    XCTAssertEqual(try journal.load()?.state, .running)
    try journal.finish(id: second, succeeded: false)
    XCTAssertEqual(try journal.load()?.state, .failed)
    XCTAssertNotNil(try journal.load()?.finishedAt)
    XCTAssertNil(try journal.recoverInterrupted())
  }

  func testDismissalDoesNotRemoveANewerRunningAttempt() throws {
    let old = UUID()
    try journal.begin(id: old, profileID: "old", profileName: "Old", startedAt: Date())
    _ = try journal.recoverInterrupted()
    let newer = UUID()
    try journal.begin(id: newer, profileID: "new", profileName: "New", startedAt: Date())
    try journal.dismissInterrupted(id: old)
    XCTAssertEqual(try journal.load()?.id, newer)
    _ = try journal.recoverInterrupted()
    try journal.dismissInterrupted(id: newer)
    XCTAssertNil(try journal.load())
  }

  func testStartupCleanupPreservesTheJournalAndRestoresThePreviousBuild() throws {
    let workspace = try RimeWorkspace(root: directory).createDirectories()
    let layout = workspace.profile("profile-a")
    try FileManager.default.createDirectory(at: layout.buildPrevious, withIntermediateDirectories: true)
    try Data("usable previous generation".utf8).write(to: layout.buildPrevious.appendingPathComponent("retained.bin"))
    try FileManager.default.createDirectory(at: layout.buildStaging, withIntermediateDirectories: true)
    journal = RimeDeploymentJournal(workspace: workspace)
    try journal.begin(id: UUID(), profileID: "profile-a", profileName: "Profile A", startedAt: Date())
    let cleanup = RimeWorkspaceJanitor().run(workspace: workspace)
    XCTAssertEqual(cleanup.restoredBuilds, ["profile-a"])
    XCTAssertFalse(FileManager.default.fileExists(atPath: layout.buildStaging.path))
    XCTAssertEqual(try Data(contentsOf: layout.build.appendingPathComponent("retained.bin")),
                   Data("usable previous generation".utf8))
    XCTAssertEqual(try journal.recoverInterrupted()?.state, .interrupted)
  }
}
