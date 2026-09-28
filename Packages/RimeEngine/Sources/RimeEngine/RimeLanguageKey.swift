import CoreGraphics
import Foundation

/// The 中/英 key's state, from the schema (S3 §5, S4 §7).
///
/// The label comes from `get_state_label`, never from us: a schema that calls its states 中文/西文 and
/// one that calls them something else both render correctly, and the key shows the state the user is
/// *in* rather than the one a tap would switch to — which is what the system keyboard does.
public struct RimeLanguageKey: Sendable, Hashable {
  public let label: String
  public let isASCII: Bool

  public init(label: String, isASCII: Bool) {
    self.label = label
    self.isASCII = isASCII
  }
}
