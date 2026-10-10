import XCTest
@testable import RimeEngine

/// S1 §10's macOS list: the layout rules, the launch janitor, the resolver's degraded modes and
/// the storage policy. All of it is file-system logic, so none of it needs a device.
final class S1WorkspaceTests: XCTestCase {
  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private var tracerData: URL {
    repositoryRoot.appendingPathComponent("RimeData", isDirectory: true)
  }

  private func makeWorkspace() throws -> RimeWorkspace {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkey-s1-workspace", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return try RimeWorkspace(root: root).createDirectories()
  }

  /// A profile that looks deployed: a source, a build with one table, and metadata.
  @discardableResult
  private func installProfile(_ workspace: RimeWorkspace, id: String, generation: Int = 1,
                              withBuild: Bool = true, withPrevious: Bool = false) throws -> RimeProfileLayout {
    let layout = workspace.profile(id)
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: layout.source, withIntermediateDirectories: true)
    try fileManager.copyItem(at: tracerData.appendingPathComponent("default.yaml"),
                             to: layout.source.appendingPathComponent("default.yaml"))
    try fileManager.copyItem(at: tracerData.appendingPathComponent("tracer.schema.yaml"),
                             to: layout.source.appendingPathComponent("tracer.schema.yaml"))
    try fileManager.copyItem(at: tracerData.appendingPathComponent("tracer.dict.yaml"),
                             to: layout.source.appendingPathComponent("tracer.dict.yaml"))
    if withBuild {
      try fileManager.createDirectory(at: layout.build, withIntermediateDirectories: true)
      try Data("table".utf8).write(to: layout.build.appendingPathComponent("tracer.table.bin"))
    }
    if withPrevious {
      try fileManager.createDirectory(at: layout.buildPrevious, withIntermediateDirectories: true)
      try Data("previous".utf8).write(to: layout.buildPrevious.appendingPathComponent("tracer.prism.bin"))
    }
    let metadata = RimeProfileMetadata(id: id,
                                       displayName: "Tracer",
                                       source: RimeProfileSource(kind: .bundled),
                                       license: RimeProfileLicense(spdx: "MIT", name: "MIT License"),
                                       stats: RimeProfileStats(fileCount: 3, sourceBytes: 1024,
                                                               buildBytes: 5, schemaIDs: ["tracer"]),
                                       deploy: RimeProfileDeployRecord(generation: generation,
                                                                       deployedAt: Date(),
                                                                       engineVersion: RimeEngineVersion.pinned,
                                                                       durationSeconds: 0.5))
    try workspace.writeMetadata(metadata)
    return layout
  }

  // MARK: Identity

  func testProfileIdentifierIsStableAndContentAddressed() {
    let digest = String(repeating: "a1b2c3d4", count: 8)
    let first = RimeProfileIdentifier.make(displayName: "雾凇拼音", tag: "nightly", digest: digest)
    let second = RimeProfileIdentifier.make(displayName: "雾凇拼音", tag: "nightly", digest: digest)
    XCTAssertEqual(first, second)
    XCTAssertTrue(first.hasSuffix("-a1b2c3d4a1b2c3d4"), first)
    XCTAssertFalse(first.contains(" "), first)

    // Non-ASCII names cannot slug to nothing.
    let unnamed = RimeProfileIdentifier.make(displayName: "雾凇拼音", tag: nil, digest: digest)
    XCTAssertFalse(unnamed.isEmpty)
    XCTAssertTrue(unnamed.hasSuffix("-a1b2c3d4a1b2c3d4"), unnamed)

    // Different content never collides.
    let other = RimeProfileIdentifier.make(displayName: "雾凇拼音", tag: "nightly",
                                           digest: String(repeating: "ffffffff", count: 8))
    XCTAssertNotEqual(first, other)
  }

  /// A `meta.json` that cannot be parsed is **named**, not skipped: a profile that quietly vanishes
  /// from the library looks like the user's configuration was deleted, which is why the loader throws
  /// with the id in the message instead of returning nil. Nothing pinned that choice until round 128.
  func testACorruptMetadataFileIsNamedRatherThanSkipped() throws {
    let workspace = try makeWorkspace()
    let layout = try installProfile(workspace, id: "tracer-1", generation: 1)
    try Data("this is not metadata".utf8).write(to: layout.metadata)

    XCTAssertThrowsError(try workspace.loadMetadataList()) { error in
      guard case RimeWorkspaceError.metadataUnreadable(let id, let reason) = error else {
        return XCTFail("expected metadataUnreadable, got " + String(describing: error))
      }
      XCTAssertEqual(id, "tracer-1", "the message has to name which profile is broken")
      XCTAssertFalse(reason.isEmpty)
    }
    XCTAssertThrowsError(try workspace.loadMetadata(for: "tracer-1"))

    // A profile that is simply not there is not an error: the list is built from the directories.
    XCTAssertNil(try workspace.loadMetadata(for: "never-imported"))
  }

  // MARK: Metadata round trip

  func testMetadataAndActiveRecordRoundTripThroughJSON() throws {
    let workspace = try makeWorkspace()
    let layout = try installProfile(workspace, id: "tracer-20260923-abcd1234", generation: 3)

    let metadata = try XCTUnwrap(try workspace.loadMetadata(for: "tracer-20260923-abcd1234"))
    XCTAssertEqual(metadata.displayName, "Tracer")
    XCTAssertEqual(metadata.stats.schemaIDs, ["tracer"])
    XCTAssertEqual(metadata.deploy?.generation, 3)
    XCTAssertEqual(metadata.license?.spdx, "MIT")
    XCTAssertEqual(metadata.schemaVersion, RimeProfileMetadata.currentSchemaVersion)
    XCTAssertTrue(FileManager.default.fileExists(atPath: layout.metadata.path))

    let active = RimeActiveProfile(profileID: "tracer-20260923-abcd1234", generation: 3,
                                   sourceDigest: "sha256:deadbeef", previousProfileID: nil)
    try workspace.writeActiveProfile(active)
    let reloaded = try XCTUnwrap(try workspace.loadActiveProfile())
    XCTAssertEqual(reloaded.profileID, active.profileID)
    XCTAssertEqual(reloaded.generation, 3)
    XCTAssertTrue(reloaded.isCompatible)
  }

  func testActiveRecordRejectsANewerSchemaVersion() throws {
    let workspace = try makeWorkspace()
    let future = """
    {"schemaVersion": 99, "profileID": "x", "generation": 1, "deployedAt": "2026-09-23T14:40:04Z",
     "engineVersion": "1.17.0"}
    """
    try Data(future.utf8).write(to: workspace.activeRecord)
    let record = try XCTUnwrap(try workspace.loadActiveProfile())
    XCTAssertFalse(record.isCompatible, "a newer schemaVersion must be refused, not guessed at")
  }

  // MARK: Resolution

  func testResolverRejectsAnIncompatibleEngineBeforeUsingEitherBuild() throws {
    let workspace = try makeWorkspace()
    let layout = try installProfile(workspace, id: "tracer-1", withPrevious: true)
    let compatible = RimeWorkspaceResolver.resolve(workspace: workspace, bundledSharedData: tracerData)
    try workspace.writeActiveProfile(RimeActiveProfile(profileID: "tracer-1", generation: 1,
                                                       engineVersion: "1.16.0"))

    for usePrevious in [false, true] {
      if usePrevious { try FileManager.default.removeItem(at: layout.build) }
      let resolved = RimeWorkspaceResolver.resolve(workspace: workspace, bundledSharedData: tracerData)
      XCTAssertEqual(resolved.origin, .bundled)
      XCTAssertNil(resolved.profileID)
      XCTAssertNil(resolved.generation)
      XCTAssertEqual(resolved.directories, compatible.directories)
      XCTAssertEqual(resolved.fallbackReason,
                     "active.json engineVersion 1.16.0 is incompatible with this engine "
                       + RimeEngineVersion.pinned)
    }
  }

  func testResolverFallsBackThroughEveryState() throws {
    let workspace = try makeWorkspace()
    let layout = try installProfile(workspace, id: "tracer-1", generation: 2)
    try workspace.writeActiveProfile(RimeActiveProfile(profileID: "tracer-1", generation: 2))

    // 1. An active profile with a build binds to it.
    let active = RimeWorkspaceResolver.resolve(workspace: workspace, bundledSharedData: tracerData)
    XCTAssertEqual(active.origin, .container)
    XCTAssertEqual(active.profileID, "tracer-1")
    XCTAssertEqual(active.buildDirectory.path, layout.build.path)
    XCTAssertNil(active.fallbackReason)
    XCTAssertEqual(active.directories.sharedDataDir, layout.source.path)
    XCTAssertEqual(active.directories.userDataDir, workspace.userData.path)

    // 2. A missing build falls back to build.previous, and says so.
    try FileManager.default.removeItem(at: layout.build)
    try FileManager.default.createDirectory(at: layout.buildPrevious, withIntermediateDirectories: true)
    try Data("previous".utf8).write(to: layout.buildPrevious.appendingPathComponent("tracer.table.bin"))
    let previous = RimeWorkspaceResolver.resolve(workspace: workspace, bundledSharedData: tracerData)
    XCTAssertEqual(previous.profileID, "tracer-1")
    XCTAssertEqual(previous.buildDirectory.path, layout.buildPrevious.path)
    XCTAssertEqual(previous.fallbackReason, "the active build is missing or empty; using build.previous")

    // 3. No usable build at all falls back to the bundle.
    try FileManager.default.removeItem(at: layout.buildPrevious)
    let bundled = RimeWorkspaceResolver.resolve(workspace: workspace, bundledSharedData: tracerData)
    XCTAssertEqual(bundled.origin, .bundled)
    XCTAssertEqual(bundled.directories.sharedDataDir, tracerData.path)
    XCTAssertEqual(bundled.fallbackReason, "profile 'tracer-1' has no usable build")

    // 4. No active.json at all: the keyboard still types, with the bundled data.
    try workspace.removeActiveProfile()
    let fresh = RimeWorkspaceResolver.resolve(workspace: workspace, bundledSharedData: tracerData)
    XCTAssertEqual(fresh.origin, .bundled)
    XCTAssertEqual(fresh.fallbackReason, "no active.json")

    // 5. No app group: degraded, and named.
    let noGroup = RimeWorkspaceResolver.resolve(workspace: workspace, bundledSharedData: tracerData,
                                                appGroupAvailable: false)
    XCTAssertEqual(noGroup.origin, .bundled)
    XCTAssertEqual(noGroup.fallbackReason, "the app group is unreachable")
  }

  func testAnEmptyBuildDirectoryIsNotUsable() throws {
    let workspace = try makeWorkspace()
    let layout = try installProfile(workspace, id: "tracer-empty", withBuild: false)
    try workspace.writeActiveProfile(RimeActiveProfile(profileID: "tracer-empty", generation: 1))
    try FileManager.default.createDirectory(at: layout.build, withIntermediateDirectories: true)

    let resolved = RimeWorkspaceResolver.resolve(workspace: workspace, bundledSharedData: tracerData)
    XCTAssertEqual(resolved.origin, .bundled,
                   "an empty build is what a killed deploy leaves; binding to it types nothing")
  }

  // MARK: Janitor

  func testJanitorRemovesStagingAndAKilledDeploy() throws {
    let workspace = try makeWorkspace()
    let layout = try installProfile(workspace, id: "tracer-1")
    let fileManager = FileManager.default

    // A killed deploy: build.staging with tables in it, and staging holding an unpack.
    try fileManager.createDirectory(at: layout.buildStaging, withIntermediateDirectories: true)
    try Data("half".utf8).write(to: layout.buildStaging.appendingPathComponent("tracer.table.bin"))
    let unpack = workspace.staging.appendingPathComponent("2F0A/unpack", isDirectory: true)
    try fileManager.createDirectory(at: unpack, withIntermediateDirectories: true)
    try Data("half".utf8).write(to: unpack.appendingPathComponent("default.yaml"))

    let outcome = RimeWorkspaceJanitor().run(workspace: workspace)
    XCTAssertFalse(fileManager.fileExists(atPath: layout.buildStaging.path))
    XCTAssertEqual(outcome.removedBuildStaging, ["tracer-1"])
    XCTAssertFalse(fileManager.fileExists(atPath: workspace.staging.appendingPathComponent("2F0A").path))
    XCTAssertEqual(outcome.removedStagingEntries, ["2F0A"])

    // The deployed build is untouched: the janitor repairs, it does not reset.
    XCTAssertTrue(fileManager.fileExists(atPath: layout.build.path))
  }

  func testJanitorRestoresAPreviousGenerationWhenTheBuildIsGone() throws {
    let workspace = try makeWorkspace()
    let layout = try installProfile(workspace, id: "tracer-1", withBuild: false, withPrevious: true)
    try workspace.writeActiveProfile(RimeActiveProfile(profileID: "tracer-1", generation: 2))

    let outcome = RimeWorkspaceJanitor().run(workspace: workspace)
    XCTAssertEqual(outcome.restoredBuilds, ["tracer-1"])
    XCTAssertTrue(FileManager.default.fileExists(atPath: layout.build.appendingPathComponent("tracer.prism.bin").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: layout.buildPrevious.path))

    // And the resolved engine now finds a usable profile instead of the bundle.
    let resolved = RimeWorkspaceResolver.resolve(workspace: workspace, bundledSharedData: tracerData)
    XCTAssertEqual(resolved.profileID, "tracer-1")
  }

  // MARK: Installation

  func testInstallationSeedingNeverOverwritesAnExistingID() throws {
    let workspace = try makeWorkspace()
    let sync = workspace.root.appendingPathComponent("sync", isDirectory: true)
    let first = try workspace.seedInstallation(syncDirectory: sync, installationID: "AAAA")
    XCTAssertEqual(first.installationID, "AAAA")
    XCTAssertTrue(sync.path.hasPrefix("/"), "sync_dir must be absolute: librime accepts a relative one silently")

    let second = try workspace.seedInstallation(syncDirectory: sync, installationID: "BBBB")
    XCTAssertEqual(second.installationID, "AAAA",
                   "an installation id is per install; sharing one across devices is what creates conflict copies")

    let reloaded = try XCTUnwrap(workspace.loadInstallation())
    XCTAssertEqual(reloaded.syncDirectory, sync.path)
    XCTAssertEqual(workspace.userSyncDirectory.lastPathComponent, "AAAA")
  }

  // MARK: Versioning (S6 §4)

  /// S6 §4: "the app version and the librime version are recorded in every profile's meta.json and shown
  /// in diagnostics". The engine's was there; the app's was nowhere in the tree.
  func testTheAppVersionTravelsWithTheProfileAndOlderFilesStillDecode() throws {
    let record = RimeProfileDeployRecord(generation: 2, deployedAt: Date(), engineVersion: "1.17.0",
                                         appVersion: "1.0 (7)", durationSeconds: 1.5)
    let metadata = RimeProfileMetadata(id: "tracer-1", displayName: "Tracer",
                                       source: RimeProfileSource(kind: .files), deploy: record)
    let data = try RimeJSON.encode(metadata)
    XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("1.0 (7)"),
                  "meta.json has to carry it: " + String(decoding: data, as: UTF8.self))
    XCTAssertEqual(try RimeJSON.decode(RimeProfileMetadata.self, from: data).deploy?.appVersion,
                   "1.0 (7)")

    let pointer = RimeActiveProfile(profileID: "tracer-1", generation: 2, appVersion: "1.0 (7)")
    let pointerData = try RimeJSON.encode(pointer)
    XCTAssertEqual(try RimeJSON.decode(RimeActiveProfile.self, from: pointerData).appVersion,
                   "1.0 (7)")

    // A file written before the field existed must keep decoding: the keyboard reads active.json at
    // boot, and a decode failure there is a keyboard that does not appear.
    let legacy = #"{"schemaVersion":1,"profileID":"tracer-1","generation":1,"#
      + #""deployedAt":"2026-01-01T00:00:00Z","engineVersion":"1.17.0"}"#
    let active = try RimeJSON.decode(RimeActiveProfile.self, from: Data(legacy.utf8))
    XCTAssertEqual(active.profileID, "tracer-1")
    XCTAssertNil(active.appVersion)
  }

  /// A corrupt `installation.yaml` must not silently mint a new installation id: that moves the
  /// device's sync subdirectory, so its own earlier snapshots start looking like another device's.
  func testAnUnreadableInstallationFileIsQuarantinedRatherThanSilentlyReplaced() throws {
    let workspace = try makeWorkspace()
    let record = workspace.installationRecord
    try FileManager.default.createDirectory(at: record.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    // An id with no sync_dir: the file is there, and it does not parse.
    try Data("installation_id: MAC\n".utf8).write(to: record)
    let unreadable = try Data(contentsOf: record)

    let seeded = try workspace.seedInstallation(syncDirectory: URL(fileURLWithPath: "/tmp/arkey-sync"))
    XCTAssertEqual(workspace.loadInstallation()?.installationID, seeded.installationID,
                   "the workspace is usable again")

    let quarantine = workspace.quarantinedInstallationURL
    XCTAssertTrue(FileManager.default.fileExists(atPath: quarantine.path),
                  "the unreadable file is moved aside, not overwritten")
    XCTAssertEqual(try Data(contentsOf: quarantine), unreadable,
                   "and its bytes are kept, so the id can be recovered by hand")
  }

  // MARK: Storage

  func testStorageReportAccountsForEachProfileAndTheUserDirectory() throws {
    let workspace = try makeWorkspace()
    try installProfile(workspace, id: "a", withPrevious: true)
    try installProfile(workspace, id: "b")
    try Data(repeating: 0x41, count: 2048).write(to: workspace.userData.appendingPathComponent("x.userdb"))

    let report = try workspace.storageReport()
    XCTAssertEqual(report.profiles.map(\.id), ["a", "b"])
    XCTAssertEqual(report.profiles[0].previousBuildBytes, 8)
    XCTAssertEqual(report.profiles[0].schemaCount, 1)
    XCTAssertEqual(report.profiles[0].license, "MIT")
    XCTAssertGreaterThanOrEqual(report.userDataBytes, 2048)
    XCTAssertGreaterThan(report.totalBytes, 2048)
  }

  func testDeletingAProfileKeepsUserDictionariesUnlessAskedForThem() throws {
    let workspace = try makeWorkspace()
    try installProfile(workspace, id: "a")
    try workspace.writeActiveProfile(RimeActiveProfile(profileID: "a", generation: 1))
    let database = workspace.userData.appendingPathComponent("tracer.userdb", isDirectory: true)
    try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)

    try workspace.deleteProfile("a")
    XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.profile("a").directory.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: database.path),
                  "a learned dictionary belongs to a dictionary name, not to the profile that produced it")
    XCTAssertNil(try workspace.loadActiveProfile(), "deleting the active profile clears the pointer")

    try installProfile(workspace, id: "b")
    try workspace.deleteProfile("b", removingUserDictionaries: ["tracer"])
    XCTAssertFalse(FileManager.default.fileExists(atPath: database.path))
  }

  func testStoragePolicyExcludesDerivedArtifactsFromBackup() throws {
    let workspace = try makeWorkspace()
    let layout = try installProfile(workspace, id: "a", withPrevious: true)
    try workspace.applyStoragePolicy()

    for url in [layout.build, layout.buildPrevious, workspace.staging] {
      let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
      XCTAssertEqual(values.isExcludedFromBackup, true, url.lastPathComponent + " should not inflate a backup")
    }
  }

  // MARK: Bindings

  func testDeployerBindingUsesBuildStagingAndClientBindingUsesBuild() throws {
    let workspace = try makeWorkspace()
    let layout = try installProfile(workspace, id: "a")

    let deployer = RimeBindings.deployer(workspace: workspace, profileID: "a")
    XCTAssertEqual(deployer.sharedDataDir, layout.source.path)
    XCTAssertEqual(deployer.prebuiltDataDir, layout.buildStaging.path)
    XCTAssertEqual(deployer.stagingDir, layout.buildStaging.path,
                   "librime's deployer writes into staging_dir; both must point at build.staging")
    XCTAssertEqual(deployer.userDataDir, workspace.userData.path)

    let client = RimeBindings.client(workspace: workspace, profileID: "a", buildDirectory: layout.build)
    XCTAssertEqual(client.prebuiltDataDir, layout.build.path)
    XCTAssertEqual(client.stagingDir, layout.build.path,
                   "failed deployment output must not shadow the published schemas")
    XCTAssertEqual(client.sharedDataDir, layout.source.path)
  }
}
