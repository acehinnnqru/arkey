import Foundation

// MARK: - Probe summaries

/// The probe log as **numbers**, which is what the acceptance criteria ask for: S1-AC8 wants the deploy
/// duration, the app footprint, the extension boot and the footprint after typing, S4-AC6 the per-key cost.
/// The raw JSONL stays for copying out; this is what a person reads on the device.
public struct RimeProbeSummary: Sendable {
  public struct Phase: Sendable, Hashable {
    public let name: String
    public let count: Int
    /// Nearest-rank over the samples: no statistics library, and a percentile a reader can reproduce.
    public let medianMilliseconds: Double?
    public let p95Milliseconds: Double?
    public let maxMilliseconds: Double?
    public let lastMilliseconds: Double?
    public let maxFootprintBytes: UInt64?
    public let lastFootprintBytes: UInt64?
    public let lastMessage: String?
  }

  /// One row per phase, sorted by name. A phase with no timings (a boot failure, say) still gets a row.
  public let phases: [Phase]
  public let recordCount: Int
  public let firstTimestamp: Date?
  public let lastTimestamp: Date?

  /// The phases the specs' tables name, in their order. They lead the list; everything else follows.
  public static let headlinePhases = ["keyboard.boot", "keyboard.stats", "engine.deploy", "engine.start"]

  public init(records: [RimeProbeRecord]) {
    recordCount = records.count
    firstTimestamp = records.map(\.timestamp).min()
    lastTimestamp = records.map(\.timestamp).max()

    var grouped: [String: [RimeProbeRecord]] = [:]
    for record in records { grouped[record.phase, default: []].append(record) }
    phases = grouped.keys.sorted().map { name in
      let group = (grouped[name] ?? []).sorted { $0.timestamp < $1.timestamp }
      let timings = group.compactMap(\.milliseconds).sorted()
      let footprints = group.compactMap(\.footprintBytes)
      return Phase(name: name,
                   count: group.count,
                   medianMilliseconds: RimeProbeSummary.percentile(timings, 0.5),
                   p95Milliseconds: RimeProbeSummary.percentile(timings, 0.95),
                   maxMilliseconds: timings.last,
                   lastMilliseconds: group.last?.milliseconds,
                   maxFootprintBytes: footprints.max(),
                   lastFootprintBytes: group.last?.footprintBytes,
                   lastMessage: group.last?.message)
    }
  }

  public var isEmpty: Bool { recordCount == 0 }

  /// The summary as text, which is what a device run copies out: the numbers first, one line per phase, and
  /// the reason a phase without timings carries.
  public func report() -> String {
    guard !isEmpty else { return "probe log: no records" }
    var lines = ["probe log: " + String(recordCount) + " records"]
    if let first = firstTimestamp, let last = lastTimestamp {
      lines.append("first " + RimeProbeSummary.stamp(first) + ", last " + RimeProbeSummary.stamp(last))
    }
    for phase in orderedPhases {
      var parts = [String(phase.count) + " samples"]
      if let median = phase.medianMilliseconds {
        parts.append("median " + RimeProbeSummary.number(median) + " ms")
      }
      if let p95 = phase.p95Milliseconds { parts.append("p95 " + RimeProbeSummary.number(p95) + " ms") }
      if let worst = phase.maxMilliseconds { parts.append("max " + RimeProbeSummary.number(worst) + " ms") }
      if let bytes = phase.lastFootprintBytes {
        parts.append("footprint " + RimeProbeSummary.number(RimeProbe.megabytes(bytes)) + " MB")
      }
      if let bytes = phase.maxFootprintBytes, bytes != phase.lastFootprintBytes {
        parts.append("peak " + RimeProbeSummary.number(RimeProbe.megabytes(bytes)) + " MB")
      }
      if let message = phase.lastMessage { parts.append(message) }
      lines.append("  " + phase.name + ": " + parts.joined(separator: ", "))
    }
    return lines.joined(separator: "\n")
  }

  static func number(_ value: Double) -> String { String(format: "%.1f", value) }

  static func stamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    return formatter.string(from: date)
  }

  /// The rows in the order a reader wants them: the spec's phases first, then the rest by name.
  public var orderedPhases: [Phase] {
    let byName = Dictionary(uniqueKeysWithValues: phases.map { ($0.name, $0) })
    let headline = RimeProbeSummary.headlinePhases.compactMap { byName[$0] }
    let named = Set(RimeProbeSummary.headlinePhases)
    return headline + phases.filter { !named.contains($0.name) }
  }

  /// Nearest-rank percentile over an already-sorted list.
  static func percentile(_ sorted: [Double], _ fraction: Double) -> Double? {
    guard !sorted.isEmpty else { return nil }
    let rank = Int((fraction * Double(sorted.count)).rounded(.up))
    return sorted[min(sorted.count, max(1, rank)) - 1]
  }
}