import Foundation

// MARK: - Key latency windows

/// S4-AC6's per-key numbers, gathered without a file write per key.
///
/// The keyboard cannot append a probe record on every key — the input path is synchronous (S3-AC5) — so it
/// batches. Batching the *samples* rather than only their average is what makes the number honest: the record
/// carries the window's **p95**, so what the probe summary aggregates are per-key percentiles, not the average
/// of twenty-five keys, which would hide every spike the criterion is about.
public struct RimeKeyLatencyWindow: Sendable {
  public let capacity: Int
  private var samples: [Double] = []
  private var total: Double = 0
  private var worst: Double = 0

  public init(capacity: Int = 25) {
    self.capacity = max(1, capacity)
  }

  /// Keys recorded since the last `reset()`.
  public var count: Int { samples.count }
  public var isEmpty: Bool { samples.isEmpty }
  public var isFull: Bool { samples.count >= capacity }
  public var average: Double { samples.isEmpty ? 0 : total / Double(samples.count) }
  public var maximum: Double { worst }

  /// Nearest-rank over the window, the same rule `RimeProbeSummary` uses on the records.
  public var p95: Double {
    guard !samples.isEmpty else { return 0 }
    let sorted = samples.sorted()
    let rank = Int((0.95 * Double(sorted.count)).rounded(.up))
    return sorted[min(sorted.count, max(1, rank)) - 1]
  }

  public mutating func record(milliseconds: Double) {
    samples.append(milliseconds)
    total += milliseconds
    worst = Swift.max(worst, milliseconds)
  }

  public mutating func reset() {
    samples.removeAll(keepingCapacity: true)
    total = 0
    worst = 0
  }

  /// What the probe record's message says: how many keys, and the three numbers a reader compares against
  /// the budget.
  public var message: String {
    "keys=" + String(count)
      + " avgMs=" + String(format: "%.2f", average)
      + " p95Ms=" + String(format: "%.2f", p95)
      + " maxMs=" + String(format: "%.2f", worst)
  }
}
