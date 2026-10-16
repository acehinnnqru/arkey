import Foundation

public enum RimeEngineError: Error, CustomStringConvertible, Sendable {
  /// rime_get_api() returned NULL, i.e. the librime symbols are not linked.
  case apiUnavailable
  /// librime did not accept the traits we handed it.
  case initializationFailed
  case notStarted
  case sessionCreationFailed
  case sessionNotOpen
  case deploymentFailed
  case dataDirectoryMissing(String)
  case configOpenFailed(String)
  case configParseFailed(String)
  case configValueMissing(String)
  case schemaSelectionFailed(String)

  public var description: String {
    switch self {
    case .apiUnavailable:
      return "rime_get_api() returned NULL (librime is not linked)"
    case .initializationFailed:
      return "RimeInitialize failed"
    case .notStarted:
      return "the Rime engine has not started"
    case .sessionCreationFailed:
      return "RimeCreateSession returned no session"
    case .sessionNotOpen:
      return "no Rime session is open"
    case .deploymentFailed:
      return "Rime deployment (maintenance) failed"
    case .dataDirectoryMissing(let path):
      return "required data directory is missing: " + path
    case .configOpenFailed(let id):
      return "librime could not open the configuration '" + id + "'"
    case .configParseFailed(let snippet):
      return "librime could not parse the YAML fragment: " + snippet
    case .configValueMissing(let key):
      return "configuration key is unset: " + key
    case .schemaSelectionFailed(let id):
      return "librime could not select the schema '" + id + "'"
    }
  }
}
