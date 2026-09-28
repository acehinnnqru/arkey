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

extension RimeProbeRecord {
  /// S2 §5.5: every applied setting is one probe line — the config, the key and both sides of the
  /// change. It carries configuration values only: the composition, the candidates and anything else
  /// the user typed are not part of a change record, and S6 §3 makes that a property of the log
  /// (pinned by `S6ProbePrivacyTests`).
  public static func configApplied(_ change: RimeConfigChange) -> RimeProbeRecord {
    let old = change.oldValue?.compactDescription ?? "none"
    let new = change.newValue?.compactDescription ?? "none"
    return RimeProbeRecord(phase: "config.applied",
                           message: change.configID + " " + change.key + ": " + old + " -> " + new)
  }
}

extension RimeProbeRecord {
  /// S6 §3: activation is the other record the log gained — the profile and the generation it moved
  /// to, which is what makes "which build was the keyboard on" answerable after the fact.
  public static func profileActivated(profileID: String, generation: Int?) -> RimeProbeRecord {
    var message = profileID
    if let generation {
      message += " generation " + String(generation)
    }
    return RimeProbeRecord(phase: "profile.activate", message: message)
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

  /// A size a person reads, in one place. The app had two private copies of a `ByteCountFormatter`
  /// and a third that did its own `String(format:)`, which is how the same 12 MB ends up written
  /// three ways — and in whatever language the device is set to.
  public static func formatted(bytes: UInt64) -> String {
    if bytes < 1024 { return String(bytes) + " B" }
    let kilobytes = Double(bytes) / 1024
    if kilobytes < 1000 { return String(format: "%.0f KB", kilobytes) }
    let megabytes = kilobytes / 1024
    if megabytes < 1000 { return String(format: "%.1f MB", megabytes) }
    return String(format: "%.1f GB", megabytes / 1024)
  }

  /// Seconds since this process started, straight from the kernel, or nil if it will not say.
  /// This is what separates "dyld plus our own startup" from everything that happens afterwards:
  /// a mark taken at first appearance can say how long the app took to get there at all.
  public static func processAgeSeconds() -> Double? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return nil }
    // p_starttime is wall-clock, so it has to be compared against the wall clock. Subtracting
    // systemUptime (seconds since boot) from it is meaningless and yields a negative age.
    let start = Double(info.kp_proc.p_starttime.tv_sec)
      + Double(info.kp_proc.p_starttime.tv_usec) / 1_000_000
    let age = Date().timeIntervalSince1970 - start
    return age >= 0 ? age : nil
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

  /// Appends one JSON line.
  ///
  /// **O_APPEND, not seek-to-end plus write.** This file has two writers in two processes — the keyboard
  /// extension and the app — and `FileHandle.seekToEnd()` followed by a write is atomic only inside one
  /// process: two processes can both seek to the same offset and one line lands on top of the other.
  /// `O_APPEND` makes the kernel place every write at the end, which is what an append-only log needs.
  /// The old fallback was worse still: a failed `FileHandle` fell back to an *atomic* write, which
  /// replaces the file — one record would have truncated the whole log.
  public func append(_ record: RimeProbeRecord) {
    guard let data = try? encoder.encode(record) else { return }
    var line = data
    line.append(0x0A)
    lock.lock()
    defer { lock.unlock() }
    let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    guard descriptor >= 0 else { return }
    defer { close(descriptor) }
    line.withUnsafeBytes { buffer in
      guard let base = buffer.baseAddress else { return }
      var written = 0
      while written < buffer.count {
        let result = write(descriptor, base.advanced(by: written), buffer.count - written)
        if result <= 0 { break }
        written += result
      }
    }
  }

  public func readAll() -> [RimeProbeRecord] {
    guard let data = try? Data(contentsOf: url) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return data.split(separator: 0x0A).compactMap { try? decoder.decode(RimeProbeRecord.self, from: Data($0)) }
  }
}
