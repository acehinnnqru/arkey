import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// An open descriptor owns the kernel lock. The lock file is permanent: replacing or deleting it
/// would let two processes lock different inodes. Process exit closes the descriptor automatically.
final class RimeDictionaryLock {
  let url: URL
  private let descriptor: Int32

  init(url: URL) throws {
    self.url = url
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      let code = errno
      close(descriptor)
      if code == EWOULDBLOCK || code == EAGAIN {
        throw RimeDictionaryAccessError.dictionaryBusy
      }
      throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
  }

  deinit { close(descriptor) }
}

// MARK: - The lease

/// Diagnostic metadata for the holder of the shared kernel lock. Heartbeat expiry never releases
/// ownership: a suspended process can still have an open librime session.
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

  /// Diagnostic freshness only. A suspended holder keeps its kernel lock regardless of this age.
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

  /// Writes metadata only. Production callers must hold the dictionary lock throughout this call.
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

  /// Removes diagnostic metadata after closing the session, while the kernel lock is still held.
  public func release(pid: Int32 = getpid()) {
    guard let lease = current(), lease.pid == pid else { return }
    try? fileManager.removeItem(at: url)
  }

  var lockURL: URL { url.deletingLastPathComponent().appendingPathComponent("dictionary.lock") }

  func acquireLock() throws -> RimeDictionaryLock { try RimeDictionaryLock(url: lockURL) }

  // MARK: Reader side

  public func current() -> RimeKeyboardLease? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    guard let lease = try? RimeJSON.decode(RimeKeyboardLease.self, from: data) else { return nil }
    guard lease.schemaVersion <= RimeKeyboardLease.currentSchemaVersion else { return nil }
    return lease
  }

  /// What the lease file says, without collapsing "nobody is typing" into "we cannot tell".
  public enum State: Sendable, Equatable {
    /// No kernel holder and no fresh diagnostic warning. Access still requires atomic acquisition.
    case cold
    /// A live process holds them.
    case held(RimeKeyboardLease)
    /// A file is there and cannot be read: a corrupt write, or one whose schema version we do not know.
    ///
    /// An owned kernel lock always blocks, including when metadata is missing or corrupt. With no
    /// kernel holder, fresh unreadable metadata is a conservative warning that can age out.
    case unreadable(modifiedAt: Date, reason: String)
  }

  public func state(now: Date = Date(),
                    staleAfter: TimeInterval = RimeKeyboardLease.staleAfter) -> State {
    // Probe the kernel first. A stale, missing, or corrupt heartbeat cannot hide a lock holder.
    do {
      let lock = try acquireLock()
      withExtendedLifetime(lock) {}
    } catch RimeDictionaryAccessError.dictionaryBusy {
      if let lease = current() { return .held(lease) }
      return .unreadable(modifiedAt: .distantPast, reason: "the dictionary lock is held without readable metadata")
    } catch {
      return .unreadable(modifiedAt: .distantPast, reason: String(describing: error))
    }
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

  /// Diagnostic holder metadata. A nil result never grants dictionary access.
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
    guard let lock = try? acquireLock() else { return }
    defer { withExtendedLifetime(lock) {} }
    guard fileManager.fileExists(atPath: url.path) else { return }
    // No holder can claim or renew while pruning. Only diagnostic age/liveness is relevant here.
    if let lease = current(), liveness(lease.pid),
       now.timeIntervalSince(lease.heartbeat) < RimeKeyboardLease.staleAfter { return }
    if current() == nil,
       let attributes = try? fileManager.attributesOfItem(atPath: url.path),
       let modified = attributes[.modificationDate] as? Date,
       now.timeIntervalSince(modified) < RimeKeyboardLease.staleAfter { return }
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
  case dictionaryBusy
  case keyboardIsUsingIt(pid: Int32, since: Date)
  /// A lease file that cannot be read. Refused while fresh, for the same reason a live holder is.
  case leaseUnreadable(modifiedAt: Date, reason: String)

  public var description: String {
    switch self {
    case .dictionaryBusy:
      return "The dictionaries are in use by another session or operation. Try again after it finishes."
    case .keyboardIsUsingIt(let pid, let since):
      return RimeLocalization.text("The keyboard is using user dictionaries (pid \(String(pid)), since \(ISO8601DateFormatter().string(from: since))). Close the keyboard and try again, or wait a moment.")
    case .leaseUnreadable(let modifiedAt, let reason):
      return RimeLocalization.text("The dictionary lease file could not be read (\(reason), last modified \(ISO8601DateFormatter().string(from: modifiedAt))). Treating dictionaries as potentially in use. If the keyboard is not using them, wait a moment.")
    }
  }
}

/// Atomically owns the same kernel lock as shared sessions for the whole dictionary operation,
/// including closing and restoring the app's session. Lease metadata only helps explain refusal.
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
    let ownsLock = engine.perform { engine.dictionaryLock?.url == leaseStore.lockURL }
    if ownsLock { return nil }
    switch leaseStore.state(now: now) {
    case .cold:
      return nil
    case .held(let lease):
      return .keyboard(pid: lease.pid, since: lease.openedAt)
    case .unreadable(let modifiedAt, let reason):
      return .unreadableLease(modifiedAt: modifiedAt, reason: reason)
    }
  }

  /// Advisory check for presentation only. `perform` atomically acquires ownership before accessing data.
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
    try engine.perform {
      // Reuse this engine's ownership so its session can be closed and restored without a gap.
      if engine.dictionaryLock == nil { try requireExclusiveAccess(now: now) }
      return try engine.withDictionaryOwnership(store: leaseStore, host: "app") {
        let hadSession = engine.isSessionOpen
        engine.closeSession()
        defer {
          if hadSession { try? engine.openSession() }
        }
        return try body()
      }
    }
  }
}

extension RimeEngine {
  /// True while this engine holds a librime session. Dictionary operations can also hold ownership
  /// with no session, so this value alone never grants access to another caller.
  public var isSessionOpen: Bool {
    perform {
      guard let session else { return false }
      guard let api = RimeAPI.pointer, let find = api.pointee.find_session else { return true }
      return find(session)
    }
  }
}
