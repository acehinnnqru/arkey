import Foundation

/// The host writes this before compilation, independently of the generation being published.
/// A running record left by a terminated process is an unconfirmed attempt, never a usable build.
public struct RimeDeploymentJournal: Sendable {
  public struct Record: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case running, succeeded, failed, interrupted }
    public let id: UUID
    public let profileID: String
    public let profileName: String
    public let startedAt: Date
    public var state: State
    public var finishedAt: Date?
  }

  public let url: URL

  public init(workspace: RimeWorkspace) {
    url = workspace.root.appendingPathComponent("deployment-state.json")
  }

  public init(url: URL) { self.url = url }

  public func load() throws -> Record? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try RimeJSON.decode(Record.self, from: Data(contentsOf: url))
  }

  @discardableResult
  public func begin(id: UUID, profileID: String, profileName: String, startedAt: Date) throws -> Record {
    let record = Record(id: id, profileID: profileID, profileName: profileName,
                        startedAt: startedAt, state: .running)
    try save(record)
    return record
  }

  /// A late completion cannot overwrite a newer attempt's state.
  public func finish(id: UUID, succeeded: Bool, now: Date = Date()) throws {
    guard var record = try load(), record.id == id, record.state == .running else { return }
    record.state = succeeded ? .succeeded : .failed
    record.finishedAt = now
    try save(record)
  }

  /// Call once on a fresh host launch, before automatic repair can start another deployment.
  public func recoverInterrupted() throws -> Record? {
    guard var record = try load() else { return nil }
    if record.state == .running {
      record.state = .interrupted
      // The exact termination time is unknown; do not invent a completion time.
      try save(record)
    }
    return record.state == .interrupted ? record : nil
  }

  public func dismissInterrupted(id: UUID) throws {
    guard let record = try load(), record.id == id, record.state == .interrupted else { return }
    try FileManager.default.removeItem(at: url)
  }

  private func save(_ record: Record) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try RimeJSON.encode(record).write(to: url, options: .atomic)
  }
}
