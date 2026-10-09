import XCTest
import RimeEngine

final class KeyboardDiagnosticsTests: XCTestCase {
  func testTransitionProducesOneSummaryAndRetainsOneFramePeak() throws {
    var trace = KeyboardGeometryTrace()
    for index in 0..<104 {
      trace.record(height: index == 42 ? 600 : 270, requestedHeight: 270,
                   needsGlobe: false, message: "frame \(index)")
    }
    let summary = try XCTUnwrap(trace.finish(reason: "settled"))
    XCTAssertTrue(summary.contains("samples=104"))
    XCTAssertTrue(summary.contains("peakHeight=600.00"))
    XCTAssertTrue(summary.contains("first: frame 0"))
    XCTAssertTrue(summary.contains("peak: frame 42"))
    XCTAssertTrue(summary.contains("last: frame 103"))
    trace.record(height: 700, requestedHeight: 270, needsGlobe: false, message: "late")
    XCTAssertNil(trace.finish(reason: "disappear"))
  }

  func testLegacyFramesAreGroupedWithoutLosingOtherPresentations() {
    var records = (0..<104).map { index in
      RimeProbeRecord(phase: "keyboard.geometry.displayFrame",
                      message: "geometry id=A appearance=1 seq=\(index)")
    }
    records.append(RimeProbeRecord(phase: "keyboard.geometry.loaded", message: "geometry id=B appearance=1"))
    records.append(RimeProbeRecord(phase: "keyboard.boot", message: "ready"))
    let compact = DiagnosticsReport.compact(records)
    XCTAssertEqual(compact.count, 3)
    XCTAssertTrue(compact.contains { $0.message?.contains("104 records") == true })
    XCTAssertTrue(compact.contains { $0.phase == "keyboard.boot" })
    XCTAssertEqual(DiagnosticsReport.compact(compact).count, 3)
  }

  func testExportBoundsLargeLegacyRecordsAndIncludesPhase() {
    let records = (0..<200).map { index in
      RimeProbeRecord(phase: "keyboard.geometry.summary",
                      message: "record \(index) " + String(repeating: "x", count: 20_000))
    }
    let report = DiagnosticsReport.text(records: records, location: "test log")
    XCTAssertTrue(report.hasPrefix("Arkey diagnostics"))
    XCTAssertTrue(report.contains("keyboard.geometry.summary"))
    XCTAssertTrue(report.contains("record 199"))
    XCTAssertTrue(report.contains("[Message truncated]"))
    XCTAssertLessThan(report.utf8.count, 130_000)
  }
}
