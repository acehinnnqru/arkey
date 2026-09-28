import XCTest
@testable import RimeEngine

/// S1-AC8 and S4-AC6 read the probe log as numbers. This is the arithmetic behind that reading.
final class S6ProbeSummaryTests: XCTestCase {
  private func record(_ phase: String, milliseconds: Double?, footprint: UInt64? = nil,
                      message: String? = nil, after seconds: TimeInterval = 0) -> RimeProbeRecord {
    var record = RimeProbeRecord(phase: phase, milliseconds: milliseconds, message: message)
    record.footprintBytes = footprint
    record.timestamp = Date(timeIntervalSince1970: 1_000 + seconds)
    return record
  }

  func testAnEmptyLogSummarisesToNothing() {
    let summary = RimeProbeSummary(records: [])
    XCTAssertTrue(summary.isEmpty)
    XCTAssertEqual(summary.recordCount, 0)
    XCTAssertTrue(summary.phases.isEmpty)
    XCTAssertNil(summary.firstTimestamp)
  }

  func testThePercentilesAreNearestRank() throws {
    let records = (1...20).map { index in
      record("keyboard.stats", milliseconds: Double(index), after: Double(index))
    }
    let phase = try XCTUnwrap(RimeProbeSummary(records: records).phases.first)
    XCTAssertEqual(phase.count, 20)
    XCTAssertEqual(phase.medianMilliseconds, 10, "the tenth of twenty")
    XCTAssertEqual(phase.p95Milliseconds, 19, "nearest rank: ceil(0.95 × 20) = 19")
    XCTAssertEqual(phase.maxMilliseconds, 20)
    XCTAssertEqual(phase.lastMilliseconds, 20, "the latest record wins, not the largest")
  }

  func testFootprintsKeepTheirMaximumAndTheirLatest() throws {
    let records = [record("keyboard.stats", milliseconds: 1, footprint: 40, after: 0),
                   record("keyboard.stats", milliseconds: 2, footprint: 90, after: 1),
                   record("keyboard.stats", milliseconds: 3, footprint: 60, after: 2)]
    let phase = try XCTUnwrap(RimeProbeSummary(records: records).phases.first)
    XCTAssertEqual(phase.maxFootprintBytes, 90)
    XCTAssertEqual(phase.lastFootprintBytes, 60)
  }

  func testAPhaseWithoutTimingsStillGetsARow() throws {
    let summary = RimeProbeSummary(records: [record("keyboard.boot.failed", milliseconds: nil,
                                                  message: "no full access")])
    let phase = try XCTUnwrap(summary.phases.first)
    XCTAssertEqual(phase.name, "keyboard.boot.failed")
    XCTAssertEqual(phase.count, 1)
    XCTAssertNil(phase.medianMilliseconds)
    XCTAssertEqual(phase.lastMessage, "no full access")
  }

  func testTheSpecsPhasesLeadTheList() {
    let summary = RimeProbeSummary(records: [record("engine.record", milliseconds: 1),
                                             record("keyboard.stats", milliseconds: 2),
                                             record("keyboard.boot", milliseconds: 3),
                                             record("keyboard.adopt.deferred", milliseconds: 4)])
    XCTAssertEqual(summary.orderedPhases.map(\.name),
                   ["keyboard.boot", "keyboard.stats", "engine.record", "keyboard.adopt.deferred"],
                   "the spec's phases first, the rest alphabetical")
    XCTAssertEqual(summary.phases.map(\.name),
                   ["engine.record", "keyboard.adopt.deferred", "keyboard.boot", "keyboard.stats"])
  }

  /// The report is what a device run copies out, so its shape matters: the numbers, in the specs' order,
  /// with the reason attached to the phases that carry one.
  func testTheReportIsTheNumbersInTheSpecsOrder() throws {
    let records = [record("keyboard.boot", milliseconds: 120, footprint: 30 * 1_048_576,
                          message: "profile tracer", after: 0),
                   record("keyboard.stats", milliseconds: 8, footprint: 40 * 1_048_576, after: 1),
                   record("keyboard.stats", milliseconds: 12, footprint: 55 * 1_048_576, after: 2),
                   record("keyboard.boot.failed", milliseconds: nil, message: "no full access", after: 3)]
    let report = RimeProbeSummary(records: records).report()
    let lines = report.split(separator: "\n").map(String.init)

    XCTAssertEqual(lines.first, "probe log: 4 records")
    XCTAssertTrue(lines[1].hasPrefix("first "), lines[1])
    XCTAssertEqual(lines[2], "  keyboard.boot: 1 samples, median 120.0 ms, p95 120.0 ms, max 120.0 ms, footprint 30.0 MB, profile tracer")
    XCTAssertEqual(lines[3], "  keyboard.stats: 2 samples, median 8.0 ms, p95 12.0 ms, max 12.0 ms, footprint 55.0 MB",
                   "the latest sample, which is what the footprint after typing means")
    XCTAssertEqual(lines[4], "  keyboard.boot.failed: 1 samples, no full access")
  }

  func testAnEmptyLogSaysSoInItsReport() {
    XCTAssertEqual(RimeProbeSummary(records: []).report(), "probe log: no records")
  }

  /// One size format for the whole app, so three screens cannot write the same number three ways.
  func testSizesAreFormattedInOnePlace() {
    XCTAssertEqual(RimeProbe.formatted(bytes: 0), "0 B")
    XCTAssertEqual(RimeProbe.formatted(bytes: 512), "512 B")
    XCTAssertEqual(RimeProbe.formatted(bytes: 2048), "2 KB")
    XCTAssertEqual(RimeProbe.formatted(bytes: 1_048_576), "1.0 MB")
    XCTAssertEqual(RimeProbe.formatted(bytes: 5 * 1_048_576), "5.0 MB")
    XCTAssertEqual(RimeProbe.formatted(bytes: 2 * 1_073_741_824), "2.0 GB")
  }
}
