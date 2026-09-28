import Foundation

// MARK: - Learning

/// S5-AC6's decision, in one place: a schema that turns learning off leaves sync with nothing to do, and the
/// screen has to say that rather than show an error. It lived in the app as a schema lookup nobody could test —
/// and the key name and the meaning of `false` are the kind of detail that drifts.
public enum RimeUserDictionaryLearning {
  /// What a schema sets to opt in or out of learning from committed text.
  public static let schemaKey = "translator/enable_user_dict"

  /// Whether the schema learns from what the user commits, or nil when it says nothing about it — a schema that
  /// leaves the key out inherits librime's default, and "inherits" is not the same claim as "on".
  public static func isEnabled(engine: RimeEngine, schemaID: String) throws -> Bool? {
    try engine.schemaValue(schemaKey, schemaID: schemaID)?.boolValue
  }
}
