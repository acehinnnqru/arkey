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
  public func percentile(_ quantile: Double) -> Double {
    guard !samples.isEmpty else { return 0 }
    let sorted = samples.sorted()
    let rank = Int((quantile * Double(sorted.count)).rounded(.up))
    return sorted[min(sorted.count, max(1, rank)) - 1]
  }

  /// S4 §9's budget is a **p99** (≤ 30 ms to the candidate bar), and the tracer-bullet results quote
  /// p50/p99, so the window carries all three: the record can answer the budget and the "typical key"
  /// question without re-deriving either.
  public var p50: Double { percentile(0.50) }
  public var p95: Double { percentile(0.95) }
  public var p99: Double { percentile(0.99) }

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

  /// What the probe record's message says: how many keys, and the numbers a reader compares against the
  /// budget — p99 first among them, because that is the one S4 §9 sets.
  public var message: String {
    "keys=" + String(count)
      + " avgMs=" + String(format: "%.2f", average)
      + " p50Ms=" + String(format: "%.2f", p50)
      + " p95Ms=" + String(format: "%.2f", p95)
      + " p99Ms=" + String(format: "%.2f", p99)
      + " maxMs=" + String(format: "%.2f", worst)
  }
}
