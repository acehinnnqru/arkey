import XCTest
@testable import RimeEngine

/// S4-AC6: the number the keyboard writes is a per-key percentile, not the average of a batch — the average
/// of twenty-five keys hides every spike the budget is about.
final class S4LatencyTests: XCTestCase {
  func testTheWindowReportsThePercentileOfItsSamplesNotTheirAverage() {
    var window = RimeKeyLatencyWindow(capacity: 20)
    for value in 1...19 { window.record(milliseconds: Double(value)) }
    window.record(milliseconds: 100)

    XCTAssertEqual(window.count, 20)
    XCTAssertTrue(window.isFull)
    XCTAssertEqual(window.average, 14.5, accuracy: 0.001, "290 ms over twenty keys")
    XCTAssertEqual(window.p95, 19, "nearest rank: ceil(0.95 × 20) = 19")
    XCTAssertEqual(window.maximum, 100, "and the spike is still visible as the max")
  }

  func testAShortWindowStillAnswers() {
    var window = RimeKeyLatencyWindow(capacity: 25)
    XCTAssertTrue(window.isEmpty)
    XCTAssertEqual(window.average, 0)
    XCTAssertEqual(window.p95, 0)
    XCTAssertFalse(window.isFull)

    window.record(milliseconds: 7)
    window.record(milliseconds: 9)
    XCTAssertEqual(window.count, 2)
    XCTAssertEqual(window.average, 8, accuracy: 0.001)
    XCTAssertEqual(window.p95, 9)
    XCTAssertEqual(window.maximum, 9)
  }

  func testResettingForgetsTheBatchAndKeepsNothingBehind() {
    var window = RimeKeyLatencyWindow(capacity: 4)
    for value in [10.0, 20, 30, 40] { window.record(milliseconds: value) }
    window.reset()
    XCTAssertTrue(window.isEmpty)
    XCTAssertEqual(window.maximum, 0)
    XCTAssertEqual(window.average, 0)
    XCTAssertFalse(window.isFull)
  }

  func testTheMessageCarriesTheThreeNumbers() {
    var window = RimeKeyLatencyWindow(capacity: 4)
    for value in [4.0, 8, 12, 16] { window.record(milliseconds: value) }
    XCTAssertEqual(window.message, "keys=4 avgMs=10.00 p95Ms=16.00 maxMs=16.00")
  }
}
