import Foundation
import Rime

public struct RimeConfiguration: Sendable {
  public var directories: RimeDirectories
  public var distributionName: String
  public var distributionCodeName: String
  public var distributionVersion: String
  public var appName: String
  public var minLogLevel: Int32

  public init(directories: RimeDirectories,
              distributionName: String = "Arkey",
              distributionCodeName: String = "com.acehinnnqru.arkey",
              distributionVersion: String = "0.1.0",
              appName: String = "rime.arkey",
              minLogLevel: Int32 = 2) {
    self.directories = directories
    self.distributionName = distributionName
    self.distributionCodeName = distributionCodeName
    self.distributionVersion = distributionVersion
    self.appName = appName
    self.minLogLevel = minLogLevel
  }
}

/// The single serialisation domain for librime.
///
/// librime keeps process-global state and is not thread-safe, so one engine owns one dedicated
/// serial queue and every public method runs its body on it. Callers get an ordinary synchronous
/// call: no actor hop, no reordering, no per-keystroke latency. The keyboard calls this straight
/// from the main thread, where a key press is well under a millisecond.
///
/// This replaced an actor. The actor was correct but every key press paid two hops and the
/// ordering of concurrent keystrokes was left to the scheduler, which showed up as a keyboard
/// that felt laggy and occasionally dropped input.
public final class RimeEngine {
  let queue = DispatchQueue(label: "com.acehinnnqru.arkey.rime-engine")
  /// Identifies the engine's own queue, so a call made from inside it can be detected.
  private static let queueKey = DispatchSpecificKey<UInt8>()
  var configuration: RimeConfiguration
  let probeLog: RimeProbeLog?
  var records: [RimeProbeRecord] = []
  var allocatedStrings: [CStringBox] = []
  var api: UnsafeMutablePointer<rime_api_t>?
  var session: RimeSessionId?
  var isStarted = false

  /// librime's own log text, captured through the logsink module (§S1). Shared with the keyboard
  /// extension's diagnostics screen and the app's deploy-failure screen.
  let logs = RimeLogBuffer()
  let notificationRelay = NotificationRelay()
  var isLogSinkInstalled = false
  var logSinkAPI: UnsafeMutablePointer<RimeLogSinkApi>?
  var logSinkContext: UnsafeMutableRawPointer?

  public init(configuration: RimeConfiguration, probeLog: RimeProbeLog? = nil) {
    self.configuration = configuration
    self.probeLog = probeLog
    queue.setSpecific(key: RimeEngine.queueKey, value: 1)
  }

  /// Runs `body` on the engine's serial queue.
  ///
  /// Re-entrant calls run **inline**: a convenience call made from inside another engine call — the
  /// settings model reads a schema while holding its config — would otherwise be a `dispatch_sync` on
  /// the queue the thread already owns, which libdispatch treats as a client bug and traps (measured:
  /// SIGTRAP, "BUG IN CLIENT OF LIBDISPATCH: dispatch_sync called on queue already owned by current
  /// thread", not a deadlock).
  func perform<T>(_ body: () throws -> T) rethrows -> T {
    if DispatchQueue.getSpecific(key: RimeEngine.queueKey) != nil {
      return try body()
    }
    return try queue.sync(execute: body)
  }

  public static var librimeVersion: String { RimeAPI.version }

  public func probeRecords() -> [RimeProbeRecord] {
    perform { records }
  }

  // MARK: - Lifecycle

  @discardableResult
  public func start() throws -> RimeProbeRecord {
    try perform { try startLocked() }
  }

  /// Runs the deployer. Only the app should do this; the extension must find prebuilt tables.
  @discardableResult
  public func runMaintenance(fullCheck: Bool = true) throws -> RimeProbeRecord {
    try perform { try runMaintenanceLocked(fullCheck: fullCheck) }
  }

  public func openSession() throws {
    try perform { try openSessionLocked() }
  }

  public func closeSession() {
    perform { closeSessionLocked() }
  }

  public func shutdown() {
    perform { shutdownLocked() }
  }

  // MARK: - Input

  @discardableResult
  public func processKey(_ keyCode: Int32, modifiers: RimeModifier = .none) throws -> RimeOutput {
    try perform { try processKeyLocked(keyCode, modifiers: modifiers) }
  }

  /// Convenience for tests and for replaying a whole string of ASCII input.
  @discardableResult
  public func processKeys(_ text: String) throws -> RimeOutput {
    try perform { try processKeysLocked(text) }
  }

  @discardableResult
  public func selectCandidate(at index: Int) throws -> RimeOutput {
    try perform { try selectCandidateLocked(at: index) }
  }

  @discardableResult
  public func changePage(backward: Bool) throws -> RimeOutput {
    try perform { try changePageLocked(backward: backward) }
  }

  /// Toggles a runtime option such as ascii_mode, which is how the shift key works here.
  public func setOption(_ name: String, _ value: Bool) throws {
    try perform { try setOptionLocked(name, value) }
  }

  public func getOption(_ name: String) throws -> Bool {
    try perform { try getOptionLocked(name) }
  }

  /// Re-reads context and status without processing a key.
  @discardableResult
  public func refresh() throws -> RimeOutput {
    try perform { try refreshLocked() }
  }

  public func clearComposition() throws {
    try perform { try clearCompositionLocked() }
  }

  // MARK: - Lifecycle (queue)

  func startLocked(force: Bool = false) throws -> RimeProbeRecord {
    if isStarted, !force, let last = records.last { return last }
    let start = DispatchTime.now().uptimeNanoseconds
    guard let pointer = RimeAPI.pointer,
          let setup = pointer.pointee.setup,
          let initialize = pointer.pointee.initialize else {
      throw RimeEngineError.apiUnavailable
    }

    let directories = configuration.directories
    let boxes = [directories.sharedDataDir,
                 directories.prebuiltDataDir,
                 directories.userDataDir,
                 directories.stagingDir,
                 directories.logDir,
                 configuration.distributionName,
                 configuration.distributionCodeName,
                 configuration.distributionVersion,
                 configuration.appName].map(CStringBox.init)
    allocatedStrings = boxes

    var traits = RimeTraits()
    traits.data_size = RimeAPI.dataSize(of: RimeTraits.self)
    traits.shared_data_dir = boxes[0].raw
    traits.prebuilt_data_dir = boxes[1].raw
    traits.user_data_dir = boxes[2].raw
    traits.staging_dir = boxes[3].raw
    traits.log_dir = boxes[4].raw
    traits.distribution_name = boxes[5].raw
    traits.distribution_code_name = boxes[6].raw
    traits.distribution_version = boxes[7].raw
    traits.app_name = boxes[8].raw
    traits.min_log_level = configuration.minLogLevel

    api = pointer
    setup(&traits)
    // Both of these are installed after setup() and before initialize() so that the component
    // registration and schema loading that initialize() logs is captured too.
    installLogSinkLocked()
    installNotificationHandlerLocked()
    initialize(&traits)

    isStarted = true
    return record(phase: "engine.start",
                  start: start,
                  message: "librime " + RimeAPI.version + " writableRoot=" + directories.writableRoot.rawValue)
  }

  private func runMaintenanceLocked(fullCheck: Bool) throws -> RimeProbeRecord {
    let api = try requireAPI()
    guard let startMaintenance = api.pointee.start_maintenance else {
      throw RimeEngineError.deploymentFailed
    }
    let start = DispatchTime.now().uptimeNanoseconds
    let running = startMaintenance(fullCheck)
    if running, let join = api.pointee.join_maintenance_thread {
      join()
    }
    return record(phase: "engine.maintenance",
                  start: start,
                  message: (fullCheck ? "full check" : "incremental") + ", started=" + String(running))
  }

  private func openSessionLocked() throws {
    let api = try requireAPI()
    if let existing = session, let find = api.pointee.find_session, find(existing) { return }
    guard let create = api.pointee.create_session else { throw RimeEngineError.apiUnavailable }
    let created = create()
    guard created != 0 else { throw RimeEngineError.sessionCreationFailed }
    session = created
  }

  func closeSessionLocked() {
    guard let api, let session, let destroy = api.pointee.destroy_session else { return }
    _ = destroy(session)
    self.session = nil
  }

  private func shutdownLocked() {
    teardownLocked()
  }

  // MARK: - Input (queue)

  private func processKeyLocked(_ keyCode: Int32, modifiers: RimeModifier) throws -> RimeOutput {
    let api = try requireAPI()
    let session = try requireSession(api: api)
    guard let processKey = api.pointee.process_key else { throw RimeEngineError.apiUnavailable }
    let handled = processKey(session, keyCode, modifiers.rawValue)
    return readOutput(api: api, session: session, handled: handled)
  }

  private func processKeysLocked(_ text: String) throws -> RimeOutput {
    var last: RimeOutput?
    for character in text {
      guard let key = RimeKey.ascii(character) else { continue }
      last = try processKeyLocked(key, modifiers: .none)
    }
    if let last { return last }
    let api = try requireAPI()
    return readOutput(api: api, session: try requireSession(api: api), handled: false)
  }

  private func selectCandidateLocked(at index: Int) throws -> RimeOutput {
    let api = try requireAPI()
    let session = try requireSession(api: api)
    guard let select = api.pointee.select_candidate else { throw RimeEngineError.apiUnavailable }
    _ = select(session, index)
    return readOutput(api: api, session: session, handled: true)
  }

  private func changePageLocked(backward: Bool) throws -> RimeOutput {
    let api = try requireAPI()
    let session = try requireSession(api: api)
    guard let changePage = api.pointee.change_page else { throw RimeEngineError.apiUnavailable }
    _ = changePage(session, backward)
    return readOutput(api: api, session: session, handled: true)
  }

  private func setOptionLocked(_ name: String, _ value: Bool) throws {
    let api = try requireAPI()
    let session = try requireSession(api: api)
    guard let setOption = api.pointee.set_option else { throw RimeEngineError.apiUnavailable }
    let box = CStringBox(name)
    setOption(session, box.raw, value)
  }

  private func getOptionLocked(_ name: String) throws -> Bool {
    let api = try requireAPI()
    let session = try requireSession(api: api)
    guard let getOption = api.pointee.get_option else { throw RimeEngineError.apiUnavailable }
    let box = CStringBox(name)
    return getOption(session, box.raw)
  }

  private func refreshLocked() throws -> RimeOutput {
    let api = try requireAPI()
    return readOutput(api: api, session: try requireSession(api: api), handled: false)
  }

  private func clearCompositionLocked() throws {
    let api = try requireAPI()
    let session = try requireSession(api: api)
    api.pointee.clear_composition?(session)
  }

  // MARK: - Internals (queue)

  func requireAPI() throws -> UnsafeMutablePointer<rime_api_t> {
    if let api { return api }
    guard let pointer = RimeAPI.pointer else { throw RimeEngineError.apiUnavailable }
    return pointer
  }

  func requireSession(api: UnsafeMutablePointer<rime_api_t>) throws -> RimeSessionId {
    guard let session else { throw RimeEngineError.sessionNotOpen }
    if let find = api.pointee.find_session, !find(session) {
      throw RimeEngineError.sessionNotOpen
    }
    return session
  }

  @discardableResult
  func record(phase: String, start: UInt64, message: String? = nil) -> RimeProbeRecord {
    let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    let record = RimeProbeRecord(phase: phase, milliseconds: milliseconds, message: message)
    records.append(record)
    probeLog?.append(record)
    return record
  }

  func readOutput(api: UnsafeMutablePointer<rime_api_t>,
                  session: RimeSessionId,
                  handled: Bool) -> RimeOutput {
    var commitText: String?
    var commit = RimeCommit()
    commit.data_size = RimeAPI.dataSize(of: RimeCommit.self)
    if let getCommit = api.pointee.get_commit, getCommit(session, &commit) {
      if let text = commit.text {
        commitText = String(cString: text)
      }
      _ = api.pointee.free_commit?(&commit)
    }

    let (composition, page) = readContext(api: api, session: session)
    let status = readStatus(api: api, session: session)
    var input: String?
    if let getInput = api.pointee.get_input, let text = getInput(session) {
      input = String(cString: text)
    }
    return RimeOutput(handled: handled, commit: commitText, composition: composition,
                      page: page, status: status, input: input)
  }

  func readContext(api: UnsafeMutablePointer<rime_api_t>,
                   session: RimeSessionId) -> (RimeCompositionInfo?, RimePage?) {
    var context = RimeContext()
    context.data_size = RimeAPI.dataSize(of: RimeContext.self)
    guard let getContext = api.pointee.get_context, getContext(session, &context) else {
      return (nil, nil)
    }
    defer { _ = api.pointee.free_context?(&context) }

    let composition = RimeCompositionInfo(preedit: context.composition.preedit.map { String(cString: $0) },
                                          cursorPosition: Int(context.composition.cursor_pos),
                                          selectionStart: Int(context.composition.sel_start),
                                          selectionEnd: Int(context.composition.sel_end))

    let menu = context.menu
    let count = Int(menu.num_candidates)
    var candidates: [RimeCandidateItem] = []
    candidates.reserveCapacity(count)
    if let list = menu.candidates {
      for index in 0..<count {
        let item = list[index]
        candidates.append(RimeCandidateItem(text: item.text.map { String(cString: $0) } ?? "",
                                           comment: item.comment.map { String(cString: $0) }))
      }
    }

    var labels: [String] = []
    if let selectLabels = context.select_labels {
      labels.reserveCapacity(count)
      for index in 0..<count {
        if let label = selectLabels[index] {
          labels.append(String(cString: label))
        } else {
          labels.append("")
        }
      }
    }

    let page = RimePage(candidates: candidates,
                        highlightedIndex: Int(menu.highlighted_candidate_index),
                        pageNumber: Int(menu.page_no),
                        pageSize: Int(menu.page_size),
                        isLastPage: menu.is_last_page,
                        selectLabels: labels)
    return (composition, page)
  }

  func readStatus(api: UnsafeMutablePointer<rime_api_t>,
                  session: RimeSessionId) -> RimeStatusSnapshot? {
    var status = RimeStatus()
    status.data_size = RimeAPI.dataSize(of: RimeStatus.self)
    guard let getStatus = api.pointee.get_status, getStatus(session, &status) else {
      return nil
    }
    defer { _ = api.pointee.free_status?(&status) }
    return RimeStatusSnapshot(schemaID: status.schema_id.map { String(cString: $0) },
                              schemaName: status.schema_name.map { String(cString: $0) },
                              isDisabled: status.is_disabled,
                              isComposing: status.is_composing,
                              isAsciiMode: status.is_ascii_mode,
                              isFullShape: status.is_full_shape,
                              isSimplified: status.is_simplified,
                              isTraditional: status.is_traditional,
                              isAsciiPunctuation: status.is_ascii_punct)
  }
}
