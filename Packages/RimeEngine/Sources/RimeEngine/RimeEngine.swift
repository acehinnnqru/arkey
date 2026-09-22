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
/// librime keeps process-global state and is not thread-safe, so every call goes through this
/// actor and nothing else touches the C API.
public actor RimeEngine {
  public private(set) var records: [RimeProbeRecord] = []

  private let configuration: RimeConfiguration
  private let probeLog: RimeProbeLog?
  private var allocatedStrings: [CStringBox] = []
  private var api: UnsafeMutablePointer<rime_api_t>?
  private var session: RimeSessionId?
  private var isStarted = false

  public init(configuration: RimeConfiguration, probeLog: RimeProbeLog? = nil) {
    self.configuration = configuration
    self.probeLog = probeLog
  }

  public static var librimeVersion: String { RimeAPI.version }

  // MARK: - Lifecycle

  @discardableResult
  public func start() throws -> RimeProbeRecord {
    if isStarted, let last = records.last { return last }
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

    setup(&traits)
    initialize(&traits)

    api = pointer
    isStarted = true
    return record(phase: "engine.start",
                  start: start,
                  message: "librime " + RimeAPI.version + " writableRoot=" + directories.writableRoot.rawValue)
  }

  /// Runs the deployer. Only the app should do this; the extension must find prebuilt tables.
  @discardableResult
  public func runMaintenance(fullCheck: Bool = true) throws -> RimeProbeRecord {
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

  public func openSession() throws {
    let api = try requireAPI()
    if let existing = session, let find = api.pointee.find_session, find(existing) { return }
    guard let create = api.pointee.create_session else { throw RimeEngineError.apiUnavailable }
    let created = create()
    guard created != 0 else { throw RimeEngineError.sessionCreationFailed }
    session = created
  }

  public func closeSession() {
    guard let api, let session, let destroy = api.pointee.destroy_session else { return }
    _ = destroy(session)
    self.session = nil
  }

  public func shutdown() {
    closeSession()
    api?.pointee.finalize?()
    api = nil
    isStarted = false
    allocatedStrings = []
  }

  // MARK: - Input

  @discardableResult
  public func processKey(_ keyCode: Int32, modifiers: RimeModifier = .none) throws -> RimeOutput {
    let api = try requireAPI()
    let session = try requireSession(api: api)
    guard let processKey = api.pointee.process_key else { throw RimeEngineError.apiUnavailable }
    let handled = processKey(session, keyCode, modifiers.rawValue)
    return readOutput(api: api, session: session, handled: handled)
  }

  /// Convenience for tests and for replaying a whole string of ASCII input.
  @discardableResult
  public func processKeys(_ text: String) throws -> RimeOutput {
    var last: RimeOutput?
    for character in text {
      guard let key = RimeKey.ascii(character) else { continue }
      last = try processKey(key)
    }
    if let last { return last }
    let api = try requireAPI()
    return readOutput(api: api, session: try requireSession(api: api), handled: false)
  }

  @discardableResult
  public func selectCandidate(at index: Int) throws -> RimeOutput {
    let api = try requireAPI()
    let session = try requireSession(api: api)
    guard let select = api.pointee.select_candidate else { throw RimeEngineError.apiUnavailable }
    _ = select(session, index)
    return readOutput(api: api, session: session, handled: true)
  }

  @discardableResult
  public func changePage(backward: Bool) throws -> RimeOutput {
    let api = try requireAPI()
    let session = try requireSession(api: api)
    guard let changePage = api.pointee.change_page else { throw RimeEngineError.apiUnavailable }
    _ = changePage(session, backward)
    return readOutput(api: api, session: session, handled: true)
  }

  /// Toggles a runtime option such as ascii_mode, which is how the shift key works here.
  public func setOption(_ name: String, _ value: Bool) throws {
    let api = try requireAPI()
    let session = try requireSession(api: api)
    guard let setOption = api.pointee.set_option else { throw RimeEngineError.apiUnavailable }
    let box = CStringBox(name)
    setOption(session, box.raw, value)
  }

  public func getOption(_ name: String) throws -> Bool {
    let api = try requireAPI()
    let session = try requireSession(api: api)
    guard let getOption = api.pointee.get_option else { throw RimeEngineError.apiUnavailable }
    let box = CStringBox(name)
    return getOption(session, box.raw)
  }

  /// Re-reads context and status without processing a key.
  @discardableResult
  public func refresh() throws -> RimeOutput {
    let api = try requireAPI()
    return readOutput(api: api, session: try requireSession(api: api), handled: false)
  }

  public func clearComposition() throws {
    let api = try requireAPI()
    let session = try requireSession(api: api)
    api.pointee.clear_composition?(session)
  }

  // MARK: - Internals

  private func requireAPI() throws -> UnsafeMutablePointer<rime_api_t> {
    if let api { return api }
    guard let pointer = RimeAPI.pointer else { throw RimeEngineError.apiUnavailable }
    return pointer
  }

  private func requireSession(api: UnsafeMutablePointer<rime_api_t>) throws -> RimeSessionId {
    guard let session else { throw RimeEngineError.sessionNotOpen }
    if let find = api.pointee.find_session, !find(session) {
      throw RimeEngineError.sessionNotOpen
    }
    return session
  }

  @discardableResult
  private func record(phase: String, start: UInt64, message: String? = nil) -> RimeProbeRecord {
    let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    let record = RimeProbeRecord(phase: phase, milliseconds: milliseconds, message: message)
    records.append(record)
    probeLog?.append(record)
    return record
  }

  private func readOutput(api: UnsafeMutablePointer<rime_api_t>,
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
    return RimeOutput(handled: handled, commit: commitText, composition: composition,
                      page: page, status: status)
  }

  private func readContext(api: UnsafeMutablePointer<rime_api_t>,
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

  private func readStatus(api: UnsafeMutablePointer<rime_api_t>,
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
