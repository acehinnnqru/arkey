import XCTest
@testable import RimeEngine

/// Independent processes must coordinate through the same permanent lock inode.
final class S5DictionaryLockTests: XCTestCase {
  func testLockHelper() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let root = environment["ARKEY_LOCK_TEST_ROOT"],
          let mode = environment["ARKEY_LOCK_TEST_MODE"] else { return }
    let directory = URL(fileURLWithPath: root, isDirectory: true)
    let store = RimeLeaseStore(url: directory.appendingPathComponent("keyboard.lease.json"))
    if mode == "blocked" {
      XCTAssertThrowsError(try store.acquireLock())
      return
    }
    let ownership = try store.acquireLock()
    try store.claim(host: "test-child")
    try Data().write(to: directory.appendingPathComponent("ready"))
    let deadline = Date().addingTimeInterval(10)
    while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("exit").path),
          Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    withExtendedLifetime(ownership) {}
  }

  private func child(root: URL, mode: String) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = ["-XCTest", "RimeEngineTests.S5DictionaryLockTests/testLockHelper",
                         Bundle(for: S5DictionaryLockTests.self).bundleURL.path]
    var environment = ProcessInfo.processInfo.environment
    environment["ARKEY_LOCK_TEST_ROOT"] = root.path
    environment["ARKEY_LOCK_TEST_MODE"] = mode
    process.environment = environment
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    return process
  }

  func testAnotherProcessCannotAcquireAnOwnedLock() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RimeLeaseStore(url: root.appendingPathComponent("keyboard.lease.json"))
    let ownership = try store.acquireLock()
    let process = try child(root: root, mode: "blocked")
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    withExtendedLifetime(ownership) {}
  }

  func testProcessTerminationReleasesOwnershipEvenWithFreshMetadata() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let process = try child(root: root, mode: "hold")
    defer {
      if process.isRunning { process.terminate(); process.waitUntilExit() }
    }
    let ready = root.appendingPathComponent("ready")
    let deadline = Date().addingTimeInterval(5)
    while !FileManager.default.fileExists(atPath: ready.path), process.isRunning, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path), "the child must acquire ownership")
    let store = RimeLeaseStore(url: root.appendingPathComponent("keyboard.lease.json"))
    XCTAssertThrowsError(try store.acquireLock())
    XCTAssertNotNil(store.liveHolder())
    process.terminate()
    process.waitUntilExit()
    XCTAssertNotNil(store.current(), "process death leaves diagnostic metadata behind")
    XCTAssertNoThrow(try store.acquireLock(), "the kernel releases ownership on process death")
    XCTAssertTrue(store.isCold())
    store.prune()
    XCTAssertNil(store.current())
    XCTAssertTrue(FileManager.default.fileExists(atPath: store.lockURL.path), "never remove the lock inode")
  }
}
