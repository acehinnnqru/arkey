import XCTest
@testable import RimeEngine

/// S1 §8/AC7: a profile change is adopted at the next appearance and never mid-composition. The rule is the
/// engine's now, so it can be pinned here instead of being a comment in the extension.
final class S1AdoptionTests: XCTestCase {
  private func resolved(shared: String, build: String, profileID: String?) -> RimeResolvedProfile {
    RimeResolvedProfile(origin: .appGroup, profileID: profileID, generation: 1,
                        buildDirectory: URL(fileURLWithPath: build),
                        directories: RimeDirectories(sharedDataDir: shared,
                                                     prebuiltDataDir: build,
                                                     userDataDir: "/tmp/user",
                                                     stagingDir: "/tmp/staging",
                                                     logDir: "/tmp/log"),
                        fallbackReason: nil)
  }

  func testTheSameBindingNeedsNoAdoption() {
    let current = resolved(shared: "/p/a/source", build: "/p/a/build", profileID: "a")
    let same = resolved(shared: "/p/a/source", build: "/p/a/build", profileID: "a")
    XCTAssertEqual(RimeProfileAdoption.decide(resolved: same, current: current, isComposing: false),
                   .unchanged)
  }

  func testAChangeMidCompositionIsDeferredAndTakenAtTheNextAppearance() {
    let current = resolved(shared: "/p/a/source", build: "/p/a/build", profileID: "a")
    let next = resolved(shared: "/p/b/source", build: "/p/b/build", profileID: "b")

    XCTAssertEqual(RimeProfileAdoption.decide(resolved: next, current: current, isComposing: true),
                   .deferred, "never mid-composition")
    XCTAssertEqual(RimeProfileAdoption.decide(resolved: next, current: current, isComposing: false),
                   .rebind(next), "and the deferral is not a drop: the next appearance binds it")
  }

  func testANewGenerationOfTheSameProfileIsAChange() {
    let current = resolved(shared: "/p/a/source", build: "/p/a/build", profileID: "a")
    let next = resolved(shared: "/p/a/source", build: "/p/a/build.previous", profileID: "a")
    XCTAssertEqual(RimeProfileAdoption.decide(resolved: next, current: current, isComposing: false),
                   .rebind(next), "a rollback moves the build directory, so it is a change")
  }
}
