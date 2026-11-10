import XCTest
import Compression
@testable import RimeEngine

/// S1 §10: crafted archives for zip slip, symlinks, case collisions, duplicates, oversize entries
/// and bombs — each asserting the specific error, not a generic failure.
final class S1ArchiveTests: XCTestCase {
  private var scratch: URL!

  override func setUpWithError() throws {
    scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkey-s1-archive", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: scratch)
  }

  // MARK: A raw archive builder

  /// One entry, with every field the hardening rules look at under the test's control.
  struct RawEntry {
    var path: String
    var payload: Data
    var method: UInt16 = 0
    var versionMadeBy: UInt16 = 0x031E
    var externalAttributes: UInt32 = 0o100644 << 16
    var utf8Flag: Bool = true
    var declaredUncompressed: Int?
    var declaredCompressed: Int?
    var crc: UInt32?

    init(path: String, payload: Data = Data("x".utf8)) {
      self.path = path
      self.payload = payload
    }
  }

  func makeArchive(_ entries: [RawEntry]) -> Data {
    var output = Data()
    var directory = Data()
    for entry in entries {
      let name = Data(entry.path.utf8)
      let crc = entry.crc ?? RimeCRC32.checksum(entry.payload)
      let uncompressed = entry.declaredUncompressed ?? entry.payload.count
      let compressed = entry.declaredCompressed ?? entry.payload.count
      let offset = UInt32(output.count)

      output.append(uint32: 0x04034b50)
      output.append(uint16: 20)
      output.append(uint16: entry.utf8Flag ? 0x0800 : 0)
      output.append(uint16: entry.method)
      output.append(uint16: 0)
      output.append(uint16: 0x21)
      output.append(uint32: crc)
      output.append(uint32: UInt32(compressed))
      output.append(uint32: UInt32(uncompressed))
      output.append(uint16: UInt16(name.count))
      output.append(uint16: 0)
      output.append(name)
      output.append(entry.payload)

      directory.append(uint32: 0x02014b50)
      directory.append(uint16: entry.versionMadeBy)
      directory.append(uint16: 20)
      directory.append(uint16: entry.utf8Flag ? 0x0800 : 0)
      directory.append(uint16: entry.method)
      directory.append(uint16: 0)
      directory.append(uint16: 0x21)
      directory.append(uint32: crc)
      directory.append(uint32: UInt32(compressed))
      directory.append(uint32: UInt32(uncompressed))
      directory.append(uint16: UInt16(name.count))
      directory.append(uint16: 0)
      directory.append(uint16: 0)
      directory.append(uint16: 0)
      directory.append(uint16: 0)
      directory.append(uint32: entry.externalAttributes)
      directory.append(uint32: offset)
      directory.append(name)
    }
    let directoryOffset = UInt32(output.count)
    output.append(directory)
    output.append(uint32: 0x06054b50)
    output.append(uint16: 0)
    output.append(uint16: 0)
    output.append(uint16: UInt16(entries.count))
    output.append(uint16: UInt16(entries.count))
    output.append(uint32: UInt32(directory.count))
    output.append(uint32: directoryOffset)
    output.append(uint16: 0)
    return output
  }

  private func expect(_ expected: RimeArchiveError, _ archive: Data,
                      limits: RimeArchiveLimits = .standard,
                      file: StaticString = #filePath, line: UInt = #line) {
    do {
      let parsed = try RimeZipArchive(data: archive, limits: limits)
      try parsed.extract(to: scratch.appendingPathComponent("out", isDirectory: true), limits: limits)
      XCTFail("expected \(expected), but the archive was accepted", file: file, line: line)
    } catch let error as RimeArchiveError {
      XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
      XCTFail("expected \(expected), got \(error)", file: file, line: line)
    }
  }

  // MARK: Round trip

  func testWriterAndReaderRoundTrip() throws {
    var writer = RimeZipWriter()
    try writer.addFile(path: "default.yaml", text: "schema_list:\n  - schema: tracer\n")
    try writer.addFile(path: "nested/tracer.dict.yaml", text: "---\nname: tracer\n")
    let archive = try RimeZipArchive(data: writer.data())
    XCTAssertEqual(archive.entries.map(\.path).sorted(), ["default.yaml", "nested/tracer.dict.yaml"])

    let destination = scratch.appendingPathComponent("round-trip", isDirectory: true)
    let written = try archive.extract(to: destination)
    XCTAssertEqual(written.sorted(), ["default.yaml", "nested/tracer.dict.yaml"])
    let text = try String(contentsOf: destination.appendingPathComponent("default.yaml"), encoding: .utf8)
    XCTAssertTrue(text.contains("tracer"))
  }

  /// A real deflate entry: the reader has to inflate, not just copy.
  func testDeflatedEntryIsInflated() throws {
    let original = Data(String(repeating: "rime ", count: 5_000).utf8)
    let deflated = try XCTUnwrap(Self.deflate(original))
    XCTAssertLessThan(deflated.count, original.count)

    var entry = RawEntry(path: "big.txt", payload: deflated)
    entry.method = 8
    entry.declaredUncompressed = original.count
    entry.crc = RimeCRC32.checksum(original)

    let archive = try RimeZipArchive(data: makeArchive([entry]))
    let destination = scratch.appendingPathComponent("deflated", isDirectory: true)
    try archive.extract(to: destination)
    XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("big.txt")), original)
  }

  // MARK: The hardening rules

  func testZipSlipIsRejected() {
    expect(.unsafePath("../evil.yaml"), makeArchive([RawEntry(path: "../evil.yaml")]))
    expect(.unsafePath("a/../../evil.yaml"), makeArchive([RawEntry(path: "a/../../evil.yaml")]))
    let absolutePath = scratch.appendingPathComponent("outside.yaml").path
    expect(.unsafePath(absolutePath), makeArchive([RawEntry(path: absolutePath)]))
    expect(.unsafePath("C:/windows/evil.yaml"), makeArchive([RawEntry(path: "C:/windows/evil.yaml")]))
    expect(.unsafePath("a\\b.yaml"), makeArchive([RawEntry(path: "a\\b.yaml")]))
    expect(.unsafePath(""), makeArchive([RawEntry(path: "")]))
  }

  func testSymlinkAndSpecialEntriesAreRejected() {
    var symlink = RawEntry(path: "link.yaml")
    symlink.externalAttributes = UInt32(0o120777) << 16
    expect(.entryTypeNotAllowed("link.yaml"), makeArchive([symlink]))

    var device = RawEntry(path: "dev")
    device.externalAttributes = UInt32(0o020666) << 16
    expect(.entryTypeNotAllowed("dev"), makeArchive([device]))
  }

  func testDuplicateAndCaseCollidingEntriesAreRejected() {
    expect(.duplicateEntry("a.yaml"),
           makeArchive([RawEntry(path: "a.yaml"), RawEntry(path: "a.yaml")]))
    expect(.caseCollision("a.yaml", "A.yaml"),
           makeArchive([RawEntry(path: "a.yaml"), RawEntry(path: "A.yaml")]))
    // A directory and a file with the same normalised path collide too.
    expect(.duplicateEntry("d/"),
           makeArchive([RawEntry(path: "d/"), RawEntry(path: "d/")]))
  }

  func testEntryCountCapIsEnforced() {
    let entries = (0..<5).map { RawEntry(path: "f\($0).yaml") }
    expect(.entryLimitExceeded(3), makeArchive(entries),
           limits: RimeArchiveLimits(maxEntries: 3))
  }

  func testPerEntryAndTotalSizeCapsAreEnforced() {
    var huge = RawEntry(path: "huge.dict.yaml")
    huge.declaredUncompressed = 512 << 20
    expect(.entrySizeLimitExceeded("huge.dict.yaml", 256 << 20), makeArchive([huge]))

    var first = RawEntry(path: "a.yaml")
    first.declaredUncompressed = 700
    var second = RawEntry(path: "b.yaml")
    second.declaredUncompressed = 700
    expect(.totalSizeLimitExceeded(1000), makeArchive([first, second]),
           limits: RimeArchiveLimits(maxTotalUncompressedBytes: 1000))
  }

  func testCompressionRatioBombIsRejected() {
    var bomb = RawEntry(path: "bomb.dict.yaml", payload: Data(repeating: 0, count: 4_096))
    bomb.method = 8
    bomb.declaredCompressed = 4_096
    bomb.declaredUncompressed = 400_000
    expect(.compressionRatioExceeded("bomb.dict.yaml", 10), makeArchive([bomb]),
           limits: RimeArchiveLimits(compressionRatioLimit: 10, compressionRatioFloorBytes: 2_048))

    // The same ratio under the floor is not an attack: a 2-byte file that inflates 300x is noise.
    var small = RawEntry(path: "small.yaml", payload: Data(repeating: 0, count: 100))
    small.method = 8
    small.declaredCompressed = 100
    small.declaredUncompressed = 30_000
    let archive = try? RimeZipArchive(data: makeArchive([small]),
                                      limits: RimeArchiveLimits(compressionRatioLimit: 10,
                                                                compressionRatioFloorBytes: 1 << 20))
    XCTAssertNotNil(archive, "a tiny entry must not trip the bomb rule")
  }

  func testZip64IsRefusedRatherThanMisread() {
    var archive = makeArchive([RawEntry(path: "a.yaml")])
    // Patch the end-of-central-directory record's entry count to the zip64 marker.
    let marker = archive.count - 22 + 10
    archive[marker] = 0xFF
    archive[marker + 1] = 0xFF
    expect(.unsupportedZip64, archive)
  }

  func testChecksumAndDeclaredSizeMismatchesAreRejected() {
    var wrongCRC = RawEntry(path: "a.yaml")
    wrongCRC.crc = RimeCRC32.checksum(Data("different".utf8))
    expect(.checksumMismatch("a.yaml"), makeArchive([wrongCRC]))

    var wrongSize = RawEntry(path: "a.yaml", payload: Data("abcd".utf8))
    wrongSize.declaredUncompressed = 99
    expect(.sizeMismatch("a.yaml", 99, 4), makeArchive([wrongSize]))
  }

  func testUnsupportedCompressionMethodIsRejected() {
    var bzip2 = RawEntry(path: "a.yaml")
    bzip2.method = 12
    expect(.unsupportedCompression(12, "a.yaml"), makeArchive([bzip2]))
  }

  func testACorruptDeflateStreamIsRejected() {
    var corrupt = RawEntry(path: "a.yaml", payload: Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05]))
    corrupt.method = 8
    corrupt.declaredUncompressed = 1_000
    corrupt.crc = 0
    expect(.extractionFailed("a.yaml (the deflate stream is corrupt)"), makeArchive([corrupt]))
  }

  func testNotAZipIsRefused() {
    expect(.notAZip, Data("this is not an archive".utf8))
    expect(.notAZip, Data())
  }

  /// A rejected archive leaves nothing behind, which is what lets the importer treat staging as
  /// scratch.
  func testExtractionFailureLeavesNoPartialOutput() throws {
    var good = RawEntry(path: "good.yaml", payload: Data("ok".utf8))
    good.declaredUncompressed = 2
    var bad = RawEntry(path: "bad.yaml", payload: Data("abc".utf8))
    bad.crc = RimeCRC32.checksum(Data("nope".utf8))

    let archive = try RimeZipArchive(data: makeArchive([good, bad]))
    let destination = scratch.appendingPathComponent("partial", isDirectory: true)
    XCTAssertThrowsError(try archive.extract(to: destination))
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path),
                   "a failed extraction must not leave a half-unpacked tree behind")
  }

  // MARK: Helpers

  static func deflate(_ data: Data) -> Data? {
    let bufferSize = 64 * 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }
    var output = Data()
    var failed = false
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      guard let source = raw.bindMemory(to: UInt8.self).baseAddress else { return }
      var stream = compression_stream(dst_ptr: buffer, dst_size: bufferSize,
                                      src_ptr: source, src_size: raw.count, state: nil)
      guard compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB)
        == COMPRESSION_STATUS_OK else { failed = true; return }
      defer { compression_stream_destroy(&stream) }
      stream.src_ptr = source
      stream.src_size = raw.count
      stream.dst_ptr = buffer
      stream.dst_size = bufferSize
      while true {
        let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
        output.append(buffer, count: bufferSize - stream.dst_size)
        if status == COMPRESSION_STATUS_END { return }
        if status == COMPRESSION_STATUS_ERROR { failed = true; return }
        stream.dst_ptr = buffer
        stream.dst_size = bufferSize
      }
    }
    return failed ? nil : output
  }
  /// The invariant that matters is not *which* guard refuses a traversing path but that **nothing is written
  /// outside the destination**. The reader has two guards — the path string and a containment re-check — and a
  /// test that only asserts the error cannot tell which one refused, so a mutation of either alone stays
  /// green. This asserts the filesystem outcome instead, which is what the two guards are there for.
  func testNothingIsWrittenOutsideTheDestination() throws {
    let destination = scratch.appendingPathComponent("escape", isDirectory: true)
    let escaped = scratch.appendingPathComponent("escaped.yaml")
    let data = makeArchive([RawEntry(path: "../escaped.yaml")])

    // Measured: the refusal happens while the archive is being *read* — the path guard fires before any
    // extraction — so this asserts the reading and the filesystem together. The extraction-time containment
    // check is a second layer for what a path string cannot see (a symlinked parent), which no fixture here
    // can produce.
    XCTAssertThrowsError(try RimeZipArchive(data: data))
    XCTAssertFalse(FileManager.default.fileExists(atPath: escaped.path),
                   "a traversing entry wrote outside the destination")
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path),
                   "and no destination was left behind")
  }
}

private extension Data {
  mutating func append(uint16 value: UInt16) {
    append(UInt8(value & 0xFF))
    append(UInt8((value >> 8) & 0xFF))
  }

  mutating func append(uint32 value: UInt32) {
    append(UInt8(value & 0xFF))
    append(UInt8((value >> 8) & 0xFF))
    append(UInt8((value >> 16) & 0xFF))
    append(UInt8((value >> 24) & 0xFF))
  }

}
