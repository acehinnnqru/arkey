import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - The lease

/// One writer at a time (S5 §3.2).
///
/// librime's leveldb user dictionaries take a per-process lock, so a second opener is not told: it
/// is handed a dictionary that is silently not loaded, and the user loses both learning and recall
/// with no message. The extension therefore writes a lease — pid plus a heartbeat — while it holds
/// a session, and the app takes user-dictionary operations only when that lease is cold.
public struct RimeKeyboardLease: Codable, Sendable, Hashable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var pid: Int32
  public var heartbeat: Date
  public var openedAt: Date
  public var host: String?

  public init(pid: Int32, heartbeat: Date = Date(), openedAt: Date = Date(), host: String? = nil) {
    self.schemaVersion = Self.currentSchemaVersion
    self.pid = pid
    self.heartbeat = heartbeat
    self.openedAt = openedAt
    self.host = host
  }

  /// A heartbeat older than this is not evidence that anyone is typing: an extension that was
  /// suspended, or killed, stops touching the file without ever removing it.
  public static let staleAfter: TimeInterval = 15
}

/// `@unchecked` because of the injectable `FileManager`: the class is not annotated Sendable, but the
/// handful of calls this type makes on it (existence, attributes, remove, atomic write) are the ones
/// FileManager documents as safe to share, and everything else here is immutable. The alternative —
/// only ever using `.default` — would take away the seam a test may want.
public struct RimeLeaseStore: @unchecked Sendable {
  /// Whether a pid still exists. Injectable because kill() is not a reliable existence check for
  /// every pid, and because a test must not depend on which pids this machine happens to have.
  public typealias LivenessCheck = @Sendable (Int32) -> Bool

  public let url: URL
  private let fileManager: FileManager
  private let liveness: LivenessCheck

  public init(url: URL, fileManager: FileManager = .default,
              liveness: @escaping LivenessCheck = RimeLeaseStore.processIsAlive) {
    self.url = url
    self.fileManager = fileManager
    self.liveness = liveness
  }

  public init(workspace: RimeWorkspace, fileManager: FileManager = .default,
              liveness: @escaping LivenessCheck = RimeLeaseStore.processIsAlive) {
    self.init(url: workspace.root.appendingPathComponent("keyboard.lease.json"),
              fileManager: fileManager, liveness: liveness)
  }

  // MARK: Holder side

  @discardableResult
  public func claim(pid: Int32 = getpid(), host: String? = nil, now: Date = Date()) throws -> RimeKeyboardLease {
    let existing = current()
    let lease = RimeKeyboardLease(pid: pid,
                                  heartbeat: now,
                                  openedAt: existing?.pid == pid ? existing?.openedAt ?? now : now,
                                  host: host ?? existing?.host)
    try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
    try RimeJSON.encode(lease, pretty: false).write(to: url, options: .atomic)
    return lease
  }

  public func heartbeat(pid: Int32 = getpid(), now: Date = Date()) {
    guard var lease = current(), lease.pid == pid else { return }
    lease.heartbeat = now
    try? RimeJSON.encode(lease, pretty: false).write(to: url, options: .atomic)
  }

  /// Called when the keyboard disappears. It is an optimisation, not the safety mechanism: a
  /// crashed extension leaves the file behind, which is what the staleness rule is for.
  public func release(pid: Int32 = getpid()) {
    guard let lease = current(), lease.pid == pid else { return }
    try? fileManager.removeItem(at: url)
  }

  // MARK: Reader side

  public func current() -> RimeKeyboardLease? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    guard let lease = try? RimeJSON.decode(RimeKeyboardLease.self, from: data) else { return nil }
    guard lease.schemaVersion <= RimeKeyboardLease.currentSchemaVersion else { return nil }
    return lease
  }

  /// What the lease file says, without collapsing "nobody is typing" into "we cannot tell".
  public enum State: Sendable, Equatable {
    /// No file, a stale heartbeat, or a process that is gone: the dictionaries are free.
    case cold
    /// A live process holds them.
    case held(RimeKeyboardLease)
    /// A file is there and cannot be read: a corrupt write, or one whose schema version we do not know.
    ///
    /// **Unknown is not "nobody is typing".** The leveldb lock this file protects does not care why we
    /// are wrong, so an unreadable lease counts as held while it is *fresh* — and since there is no
    /// heartbeat to read, the file's modification date stands in for one. A garbage file that is also
    /// old therefore ages out like any other, instead of wedging the app forever.
    case unreadable(modifiedAt: Date, reason: String)
  }

  public func state(now: Date = Date(),
                    staleAfter: TimeInterval = RimeKeyboardLease.staleAfter) -> State {
    guard fileManager.fileExists(atPath: url.path) else { return .cold }
    guard let lease = current() else {
      let attributes = try? fileManager.attributesOfItem(atPath: url.path)
      let modified = (attributes?[.modificationDate] as? Date) ?? .distantPast
      guard now.timeIntervalSince(modified) < staleAfter else { return .cold }
      return .unreadable(modifiedAt: modified,
                         reason: "the lease file exists but could not be read")
    }
    guard now.timeIntervalSince(lease.heartbeat) < staleAfter, liveness(lease.pid) else { return .cold }
    return .held(lease)
  }

  /// The lease a caller must respect, or nil when it is safe to take the dictionaries.
  public func liveHolder(now: Date = Date(), staleAfter: TimeInterval = RimeKeyboardLease.staleAfter)
    -> RimeKeyboardLease? {
    if case .held(let lease) = state(now: now, staleAfter: staleAfter) { return lease }
    return nil
  }

  /// False for a live holder **and** for a fresh unreadable file: both mean "do not touch the
  /// dictionaries yet".
  public func isCold(now: Date = Date(), staleAfter: TimeInterval = RimeKeyboardLease.staleAfter) -> Bool {
    if case .cold = state(now: now, staleAfter: staleAfter) { return true }
    return false
  }

  /// Removes a lease that cannot be live, so diagnostics do not show a ghost forever. That includes an
  /// unreadable file once it has aged out — the case the old version of this method never reached,
  /// because it required the file to decode.
  public func prune(now: Date = Date()) {
    guard fileManager.fileExists(atPath: url.path) else { return }
    guard isCold(now: now) else { return }
    try? fileManager.removeItem(at: url)
  }

  /// A `@Sendable` constant rather than a method: converting a method reference to a `@Sendable`
  /// closure is a warning today and an error under the Swift 6 language mode, and this is a plain
  /// function of its argument with nothing to capture.
  public static let processIsAlive: @Sendable (Int32) -> Bool = { pid in
    guard pid > 0 else { return false }
    if pid == getpid() { return true }
    errno = 0
    let result = kill(pid, 0)
    if result == 0 { return true }
    // EPERM means the process exists and belongs to someone else, which on iOS means alive.
    return errno == EPERM
  }
}

// MARK: - The app's gate

public enum RimeDictionaryAccessError: Error, CustomStringConvertible, Sendable {
  case keyboardIsUsingIt(pid: Int32, since: Date)
  /// A lease file that cannot be read. Refused while fresh, for the same reason a live holder is.
  case leaseUnreadable(modifiedAt: Date, reason: String)

  public var description: String {
    switch self {
    case .keyboardIsUsingIt(let pid, let since):
      return "键盘正在使用用户词库（pid " + String(pid) + "，自 "
        + ISO8601DateFormatter().string(from: since) + "）。关闭键盘后再试，或稍候片刻。"
    case .leaseUnreadable(let modifiedAt, let reason):
      return "词库租约文件无法读取（" + reason + "，最后修改 "
        + ISO8601DateFormatter().string(from: modifiedAt) + "）。暂时按“键盘可能正在使用”处理；"
        + "若键盘并未使用词库，稍候片刻即可。"
    }
  }
}

/// The app's side of the protocol: refuse with an explanation while the keyboard holds the lease,
/// and let go of the app's own session while a dictionary operation runs.
///
/// It refuses rather than stealing: S1 measured that librime does not report the second opener, so
/// "try anyway" is how a dictionary ends up silently not loaded.
public struct RimeDictionaryAccess {
  public let workspace: RimeWorkspace
  public let engine: RimeEngine
  public let leaseStore: RimeLeaseStore

  public init(workspace: RimeWorkspace, engine: RimeEngine, leaseStore: RimeLeaseStore? = nil) {
    self.workspace = workspace
    self.engine = engine
    self.leaseStore = leaseStore ?? RimeLeaseStore(workspace: workspace)
  }

  /// Why the app may not touch the dictionaries, or nil when it may.
  public enum Blocker: Sendable, Equatable, CustomStringConvertible {
    case keyboard(pid: Int32, since: Date)
    case unreadableLease(modifiedAt: Date, reason: String)

    public var error: RimeDictionaryAccessError {
      switch self {
      case .keyboard(let pid, let since):
        return .keyboardIsUsingIt(pid: pid, since: since)
      case .unreadableLease(let modifiedAt, let reason):
        return .leaseUnreadable(modifiedAt: modifiedAt, reason: reason)
      }
    }

    public var description: String { error.description }
  }

  public func blocker(now: Date = Date()) -> Blocker? {
    switch leaseStore.state(now: now) {
    case .cold:
      return nil
    case .held(let lease):
      return .keyboard(pid: lease.pid, since: lease.openedAt)
    case .unreadable(let modifiedAt, let reason):
      return .unreadableLease(modifiedAt: modifiedAt, reason: reason)
    }
  }

  public func requireExclusiveAccess(now: Date = Date()) throws {
    if let blocker = blocker(now: now) {
      throw blocker.error
    }
  }

  /// Runs a user-dictionary operation with the app's own session closed, and restores it only if it
  /// was open. Closing the session is what releases librime's hold on the leveldb database — the
  /// measured precondition for `export_user_dict` to succeed at all.
  @discardableResult
  public func perform<T>(now: Date = Date(), _ body: () throws -> T) throws -> T {
    try requireExclusiveAccess(now: now)
    let hadSession = engine.isSessionOpen
    engine.closeSession()
    defer {
      if hadSession { try? engine.openSession() }
    }
    return try body()
  }
}

extension RimeEngine {
  /// True while this engine holds a librime session. The lease is only meaningful together with
  /// one: an engine with no session is not using the dictionaries.
  public var isSessionOpen: Bool {
    perform {
      guard let session else { return false }
      guard let api = RimeAPI.pointer, let find = api.pointee.find_session else { return true }
      return find(session)
    }
  }
}
