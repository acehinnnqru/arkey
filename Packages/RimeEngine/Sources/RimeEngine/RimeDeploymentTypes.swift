import Foundation

// MARK: - Schemas

/// One entry of librime's deployed schema list.
public struct RimeSchema: Sendable, Hashable, Codable {
  public let id: String
  public let name: String

  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }
}

// MARK: - Log records

public enum RimeLogSeverity: Int, Sendable, Comparable, CaseIterable {
  case info = 0
  case warning = 1
  case error = 2
  case fatal = 3

  public static func < (lhs: RimeLogSeverity, rhs: RimeLogSeverity) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  public var label: String {
    switch self {
    case .info: return "INFO"
    case .warning: return "WARNING"
    case .error: return "ERROR"
    case .fatal: return "FATAL"
    }
  }
}

/// One record from the logsink module.
///
/// librime's logs can contain typed text, so a caller that persists these owns the privacy
/// decision; nothing here writes anywhere by itself.
public struct RimeLogRecord: Sendable, Hashable {
  public let severity: RimeLogSeverity
  public let message: String
  public let file: String
  public let line: Int
  public let timestamp: Date

  public init(severity: RimeLogSeverity, message: String, file: String, line: Int,
              timestamp: Date = Date()) {
    self.severity = severity
    self.message = message
    self.file = file
    self.line = line
    self.timestamp = timestamp
  }

  public var display: String {
    file + ":" + String(line) + " " + severity.label + " " + message
  }
}

/// A bounded ring buffer of log records.
///
/// The sink runs on whichever thread logged, possibly concurrently, so the buffer owns a lock.
/// It is deliberately small: a deploy failure screen shows the tail, and the diagnostics screen
/// copies it, and neither wants megabytes of glog.
public final class RimeLogBuffer: @unchecked Sendable {
  public let capacity: Int
  private let lock = NSLock()
  private var storage: [RimeLogRecord] = []

  public init(capacity: Int = 500) {
    self.capacity = max(1, capacity)
  }

  public func append(_ record: RimeLogRecord) {
    lock.lock()
    defer { lock.unlock() }
    storage.append(record)
    if storage.count > capacity {
      storage.removeFirst(storage.count - capacity)
    }
  }

  public func snapshot() -> [RimeLogRecord] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  public func removeAll() {
    lock.lock()
    defer { lock.unlock() }
    storage.removeAll()
  }

  public var text: String {
    snapshot().map(\.display).joined(separator: "\n")
  }

  /// The lines that matter on a failure screen: errors and fatals, in order.
  public func errors() -> [RimeLogRecord] {
    snapshot().filter { $0.severity >= .error }
  }
}

// MARK: - Notifications

/// A typed view of librime's notification callbacks.
public enum RimeNotification: Sendable, Hashable {
  public enum DeployPhase: String, Sendable, Hashable {
    case start
    case success
    case failure
  }

  case deploy(DeployPhase)
  case schema(id: String, name: String)
  case option(name: String, enabled: Bool)
  case other(type: String, value: String)

  public static func parse(type: String, value: String) -> RimeNotification {
    switch type {
    case "deploy":
      if let phase = DeployPhase(rawValue: value) {
        return .deploy(phase)
      }
      return .other(type: type, value: value)
    case "schema":
      let parts = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
      let id = parts.first.map(String.init) ?? value
      let name = parts.count > 1 ? String(parts[1]) : id
      return .schema(id: id, name: name)
    case "option":
      let enabled = !value.hasPrefix("!")
      let name = enabled ? value : String(value.dropFirst())
      return .option(name: name, enabled: enabled)
    default:
      return .other(type: type, value: value)
    }
  }
}

// MARK: - Deployment

public struct RimeDeploymentProgress: Sendable, Hashable {
  public enum Phase: String, Sendable, Hashable {
    /// The engine is being rebound to the staging layout; librime is not running yet.
    case binding
    /// librime reported deploy/start.
    case started
    /// Maintenance is executing. Long: tens of seconds for a full config.
    case running
    case succeeded
    case failed
  }

  public let phase: Phase
  public let message: String

  public init(phase: Phase, message: String = "") {
    self.phase = phase
    self.message = message
  }
}

public struct RimeBuildFile: Sendable, Hashable {
  /// Path relative to the build directory, with "/" separators on every platform.
  public let relativePath: String
  public let bytes: Int

  public init(relativePath: String, bytes: Int) {
    self.relativePath = relativePath
    self.bytes = bytes
  }
}

/// What one deployment produced. Handed to the app's deploy screen and recorded in the probe log.
public struct RimeDeploymentReport: Sendable {
  public let directories: RimeDirectories
  public let fullCheck: Bool
  public let succeeded: Bool
  public let duration: TimeInterval
  public let files: [RimeBuildFile]
  public let notifications: [RimeNotification]
  public let logs: [RimeLogRecord]
  public let failureReason: String?

  public init(directories: RimeDirectories, fullCheck: Bool, succeeded: Bool,
              duration: TimeInterval, files: [RimeBuildFile],
              notifications: [RimeNotification], logs: [RimeLogRecord],
              failureReason: String?) {
    self.directories = directories
    self.fullCheck = fullCheck
    self.succeeded = succeeded
    self.duration = duration
    self.files = files
    self.notifications = notifications
    self.logs = logs
    self.failureReason = failureReason
  }

  public var totalBytes: Int { files.reduce(0) { $0 + $1.bytes } }

  public var logText: String { logs.map(\.display).joined(separator: "\n") }
}

/// Thrown when a deployment fails; carries the report so the failure screen has librime's own text.
public struct RimeDeploymentError: Error, CustomStringConvertible, Sendable {
  public let report: RimeDeploymentReport

  public init(report: RimeDeploymentReport) {
    self.report = report
  }

  public var description: String {
    let reason = report.failureReason ?? "librime reported a deploy failure"
    if let last = report.logs.last(where: { $0.severity >= .error }) {
      return reason + " — " + last.display
    }
    return reason
  }
}

// MARK: - Configuration values

/// A configuration item, as librime's config layer models it.
///
/// S2 needs whole maps and lists, not just scalars: `schema_list` and `speller/algebra` are
/// replaced wholesale by a patch, so a value that cannot carry a list cannot express them.
public enum RimeConfigValue: Sendable, Hashable {
  case bool(Bool)
  case int(Int)
  case double(Double)
  case string(String)
  case list([RimeConfigValue])
  case map([String: RimeConfigValue])

  public var boolValue: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }

  public var intValue: Int? {
    if case .int(let value) = self { return value }
    return nil
  }

  public var doubleValue: Double? {
    if case .double(let value) = self { return value }
    return nil
  }

  public var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  public var listValue: [RimeConfigValue]? {
    if case .list(let value) = self { return value }
    return nil
  }

  public var mapValue: [String: RimeConfigValue]? {
    if case .map(let value) = self { return value }
    return nil
  }

  /// The scalar as text, for the places where Rime stores everything as a string.
  public var textValue: String? {
    switch self {
    case .bool(let value): return value ? "true" : "false"
    case .int(let value): return String(value)
    case .double(let value): return String(value)
    case .string(let value): return value
    case .list, .map: return nil
    }
  }

  /// A compact single-line rendering, for probe records and diagnostics tables.
  public var compactDescription: String {
    switch self {
    case .bool(let value): return value ? "true" : "false"
    case .int(let value): return String(value)
    case .double(let value): return String(value)
    case .string(let value): return value
    case .list(let items): return "[" + items.map(\.compactDescription).joined(separator: ", ") + "]"
    case .map(let entries):
      let rendered = entries.keys.sorted().map { $0 + ": " + (entries[$0]?.compactDescription ?? "") }
      return "{" + rendered.joined(separator: ", ") + "}"
    }
  }

  public static func from(_ value: Any) -> RimeConfigValue {
    switch value {
    case let value as Bool: return .bool(value)
    case let value as Int: return .int(value)
    case let value as Double: return .double(value)
    case let value as String: return .string(value)
    case let value as [Any]: return .list(value.map(RimeConfigValue.from))
    case let value as [String: Any]: return .map(value.mapValues(RimeConfigValue.from))
    default: return .string(String(describing: value))
    }
  }
}

/// A record of what one configuration write changed, for the probe log and the deploy screen.
public struct RimeConfigChange: Sendable, Hashable {
  public let configID: String
  public let key: String
  public let oldValue: RimeConfigValue?
  public let newValue: RimeConfigValue?

  public init(configID: String, key: String, oldValue: RimeConfigValue?, newValue: RimeConfigValue?) {
    self.configID = configID
    self.key = key
    self.oldValue = oldValue
    self.newValue = newValue
  }

  public var display: String {
    configID + " " + key + ": " + (oldValue?.compactDescription ?? "<unset>")
      + " -> " + (newValue?.compactDescription ?? "<unset>")
  }
}
