import Foundation
import Rime

// MARK: - The notification relay

/// Holds librime's notifications for the engine.
///
/// The trampoline runs on whichever thread librime notifies from — the maintenance thread during
/// a deploy — so it must not touch the engine's serial queue: the queue is blocked in
/// `join_maintenance_thread` at exactly that moment, and a synchronous hop would deadlock the
/// deploy. A lock-protected buffer plus a handler invoked outside the lock is enough.
final class NotificationRelay: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [RimeNotification] = []
  private var handler: (@Sendable (RimeNotification) -> Void)?

  func deliver(_ notification: RimeNotification) {
    lock.lock()
    storage.append(notification)
    let handler = self.handler
    lock.unlock()
    handler?(notification)
  }

  func snapshot() -> [RimeNotification] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  func removeAll() {
    lock.lock()
    defer { lock.unlock() }
    storage.removeAll()
  }

  func setHandler(_ handler: (@Sendable (RimeNotification) -> Void)?) {
    lock.lock()
    defer { lock.unlock() }
    self.handler = handler
  }
}

private func rimeNotificationTrampoline(context: UnsafeMutableRawPointer?,
                                        sessionID: RimeSessionId,
                                        messageType: UnsafePointer<CChar>?,
                                        messageValue: UnsafePointer<CChar>?) {
  guard let context else { return }
  let relay = Unmanaged<NotificationRelay>.fromOpaque(context).takeUnretainedValue()
  let type = messageType.map { String(cString: $0) } ?? ""
  let value = messageValue.map { String(cString: $0) } ?? ""
  relay.deliver(RimeNotification.parse(type: type, value: value))
}

private func rimeLogSinkTrampoline(context: UnsafeMutableRawPointer?,
                                   record: UnsafePointer<rime_logsink_record>?) {
  guard let context, let record else { return }
  let buffer = Unmanaged<RimeLogBuffer>.fromOpaque(context).takeUnretainedValue()
  let pointer = record.pointee
  let message: String
  if let text = pointer.message {
    let length = pointer.message_length
    message = String(decoding: UnsafeRawBufferPointer(start: text, count: length), as: UTF8.self)
  } else {
    message = ""
  }
  let severity: RimeLogSeverity
  switch pointer.severity {
  case .warning: severity = .warning
  case .error: severity = .error
  case .fatal: severity = .fatal
  case .info: severity = .info
  @unknown default: severity = .info
  }
  let timestamp = Date(timeIntervalSince1970: Double(pointer.unix_time_millis) / 1000.0)
  buffer.append(RimeLogRecord(severity: severity,
                              message: message,
                              file: pointer.base_filename.map { String(cString: $0) } ?? "",
                              line: Int(pointer.line),
                              timestamp: timestamp))
}

// MARK: - Engine surface

extension RimeEngine {
  /// The directories this engine is currently bound to. The extension reads `active.json` and
  /// rebinds here before its first keystroke of an appearance.
  public var directories: RimeDirectories { perform { configuration.directories } }

  public var isRunning: Bool { perform { isStarted } }

  /// Records from the logsink module: librime's own text, including the reason a deploy failed.
  public var logBuffer: RimeLogBuffer { logs }

  public func setNotificationHandler(_ handler: (@Sendable (RimeNotification) -> Void)?) {
    notificationRelay.setHandler(handler)
  }

  public func notifications() -> [RimeNotification] {
    notificationRelay.snapshot()
  }

  // MARK: Lifecycle

  /// Rebinds the engine to another set of directories: `finalize()`, then `setup()` and
  /// `initialize()` with the new traits. Verified against the pinned build to take effect in one
  /// process. Exclusive: any open session is closed first, because librime cannot switch data
  /// directories underneath a live session.
  @discardableResult
  public func rebind(to directories: RimeDirectories) throws -> RimeProbeRecord {
    try perform {
      try withDictionaryOwnership(store: dictionaryLeaseStore, host: dictionaryHost) {
        try rebindLocked(to: directories)
      }
    }
  }

  func rebindLocked(to directories: RimeDirectories) throws -> RimeProbeRecord {
    teardownLocked()
    configuration.directories = directories
    let record = try startLocked(force: true)
    return record
  }

  /// Tears librime down without leaving the engine unusable: the next `start()` or
  /// `rebind(to:)` reinitialises it.
  func teardownLocked() {
    dictionaryOwnershipDepth += 1
    defer {
      dictionaryOwnershipDepth -= 1
      releaseDictionaryOwnershipIfIdle()
    }
    closeSessionLocked()
    detachNotificationHandlerLocked()
    removeLogSinkLocked()
    if isStarted {
      api?.pointee.finalize?()
    }
    api = nil
    isStarted = false
    allocatedStrings = []
  }

  /// A deployment destroys the native session. Keep the user-visible state so a failed
  /// transaction can recreate it, without committing or replaying keystrokes.
  struct RuntimeState {
    let directories: RimeDirectories
    let running: Bool
    let hadSession: Bool
    let schema: String?
    let options: [String: Bool]
    let input: String
    let caret: Int
  }

  func captureRuntime() throws -> RuntimeState {
    var schema: String?
    var options: [String: Bool] = [:]
    var input = ""
    var caret = 0
    if session != nil {
      schema = try currentSchema()
      var names: Set<String> = ["ascii_mode", "full_shape", "simplification",
                                "traditionalization", "ascii_punct"]
      if let schema {
        let switches = try withSchemaConfig(schema) { $0.value("switches") }?.listValue ?? []
        for entry in switches {
          if let name = entry.mapValue?["name"]?.stringValue { names.insert(name) }
          for name in entry.mapValue?["options"]?.listValue ?? [] {
            if let name = name.stringValue { names.insert(name) }
          }
        }
      }
      for name in names { options[name] = try getOption(name) }
      input = try rawInput() ?? ""
      caret = try caretPosition()
    }
    return RuntimeState(directories: configuration.directories, running: isStarted,
                        hadSession: session != nil, schema: schema, options: options,
                        input: input, caret: caret)
  }

  func restoreRuntime(_ state: RuntimeState) throws {
    teardownLocked()
    configuration.directories = state.directories
    if state.running { _ = try startLocked(force: true) }
    if state.hadSession {
      try openSession()
      if let schema = state.schema { _ = try selectSchema(schema) }
      for (name, value) in state.options { try setOption(name, value) }
      if !state.input.isEmpty { _ = try setInput(state.input) }
      try setCaretPosition(state.caret)
    }
  }

  // MARK: Logsink

  func installLogSinkLocked() {
    guard !isLogSinkInstalled else { return }
    guard let module = RimeFindModule("logsink"),
          let getAPI = module.pointee.get_api,
          let custom = getAPI() else { return }
    let sink = UnsafeMutableRawPointer(custom).assumingMemoryBound(to: RimeLogSinkApi.self)
    guard sink.pointee.data_size >= 0, let addSink = sink.pointee.add_sink else { return }
    let context = Unmanaged.passUnretained(logs).toOpaque()
    guard addSink(context, rimeLogSinkTrampoline) else { return }
    logSinkAPI = sink
    logSinkContext = context
    isLogSinkInstalled = true
  }

  func removeLogSinkLocked() {
    guard isLogSinkInstalled, let sink = logSinkAPI, let context = logSinkContext else { return }
    _ = sink.pointee.remove_sink?(context)
    isLogSinkInstalled = false
    logSinkAPI = nil
    logSinkContext = nil
  }

  /// True when the pinned build exposes the logsink module, which is what makes a deploy failure
  /// carry librime's own text instead of a generic error.
  public static var isLogSinkAvailable: Bool {
    RimeFindModule("logsink") != nil
  }

  /// True when the pinned build exposes the levers module (schema list, user-dictionary export).
  public static var isLeversAvailable: Bool {
    RimeFindModule("levers") != nil
  }

  func installNotificationHandlerLocked() {
    guard let api, let setHandler = api.pointee.set_notification_handler else { return }
    let context = Unmanaged.passUnretained(notificationRelay).toOpaque()
    setHandler(rimeNotificationTrampoline, context)
  }

  func detachNotificationHandlerLocked() {
    api?.pointee.set_notification_handler?(nil, nil)
  }

  /// Waits for librime's maintenance thread. `sync_user_data` schedules work the way
  /// `start_maintenance` does, and the files are on disk only once that work has run — Squirrel
  /// calls the two together, and so must anything that wants the snapshot afterwards.
  public func joinMaintenance() {
    perform {
      guard let api, let join = api.pointee.join_maintenance_thread else { return }
      join()
    }
  }

  /// True while librime says a maintenance task is running.
  public var isInMaintenanceMode: Bool {
    perform { api?.pointee.is_maintenance_mode?() ?? false }
  }

  // MARK: Schemas

  public func schemas() throws -> [RimeSchema] {
    try perform {
      let api = try requireAPI()
      guard let getList = api.pointee.get_schema_list,
            let freeList = api.pointee.free_schema_list else {
        throw RimeEngineError.apiUnavailable
      }
      var list = RimeSchemaList()
      guard getList(&list) else { return [] }
      defer { freeList(&list) }
      var schemas: [RimeSchema] = []
      if let items = list.list {
        for index in 0..<Int(list.size) {
          let item = items[index]
          schemas.append(RimeSchema(id: item.schema_id.map { String(cString: $0) } ?? "",
                                    name: item.name.map { String(cString: $0) } ?? ""))
        }
      }
      return schemas
    }
  }

  public func schemaIDs() throws -> [String] {
    try schemas().map(\.id)
  }

  /// The schema the live session is on, or nil when no session is open.
  public func currentSchema() throws -> String? {
    try perform {
      let api = try requireAPI()
      guard let session, let getCurrent = api.pointee.get_current_schema else { return nil }
      var buffer = [CChar](repeating: 0, count: 256)
      guard getCurrent(session, &buffer, buffer.count) else { return nil }
      return String(cString: buffer)
    }
  }

  /// Switches the live session to another deployed schema. Instant: no deployment involved.
  @discardableResult
  public func selectSchema(_ schemaID: String) throws -> RimeOutput {
    try perform {
      let api = try requireAPI()
      let session = try requireSession(api: api)
      guard let select = api.pointee.select_schema else { throw RimeEngineError.apiUnavailable }
      let box = CStringBox(schemaID)
      guard select(session, box.raw) else {
        throw RimeEngineError.schemaSelectionFailed(schemaID)
      }
      return readOutput(api: api, session: session, handled: false)
    }
  }

  // MARK: Deployment

  /// Deploys a profile: rebinds to its staging layout, runs librime's maintenance thread and
  /// reports what came out. The blocking form; the app uses `deploy(binding:fullCheck:progress:)`.
  ///
  /// Never called from the extension: librime's maintenance takes tens of seconds on a real
  /// config, longer than a keyboard extension is allowed to live.
  public func deploySync(binding directories: RimeDirectories,
                         fullCheck: Bool = true,
                         progress: (@Sendable (RimeDeploymentProgress) -> Void)? = nil) throws -> RimeDeploymentReport {
    progress?(RimeDeploymentProgress(phase: .binding, message: directories.sharedDataDir))
    return try perform {
      try withDictionaryOwnership(store: dictionaryLeaseStore, host: dictionaryHost) {
        let started = Date()
        logs.removeAll()
        notificationRelay.removeAll()

        _ = try rebindLocked(to: directories)

        guard let api, let startMaintenance = api.pointee.start_maintenance else {
          throw RimeEngineError.deploymentFailed
        }
        progress?(RimeDeploymentProgress(phase: .running,
                                         message: "start_maintenance(full_check: " + String(fullCheck) + ")"))
        // Snapshot taken after the caller seeded staging and before librime runs: whatever moves from
        // here on is this deploy's own work.
        let before = RimeEngine.fingerprints(in: directories.prebuiltDataDir)
        let scheduled = startMaintenance(fullCheck)
        if scheduled, let join = api.pointee.join_maintenance_thread {
          join()
        }

        let notifications = notificationRelay.snapshot()
        let didFail = notifications.contains { notification in
          if case .deploy(.failure) = notification { return true }
          return false
        }
        let files = RimeEngine.buildFiles(in: directories.prebuiltDataDir)
        let changes = RimeEngine.changes(before: before,
                                         after: RimeEngine.fingerprints(in: directories.prebuiltDataDir))
        var failureReason: String?
        if didFail {
          failureReason = "librime reported a deploy failure"
        } else if files.isEmpty {
          failureReason = "the deploy produced no files in " + directories.prebuiltDataDir
        } else {
          do {
            let unusable = try unusableDeployedSchemaIDs()
            if !unusable.isEmpty {
              failureReason = "Missing or empty deployed schemas: " + unusable.joined(separator: ", ")
            }
          } catch {
            failureReason = "Cannot validate deployed schemas: " + String(describing: error)
          }
        }
        let succeeded = failureReason == nil
        let report = RimeDeploymentReport(directories: directories,
                                          fullCheck: fullCheck,
                                          succeeded: succeeded,
                                          duration: Date().timeIntervalSince(started),
                                          files: files,
                                          changes: changes,
                                          notifications: notifications,
                                          logs: logs.snapshot(),
                                          failureReason: failureReason)
        let phases: [RimeDeploymentProgress.Phase] = [succeeded ? .succeeded : .failed]
        for phase in phases {
          progress?(RimeDeploymentProgress(phase: phase,
                                           message: failureReason ?? String(files.count) + " files"))
        }
        _ = record(phase: "engine.deploy",
                   start: 0,
                   message: (succeeded ? "ok " : "failed ") + String(format: "%.0f ms", report.duration * 1000)
                     + " files=" + String(files.count))
        if !succeeded {
          throw RimeDeploymentError(report: report)
        }
        return report
      }
    }
  }

  /// The asynchronous form the app calls: deployment blocks for tens of seconds and must not
  /// block the caller's thread.
  public func deploy(binding directories: RimeDirectories,
                     fullCheck: Bool = true,
                     progress: (@Sendable (RimeDeploymentProgress) -> Void)? = nil) async throws -> RimeDeploymentReport {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          let report = try self.deploySync(binding: directories, fullCheck: fullCheck, progress: progress)
          continuation.resume(returning: report)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  /// Every file under a directory with the two things a rewrite moves: its size and its mtime. Used to
  /// see what a deploy actually wrote (S1 §6): the generation's file list cannot tell a rebuild from a
  /// "workspace already up to date" run, and the measured difference between them is exactly this.
  static func fingerprints(in path: String) -> [String: RimeFileFingerprint] {
    let fileManager = FileManager.default
    let root = URL(fileURLWithPath: path)
    guard let enumerator = fileManager.enumerator(
      at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
      options: [.skipsHiddenFiles]) else { return [:] }
    var result: [String: RimeFileFingerprint] = [:]
    let rootPath = root.standardizedFileURL.path
    for case let url as URL in enumerator {
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey,
                                                    .contentModificationDateKey])
      guard values?.isRegularFile == true else { continue }
      let full = url.standardizedFileURL.path
      let relative = full.hasPrefix(rootPath + "/") ? String(full.dropFirst(rootPath.count + 1)) : full
      result[relative] = RimeFileFingerprint(bytes: UInt64(values?.fileSize ?? 0),
                                             modifiedAt: values?.contentModificationDate ?? .distantPast)
    }
    return result
  }

  static func changes(before: [String: RimeFileFingerprint],
                      after: [String: RimeFileFingerprint]) -> RimeDeploymentChanges {
    var added: [String] = []
    var changed: [String] = []
    var removed: [String] = []
    for (path, fingerprint) in after {
      guard let previous = before[path] else {
        added.append(path)
        continue
      }
      if previous != fingerprint { changed.append(path) }
    }
    for path in before.keys where after[path] == nil { removed.append(path) }
    return RimeDeploymentChanges(added: added, changed: changed, removed: removed)
  }

  /// Every file under a build directory, with sizes. The deploy screen shows the count and the
  /// release script uses this to prove what a build contains.
  public static func buildFiles(in path: String) -> [RimeBuildFile] {
    let fileManager = FileManager.default
    let root = URL(fileURLWithPath: path)
    guard let enumerator = fileManager.enumerator(at: root,
                                                  includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                                  options: [.skipsHiddenFiles]) else {
      return []
    }
    var files: [RimeBuildFile] = []
    let rootPath = root.standardizedFileURL.path
    for case let url as URL in enumerator {
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      guard values?.isRegularFile == true else { continue }
      let full = url.standardizedFileURL.path
      let relative = full.hasPrefix(rootPath + "/") ? String(full.dropFirst(rootPath.count + 1)) : full
      files.append(RimeBuildFile(relativePath: relative, bytes: values?.fileSize ?? 0))
    }
    return files.sorted { $0.relativePath < $1.relativePath }
  }
}
