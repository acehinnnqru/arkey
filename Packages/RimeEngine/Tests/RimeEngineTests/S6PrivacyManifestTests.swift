import XCTest
@testable import RimeEngine

/// S6: the privacy manifest, checked for what it *says* rather than that it exists.
///
/// Two failure modes are worth a test. A manifest that declares nothing when the code reads required
/// APIs is a review rejection; a manifest that declares something the code does not do is a false
/// statement. The reason codes are Apple's approved ones, and an invented or mistyped code is
/// rejected at submission — so every code here is checked against the list.
final class S6PrivacyManifestTests: XCTestCase {
  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  /// Apple's approved reason codes, as of the check recorded in docs/s6-results.md. A code outside
  /// this list is not a reason Apple accepts.
  private static let approvedReasons: [String: Set<String>] = [
    "NSPrivacyAccessedAPICategoryFileTimestamp": ["DDA9.1", "C617.1", "3B52.1", "0A2A.1"],
    "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1", "8FFB.1", "3D61.1"],
    "NSPrivacyAccessedAPICategoryDiskSpace": ["85F4.1", "E174.1", "7D9E.1", "B728.1"],
    "NSPrivacyAccessedAPICategoryActiveKeyboards": ["3EC4.1", "54BD.1"],
    "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1", "1C8F.1", "C56D.1", "AC6B.1"],
  ]

  private func loadManifest() throws -> [String: Any] {
    let url = repositoryRoot.appendingPathComponent("arkey/PrivacyInfo.xcprivacy")
    let data = try Data(contentsOf: url)
    let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
    return try XCTUnwrap(plist as? [String: Any], "the manifest is not a plist dictionary")
  }

  /// The manifest ships because @B@arkey/@B@ is a synchronized root group: files added to the folder are
  /// part of the target without a project edit. If that ever changes, the manifest would silently
  /// stop being bundled, and this says so.
  func testTheManifestShipsWithTheTargetThatOwnsIt() throws {
    let manifest = repositoryRoot.appendingPathComponent("arkey/PrivacyInfo.xcprivacy")
    XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path))

    let pbxproj = try String(contentsOf: repositoryRoot.appendingPathComponent("arkey.xcodeproj/project.pbxproj"),
                             encoding: .utf8)
    XCTAssertTrue(pbxproj.contains("PBXFileSystemSynchronizedRootGroup"),
                  "the project no longer uses synchronized groups, so the manifest needs wiring")
    XCTAssertTrue(pbxproj.contains("path = arkey;"),
                  "the app's own folder must be the synchronized one")
  }

  func testTheManifestParsesAndStatesNoTrackingAndNoCollection() throws {
    let manifest = try loadManifest()
    XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
    XCTAssertEqual((manifest["NSPrivacyTrackingDomains"] as? [String])?.count, 0,
                   "tracking domains only exist if tracking does")
    XCTAssertEqual((manifest["NSPrivacyCollectedDataTypes"] as? [Any])?.count, 0,
                   "the app collects nothing: user dictionaries stay in the user's own container")
  }

  func testEveryDeclaredAPIIsOneAppleDefinesAndCarriesAnApprovedReason() throws {
    let manifest = try loadManifest()
    let types = try XCTUnwrap(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
    XCTAssertFalse(types.isEmpty, "the code reads file metadata and disk space, so this cannot be empty")

    for entry in types {
      let category = try XCTUnwrap(entry["NSPrivacyAccessedAPIType"] as? String)
      let reasons = try XCTUnwrap(entry["NSPrivacyAccessedAPITypeReasons"] as? [String])
      XCTAssertFalse(reasons.isEmpty, category + " is declared with no reason")
      let approved = try XCTUnwrap(Self.approvedReasons[category],
                                   category + " is not a category Apple defines")
      for reason in reasons {
        XCTAssertTrue(approved.contains(reason),
                      reason + " is not an approved reason for " + category)
      }
    }
  }

  /// Which categories the code actually justifies. Kept next to the manifest's content so a new
  /// required-reason API in the engine has to be noticed here.
  func testTheDeclaredCategoriesAreTheOnesTheCodeUses() throws {
    let manifest = try loadManifest()
    let types = try XCTUnwrap(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
    let categories = Set(types.compactMap { $0["NSPrivacyAccessedAPIType"] as? String })

    XCTAssertEqual(categories, ["NSPrivacyAccessedAPICategoryFileTimestamp",
                                "NSPrivacyAccessedAPICategoryDiskSpace",
                                "NSPrivacyAccessedAPICategoryUserDefaults",
                                "NSPrivacyAccessedAPICategorySystemBootTime"])
    // Geometry diagnostics retain system uptime in user-initiated bug reports. Both processes
    // record it, so each bundle needs the same approved reason.
    for path in ["arkey/PrivacyInfo.xcprivacy", "ARKeyboard/PrivacyInfo.xcprivacy"] {
      let data = try Data(contentsOf: repositoryRoot.appendingPathComponent(path))
      let manifest = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any])
      let entries = try XCTUnwrap(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
      let bootTime = try XCTUnwrap(entries.first {
        $0["NSPrivacyAccessedAPIType"] as? String == "NSPrivacyAccessedAPICategorySystemBootTime"
      }, path)
      XCTAssertEqual(bootTime["NSPrivacyAccessedAPITypeReasons"] as? [String], ["3D61.1"], path)
    }
    XCTAssertFalse(categories.contains("NSPrivacyAccessedAPICategoryActiveKeyboards"),
                   "needsInputModeSwitchKey is the system telling us, not us asking for the list")

    // The two file-timestamp reasons are distinct and both used: the app's own containers, and the
    // archive the user picks.
    let fileTimestamp = try XCTUnwrap(types.first {
      $0["NSPrivacyAccessedAPIType"] as? String == "NSPrivacyAccessedAPICategoryFileTimestamp"
    })
    let reasons = Set(try XCTUnwrap(fileTimestamp["NSPrivacyAccessedAPITypeReasons"] as? [String]))
    XCTAssertEqual(reasons, ["C617.1", "3B52.1"])

    // The keyboard's own settings live in the app group's UserDefaults, so the reason is the
    // app-group one — not CA92.1, which would claim the app's private defaults.
    let userDefaults = try XCTUnwrap(types.first {
      $0["NSPrivacyAccessedAPIType"] as? String == "NSPrivacyAccessedAPICategoryUserDefaults"
    })
    XCTAssertEqual(try XCTUnwrap(userDefaults["NSPrivacyAccessedAPITypeReasons"] as? [String]),
                   ["1C8F.1"])
  }

  /// The scan the other tests only claim. Each required-reason category has patterns that make code use it,
  /// the sources are read with comments stripped, and the categories found are compared with the ones
  /// declared — in both directions, because both mistakes are real: a manifest that under-declares is a
  /// rejection, and one that over-declares is a false statement about the app.
  func testTheScanFindsExactlyTheCategoriesTheManifestDeclares() throws {
    let used = try categoriesUsedInSources()
    let manifest = try loadManifest()
    let types = try XCTUnwrap(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
    let declared = Set(types.compactMap { $0["NSPrivacyAccessedAPIType"] as? String })

    XCTAssertEqual(used, declared,
                   "the manifest and the code disagree: used " + used.sorted().joined(separator: ", "))
    XCTAssertEqual(used, ["NSPrivacyAccessedAPICategoryFileTimestamp",
                          "NSPrivacyAccessedAPICategoryDiskSpace",
                          "NSPrivacyAccessedAPICategoryUserDefaults",
                          "NSPrivacyAccessedAPICategorySystemBootTime"],
                   "and this is a scan that found something, not a scan that found nothing")
  }

  /// Every place our code lives, tests excluded: a test may name an API without using it.
  private static let sourceDirectories = ["Packages/RimeEngine/Sources", "arkey", "ARKeyboard", "KeyboardUI"]

  /// The API surface that makes a category apply. Deliberately broad: a false hit is reviewed by hand, a
  /// missed one is a rejected submission.
  private static let patterns: [String: [String]] = [
    "NSPrivacyAccessedAPICategoryFileTimestamp": ["attributesOfItem", "contentModificationDate",
                                                  "contentAccessDate", "creationDate", "modificationDate",
                                                  "fileModificationDate", "stat(", "fstat(", "getattrlist"],
    "NSPrivacyAccessedAPICategoryDiskSpace": ["volumeAvailableCapacity", "systemFreeSize", "systemSize",
                                              "statfs", "statvfs", "availableCapacityForImportantUsage"],
    "NSPrivacyAccessedAPICategoryUserDefaults": ["UserDefaults"],
    "NSPrivacyAccessedAPICategorySystemBootTime": ["systemUptime", "mach_absolute_time"],
    "NSPrivacyAccessedAPICategoryActiveKeyboards": ["activeInputModes"],
  ]

  private func categoriesUsedInSources() throws -> Set<String> {
    let fileManager = FileManager.default
    var used = Set<String>()
    var scanned = 0

    for directory in Self.sourceDirectories {
      let root = repositoryRoot.appendingPathComponent(directory, isDirectory: true)
      guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) else {
        continue
      }
      for case let url as URL in enumerator where url.pathExtension == "swift" {
        scanned += 1
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
          // Comments are where these names are *discussed*: the probe explains why it does not use the
          // system uptime, and a scan that counted that sentence would demand a declaration for it.
          let line = Self.withoutComment(String(raw))
          for (category, needles) in Self.patterns {
            if needles.contains(where: { line.contains($0) }) { used.insert(category) }
          }
        }
      }
    }

    XCTAssertGreaterThan(scanned, 50, "the scan has to have found the sources")
    return used
  }

  private static func withoutComment(_ line: String) -> String {
    guard let range = line.range(of: "//") else { return line }
    let before = line[line.startIndex..<range.lowerBound]
    if before.hasSuffix(":") { return line }
    return String(before)
  }
}
