import XCTest
@testable import RimeEngine

/// S1 §5's static catalog: what the app may offer, and what it records when the user asks for it.
final class S1CatalogTests: XCTestCase {
  private var scratch: URL!

  override func setUpWithError() throws {
    scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkey-s1-catalog", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: scratch)
  }

  // MARK: The list

  func testTheCatalogIsShortAndEveryEntryIsComplete() {
    let catalog = RimeCatalog.standard
    XCTAssertFalse(catalog.entries.isEmpty)
    XCTAssertLessThanOrEqual(catalog.entries.count, 4,
                             "S1 asks for a short catalog, not a store")
    XCTAssertEqual(Set(catalog.entries.map(\.id)).count, catalog.entries.count, "ids are unique")

    for entry in catalog.entries {
      XCTAssertFalse(entry.displayName.isEmpty)
      XCTAssertFalse(entry.license.spdx.isEmpty)
      XCTAssertFalse(entry.license.name.isEmpty)
      XCTAssertNotNil(entry.license.sourceURL, "\(entry.id) must name where it comes from")
      XCTAssertGreaterThan(entry.approximateBytes, 0)
      XCTAssertGreaterThan(entry.requirements.schemaCount, 0)
      XCTAssertFalse(entry.notes.isEmpty, "the UI states the cost before anything is fetched")
      XCTAssertTrue(entry.isSecure, "\(entry.pageURL) must be HTTPS")
    }
  }

  func testPresetsUseUpstreamReleasesAndKeepChannelAndSizeIndependent() throws {
    let entries = RimeCatalog.standard.entries
    XCTAssertEqual(entries.count, 4)
    XCTAssertEqual(entries.filter { $0.releaseChannel == .stable }.count, 2)
    XCTAssertEqual(entries.filter { $0.releaseChannel == .nightly }.count, 2)
    XCTAssertEqual(entries.filter { !$0.removedImportTables.isEmpty }.count, 2)
    for entry in entries {
      XCTAssertTrue(entry.pageURL.hasPrefix("https://github.com/iDvel/rime-ice/releases"))
    }
  }

  func testLookupByNameAndTheRefusalForAnUnknownID() throws {
    let first = try XCTUnwrap(RimeCatalog.standard.entries.first)
    XCTAssertEqual(RimeCatalog.standard.entry(id: first.id)?.displayName, first.displayName)
    XCTAssertNil(RimeCatalog.standard.entry(id: "nope"))
    XCTAssertThrowsError(try RimeCatalogValidation.entry(id: "nope")) { error in
      guard case RimeCatalogError.unknownEntry(let id) = error else {
        return XCTFail("expected unknownEntry, got \(error)")
      }
      XCTAssertEqual(id, "nope")
    }
  }

  func testAnInsecurePageIsRefusedBeforeAnythingIsFetched() throws {
    let insecure = RimeCatalogEntry(id: "x", displayName: "X",
                                    license: .unknown,
                                    pageURL: "http://example.invalid/x.zip",
                                    approximateBytes: 1024,
                                    requirements: .init(needsLua: false),
                                    notes: "http")
    let catalog = RimeCatalog(entries: [insecure])
    XCTAssertThrowsError(try RimeCatalogValidation.entry(id: "x", in: catalog)) { error in
      guard case RimeCatalogError.insecureURL = error else {
        return XCTFail("expected insecureURL, got \(error)")
      }
    }
  }

  // MARK: Receipts

  func testAReceiptRecordsTheSizeTheDigestAndTheRedirect() throws {
    let entry = try XCTUnwrap(RimeCatalog.standard.entries.first)
    let file = scratch.appendingPathComponent("download.zip")
    let contents = Data(repeating: 0x41, count: 4096)
    try contents.write(to: file)

    let receipt = try RimeCatalogValidation.receipt(
      for: entry, fileURL: file,
      resolvedURL: "https://github.com/iDvel/rime-ice/releases/download/nightly/full.zip",
      retrievedAt: Date(timeIntervalSince1970: 1_700_000_000))

    XCTAssertEqual(receipt.entryID, entry.id)
    XCTAssertEqual(receipt.pageURL, entry.pageURL)
    XCTAssertEqual(receipt.bytes, 4096)
    XCTAssertEqual(receipt.sha256, RimeDigest.sha256(of: contents))
    XCTAssertEqual(receipt.resolvedURL,
                   "https://github.com/iDvel/rime-ice/releases/download/nightly/full.zip")

    // The receipt is what the profile records as provenance.
    let source = receipt.profileSource
    XCTAssertEqual(source.kind, .download)
    XCTAssertEqual(source.url, entry.pageURL)
    XCTAssertEqual(source.bytes, 4096)
    XCTAssertEqual(source.sha256, receipt.sha256)
    XCTAssertEqual(source.retrievedAt, receipt.retrievedAt)
  }

  func testTheSizeCapsAreEnforcedBeforeAnythingIsImported() throws {
    let entry = try XCTUnwrap(RimeCatalog.standard.entries.first)
    let big = scratch.appendingPathComponent("big.zip")
    try Data(repeating: 0, count: 8192).write(to: big)
    XCTAssertThrowsError(try RimeCatalogValidation.receipt(
      for: entry, fileURL: big, limits: RimeCatalogLimits(maxBytes: 4096, minBytes: 16))) { error in
      guard case RimeCatalogError.tooLarge(let bytes, let limit) = error else {
        return XCTFail("expected tooLarge, got \(error)")
      }
      XCTAssertEqual(bytes, 8192)
      XCTAssertEqual(limit, 4096)
    }

    let tiny = scratch.appendingPathComponent("tiny.zip")
    try Data("no".utf8).write(to: tiny)
    XCTAssertThrowsError(try RimeCatalogValidation.receipt(for: entry, fileURL: tiny)) { error in
      guard case RimeCatalogError.tooSmall = error else {
        return XCTFail("expected tooSmall, got \(error)")
      }
    }

    XCTAssertThrowsError(try RimeCatalogValidation.receipt(
      for: entry, fileURL: scratch.appendingPathComponent("missing.zip"))) { error in
      guard case RimeCatalogError.unreadable = error else {
        return XCTFail("expected unreadable, got \(error)")
      }
    }
  }

  func testTheLiteEntrySaysWhatItLeavesOut() throws {
    let lite = try XCTUnwrap(RimeCatalog.standard.entry(id: "rime-ice-lite"))
    let full = try XCTUnwrap(RimeCatalog.standard.entry(id: "rime-ice-full"))
    XCTAssertEqual(lite.approximateBytes, full.approximateBytes)
    XCTAssertEqual(lite.removedImportTables, ["cn_dicts/tencent"])
    XCTAssertEqual(lite.license.spdx, full.license.spdx, "the same config, the same licence")
    XCTAssertEqual(lite.requirements.schemaCount, full.requirements.schemaCount)
  }

  /// The catalogue is the app's own list, and every entry in it is third-party config data the user imports
  /// rather than something this repository ships. The credit path is therefore part of the entry: without a
  /// source URL and a notice path the licence screen has nothing to point at, and GPL-3.0-only data with no
  /// route to its source is the one mistake here that a release cannot fix by rebuilding.
  func testEveryCatalogEntryCarriesTheCreditPathItsLicenceNeeds() throws {
    for entry in RimeCatalog.standard.entries {
      XCTAssertFalse(entry.license.spdx.isEmpty, entry.id + " has no licence identifier")
      XCTAssertTrue(entry.license.url?.hasPrefix("https://") == true,
                    entry.id + " has no licence text to link to")
      XCTAssertTrue(entry.license.sourceURL?.hasPrefix("https://") == true,
                    entry.id + " does not say where its source is")
      XCTAssertNotNil(entry.license.noticePath,
                      entry.id + " does not say which upstream file carries the credits")
      XCTAssertTrue(entry.isSecure, entry.id + " does not link over https")
    }
  }

  /// Copyleft is the case the whole posture is about: the user imports it, the repository never ships it.
  /// This is the catalogue half of that statement — the release check is the bundle half.
  func testCopyleftEntriesNameTheirSourceAndTheirCredits() throws {
    let copyleft = ["GPL-2.0-only", "GPL-3.0-only", "LGPL-2.1-only", "LGPL-3.0-only", "AGPL-3.0-only"]
    let flagged = RimeCatalog.standard.entries.filter { copyleft.contains($0.license.spdx) }
    XCTAssertFalse(flagged.isEmpty, "the catalogue is expected to offer rime-ice, which is GPL-3.0-only")
    for entry in flagged {
      let source = try XCTUnwrap(entry.license.sourceURL, entry.id)
      let notice = try XCTUnwrap(entry.license.noticePath, entry.id)
      XCTAssertTrue(source.contains("github.com"), source)
      XCTAssertFalse(notice.isEmpty)
      XCTAssertFalse(entry.notes.isEmpty)
    }
  }
}
