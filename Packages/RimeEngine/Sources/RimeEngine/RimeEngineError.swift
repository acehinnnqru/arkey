import Foundation

public enum RimeEngineError: Error, CustomStringConvertible, Sendable {
  /// rime_get_api() returned NULL, i.e. the librime symbols are not linked.
  case apiUnavailable
  /// librime did not accept the traits we handed it.
  case initializationFailed
  case sessionCreationFailed
  case sessionNotOpen
  case deploymentFailed
  case dataDirectoryMissing(String)

  public var description: String {
    switch self {
    case .apiUnavailable:
      return "rime_get_api() returned NULL (librime is not linked)"
    case .initializationFailed:
      return "RimeInitialize failed"
    case .sessionCreationFailed:
      return "RimeCreateSession returned no session"
    case .sessionNotOpen:
      return "no Rime session is open"
    case .deploymentFailed:
      return "Rime deployment (maintenance) failed"
    case .dataDirectoryMissing(let path):
      return "required data directory is missing: " + path
    }
  }
}
