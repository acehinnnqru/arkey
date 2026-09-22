import Foundation

/// X11 keysyms, which is what process_key on the librime API expects.
///
/// UIKit key presses must be translated into these values: letters and punctuation are their
/// ASCII code point, everything else comes from the X11 table below.
public enum RimeKey {
  public static let space: Int32 = 0x0020
  public static let backSpace: Int32 = 0xFF08
  public static let tab: Int32 = 0xFF09
  public static let lineFeed: Int32 = 0xFF0A
  public static let returnKey: Int32 = 0xFF0D
  public static let escape: Int32 = 0xFF1B
  public static let delete: Int32 = 0xFFFF
  public static let home: Int32 = 0xFF50
  public static let left: Int32 = 0xFF51
  public static let up: Int32 = 0xFF52
  public static let right: Int32 = 0xFF53
  public static let down: Int32 = 0xFF54
  public static let pageUp: Int32 = 0xFF55
  public static let pageDown: Int32 = 0xFF56
  public static let end: Int32 = 0xFF57
  public static let shift: Int32 = 0xFFE1
  public static let control: Int32 = 0xFFE3

  /// Keysym for a plain ASCII character, or nil for anything outside ASCII.
  public static func ascii(_ character: Character) -> Int32? {
    guard let value = character.asciiValue else { return nil }
    return Int32(value)
  }
}

/// Modifier mask bits, mirroring librime's modifier flags.
public struct RimeModifier: OptionSet, Sendable, Hashable {
  public let rawValue: Int32
  public init(rawValue: Int32) { self.rawValue = rawValue }

  public static let shift = RimeModifier(rawValue: 1 << 0)
  public static let lock = RimeModifier(rawValue: 1 << 1)
  public static let control = RimeModifier(rawValue: 1 << 2)
  public static let alt = RimeModifier(rawValue: 1 << 3)
  public static let superKey = RimeModifier(rawValue: 1 << 4)
  public static let release = RimeModifier(rawValue: 1 << 30)

  public static let none: RimeModifier = []
}
