import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// One line of evidence. Written as JSONL so the container app can render it as a table.
public struct RimeProbeRecord: Codable, Sendable {
  public var timestamp: Date
  public var phase: String
  public var milliseconds: Double?
  public var footprintBytes: UInt64?
  public var message: String?

  public init(phase: String,
              milliseconds: Double? = nil,
              footprintBytes: UInt64? = nil,
              message: String? = nil) {
    self.timestamp = Date()
    self.phase = phase
    self.milliseconds = milliseconds
    self.footprintBytes = footprintBytes ?? RimeProbe.physicalFootprint()
    self.message = message
  }
}

public enum RimeProbe {
  /// Physical footprint in bytes: what jetsam accounts against the extension's limit.
  /// Resident size understates it, so this is the number worth recording.
  public static func physicalFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
      }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return info.phys_footprint
  }

  public static func megabytes(_ bytes: UInt64) -> Double {
    Double(bytes) / 1_048_576.0
  }
}

/// Append-only JSONL sink. The keyboard extension writes it, the app reads it.
public final class RimeProbeLog: @unchecked Sendable {
  public let url: URL
  private let lock = NSLock()
  private let encoder: JSONEncoder

  public init(url: URL) {
    self.url = url
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    self.encoder = encoder
  }

  public func append(_ record: RimeProbeRecord) {
    guard let data = try? encoder.encode(record) else { return }
    var line = data
    line.append(0x0A)
    lock.lock()
    defer { lock.unlock() }
    if let handle = try? FileHandle(forWritingTo: url) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: line)
    } else {
      try? line.write(to: url, options: .atomic)
    }
  }

  public func readAll() -> [RimeProbeRecord] {
    guard let data = try? Data(contentsOf: url) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return data.split(separator: 0x0A).compactMap { try? decoder.decode(RimeProbeRecord.self, from: Data($0)) }
  }
}
