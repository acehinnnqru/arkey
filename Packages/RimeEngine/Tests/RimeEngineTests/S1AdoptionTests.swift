import XCTest
@testable import RimeEngine

/// S1 §8/AC7: a profile change is adopted at the next appearance and never mid-composition. The rule is the
/// engine's now, so it can be pinned here instead of being a comment in the extension.
final class S1AdoptionTests: XCTestCase {
  private func resolved(shared: String, build: String, profileID: String?,
                        generation: Int = 1) -> RimeResolvedProfile {
    let root = FileManager.default.temporaryDirectory
    let buildDirectory = root.appendingPathComponent(build, isDirectory: true)
    return RimeResolvedProfile(origin: .appGroup, profileID: profileID, generation: generation,
                               buildDirectory: buildDirectory,
                               directories: RimeDirectories(sharedDataDir: root.appendingPathComponent(shared).path,
                                                            prebuiltDataDir: buildDirectory.path,
                                                            userDataDir: root.appendingPathComponent("user").path,
                                                            stagingDir: root.appendingPathComponent("staging").path,
                                                            logDir: root.appendingPathComponent("log").path),
                               fallbackReason: nil)
  }

  func testTheSameBindingNeedsNoAdoption() {
    let current = resolved(shared: "p/a/source", build: "p/a/build", profileID: "a")
    let same = resolved(shared: "p/a/source", build: "p/a/build", profileID: "a")
    XCTAssertEqual(RimeProfileAdoption.decide(resolved: same, current: current, isComposing: false),
                   .unchanged)
    XCTAssertEqual(RimeProfileAdoption.decide(resolved: same, current: current, isComposing: true),
                   .unchanged)
  }

  func testAChangeMidCompositionIsDeferredAndTakenAtTheNextAppearance() {
    let current = resolved(shared: "p/a/source", build: "p/a/build", profileID: "a")
    let next = resolved(shared: "p/b/source", build: "p/b/build", profileID: "b")

    XCTAssertEqual(RimeProfileAdoption.decide(resolved: next, current: current, isComposing: true),
                   .deferred, "never mid-composition")
    XCTAssertEqual(RimeProfileAdoption.decide(resolved: next, current: current, isComposing: false),
                   .rebind(next), "and the deferral is not a drop: the next appearance binds it")
  }

  func testANewGenerationOfTheSameProfileIsAChange() {
    let current = resolved(shared: "p/a/source", build: "p/a/build", profileID: "a")
    let next = resolved(shared: "p/a/source", build: "p/a/build", profileID: "a", generation: 2)
    XCTAssertEqual(next.directories, current.directories)
    XCTAssertEqual(RimeProfileAdoption.decide(resolved: next, current: current, isComposing: true),
                   .deferred)
    XCTAssertEqual(RimeProfileAdoption.decide(resolved: next, current: current, isComposing: false),
                   .rebind(next), "a redeploy replaces the build without changing its path")
    XCTAssertEqual(RimeProfileAdoption.decide(resolved: next, current: next, isComposing: false),
                   .unchanged, "once adopted, the same generation needs no further rebind")
  }

  func testADifferentProfileAtTheSamePathsIsAChange() {
    let current = resolved(shared: "p/source", build: "p/build", profileID: "a")
    let next = resolved(shared: "p/source", build: "p/build", profileID: "b")
    XCTAssertEqual(RimeProfileAdoption.decide(resolved: next, current: current, isComposing: false),
                   .rebind(next))
  }

  func testADifferentBuildPathOfTheSameGenerationIsAChange() {
    let current = resolved(shared: "p/a/source", build: "p/a/build", profileID: "a")
    let next = resolved(shared: "p/a/source", build: "p/a/build.previous", profileID: "a")
    XCTAssertEqual(RimeProfileAdoption.decide(resolved: next, current: current, isComposing: false),
                   .rebind(next), "recovery can move the build directory within the same generation")
  }
}
