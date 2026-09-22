import Foundation
import Rime

/// Access to the versioned librime C API.
///
/// librime 1.17 no longer exports free functions such as RimeInitialize: the only entry point is
/// the vtable returned by rime_get_api(). Member availability should be checked before use
/// (RIME_API_AVAILABLE is a C macro and cannot be imported).
public enum RimeAPI {
  public static var pointer: UnsafeMutablePointer<rime_api_t>? {
    rime_get_api()
  }

  public static var version: String {
    guard let api = pointer, let getVersion = api.pointee.get_version,
          let version = getVersion() else { return "unavailable" }
    return String(cString: version)
  }

  /// RIME_STRUCT_INIT(Type, var) has no Swift equivalent: every self-versioned struct needs
  /// data_size set to the size of the struct minus the size of the data_size field itself.
  public static func dataSize<T>(of type: T.Type) -> Int32 {
    Int32(MemoryLayout<T>.size - MemoryLayout<Int32>.size)
  }
}

/// Keeps a C string alive for as long as librime may hold on to the pointer.
final class CStringBox {
  private let storage: UnsafeMutablePointer<CChar>?

  /// Immutable view of the buffer. The traits struct takes const char *, and Swift does not
  /// implicitly convert a mutable pointer to a const one in an assignment.
  var raw: UnsafePointer<CChar>? {
    storage.map { UnsafePointer($0) }
  }

  init(_ value: String) {
    storage = strdup(value)
  }

  deinit {
    if let storage {
      free(storage)
    }
  }
}
