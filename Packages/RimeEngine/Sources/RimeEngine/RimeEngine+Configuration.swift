import Foundation
import Rime

/// A handle to one open librime configuration.
///
/// It is only valid while the engine's serial queue is executing the body of
/// `RimeEngine.withUserConfig` (or one of its siblings): librime's config objects are not
/// thread-safe, and the handle deliberately has no queue of its own so that a nested call cannot
/// deadlock the engine. `close()` saves the file, which is how Rime writes patches.
public final class RimeConfigRef {
  private let api: UnsafeMutablePointer<rime_api_t>
  var config: RimeConfig
  public let configID: String
  private var isClosed = false

  init(api: UnsafeMutablePointer<rime_api_t>, config: RimeConfig, configID: String) {
    self.api = api
    self.config = config
    self.configID = configID
  }

  deinit {
    close()
  }

  /// Closes the config, which is what makes librime write it back to disk when it was modified.
  public func close() {
    guard !isClosed else { return }
    isClosed = true
    _ = api.pointee.config_close?(&config)
  }

  // MARK: - Reading

  /// A type probe, in librime's own order: a value has exactly one type.
  private func scalar(_ key: String) -> RimeConfigValue? {
    var boolean = false
    if api.pointee.config_get_bool?(&config, key, &boolean) == true {
      return .bool(boolean)
    }
    var integer: Int32 = 0
    if api.pointee.config_get_int?(&config, key, &integer) == true {
      return .int(Int(integer))
    }
    var real = 0.0
    if api.pointee.config_get_double?(&config, key, &real) == true {
      return .double(real)
    }
    if let text = api.pointee.config_get_cstring?(&config, key) {
      return .string(String(cString: text))
    }
    return nil
  }

  /// The whole value at `key`, recursing through maps and lists. Nil when the key is unset.
  public func value(_ key: String) -> RimeConfigValue? {
    if let scalar = scalar(key) { return scalar }

    var iterator = RimeConfigIterator()
    if api.pointee.config_begin_map?(&iterator, &config, key) == true {
      var entries: [String: RimeConfigValue] = [:]
      while api.pointee.config_next?(&iterator) == true {
        guard let path = iterator.path, let name = iterator.key else { continue }
        if let child = value(String(cString: path)) {
          entries[String(cString: name)] = child
        }
      }
      api.pointee.config_end?(&iterator)
      return .map(entries)
    }

    if api.pointee.config_begin_list?(&iterator, &config, key) == true {
      var items: [RimeConfigValue] = []
      while api.pointee.config_next?(&iterator) == true {
        guard let path = iterator.path else { continue }
        if let child = value(String(cString: path)) {
          items.append(child)
        }
      }
      api.pointee.config_end?(&iterator)
      return .list(items)
    }

    return nil
  }

  public func string(_ key: String) -> String? {
    api.pointee.config_get_cstring?(&config, key).map { String(cString: $0) }
  }

  public func int(_ key: String) -> Int? {
    var value: Int32 = 0
    guard api.pointee.config_get_int?(&config, key, &value) == true else { return nil }
    return Int(value)
  }

  public func double(_ key: String) -> Double? {
    var value = 0.0
    guard api.pointee.config_get_double?(&config, key, &value) == true else { return nil }
    return value
  }

  public func bool(_ key: String) -> Bool? {
    var value = false
    guard api.pointee.config_get_bool?(&config, key, &value) == true else { return nil }
    return value
  }

  /// Map keys of `key`, in librime's iteration order.
  public func mapKeys(_ key: String) -> [String] {
    var iterator = RimeConfigIterator()
    guard api.pointee.config_begin_map?(&iterator, &config, key) == true else { return [] }
    var keys: [String] = []
    while api.pointee.config_next?(&iterator) == true {
      if let name = iterator.key {
        keys.append(String(cString: name))
      }
    }
    api.pointee.config_end?(&iterator)
    return keys
  }

  /// Full paths of the entries of the list at `key`, e.g. `schema_list/@1`.
  public func listPaths(_ key: String) -> [String] {
    var iterator = RimeConfigIterator()
    guard api.pointee.config_begin_list?(&iterator, &config, key) == true else { return [] }
    var paths: [String] = []
    while api.pointee.config_next?(&iterator) == true {
      if let path = iterator.path {
        paths.append(String(cString: path))
      }
    }
    api.pointee.config_end?(&iterator)
    return paths
  }

  public func listSize(_ key: String) -> Int {
    Int(api.pointee.config_list_size?(&config, key) ?? 0)
  }

  // MARK: - Writing

  /// Every leaf path under `key`, relative to it: `menu/page_size`, not `menu`.
  /// A settings screen lists keys, and Rime's tree is nested, so one level of `mapKeys` is not
  /// enough to describe what a patch file says.
  public func leafPaths(_ key: String) -> [String] {
    let prefix = key.isEmpty ? "" : key + "/"
    return RimeConfigValidation.flatten(config: self, prefix: key, depth: 0).map { entry in
      entry.0.hasPrefix(prefix) ? String(entry.0.dropFirst(prefix.count)) : entry.0
    }
  }

  public func clear(_ key: String) {
    _ = api.pointee.config_clear?(&config, key)
  }

  /// Writes a value, creating the intermediate maps and lists a path implies.
  ///
  /// Lists are written as `key/@N` with N starting at 0, which is Rime's own list syntax, and a
  /// list or map is cleared first: Rime's patch semantics replace such a value wholesale, so
  /// merging would be a lie about what the file says.
  @discardableResult
  public func set(_ value: RimeConfigValue, at key: String) -> Bool {
    switch value {
    case .bool(let raw):
      return api.pointee.config_set_bool?(&config, key, raw) == true
    case .int(let raw):
      return api.pointee.config_set_int?(&config, key, Int32(raw)) == true
    case .double(let raw):
      return api.pointee.config_set_double?(&config, key, raw) == true
    case .string(let raw):
      return api.pointee.config_set_string?(&config, key, raw) == true
    case .list(let items):
      clear(key)
      guard api.pointee.config_create_list?(&config, key) == true else { return false }
      for (index, item) in items.enumerated() where !set(item, at: key + "/@" + String(index)) {
        return false
      }
      return true
    case .map(let entries):
      clear(key)
      guard api.pointee.config_create_map?(&config, key) == true else { return false }
      for (name, item) in entries where !set(item, at: key + "/" + name) {
        return false
      }
      return true
    }
  }

  /// Copies a subtree out of another config into this one, which is how a YAML fragment becomes a
  /// patch. The source is a *sub-item*, extracted with `config_get_item`: handing
  /// `config_set_item` a whole config crashes librime 1.17 (measured — see the test that records
  /// it), so the root item is never used.
  @discardableResult
  public func setItem(from other: RimeConfigRef, sourceKey: String, key: String) -> Bool {
    guard !other.isClosed else { return false }
    guard let getItem = api.pointee.config_get_item,
          let setItem = api.pointee.config_set_item else { return false }
    var item = RimeConfig()
    guard getItem(&other.config, sourceKey, &item) else { return false }
    defer { _ = api.pointee.config_close?(&item) }
    return setItem(&config, key, &item)
  }
}

extension RimeEngine {
  /// Opens the user's copy of a config: `<user>/<configID>.yaml`, the file a patch is written to.
  /// Closing it saves.
  public func withUserConfig<T>(_ configID: String, _ body: (RimeConfigRef) throws -> T) throws -> T {
    try perform {
      let api = try requireAPI()
      guard let open = api.pointee.user_config_open else { throw RimeEngineError.apiUnavailable }
      var config = RimeConfig()
      let box = CStringBox(configID)
      guard open(box.raw, &config) else {
        throw RimeEngineError.configOpenFailed(configID)
      }
      let reference = RimeConfigRef(api: api, config: config, configID: configID)
      defer { reference.close() }
      return try body(reference)
    }
  }

  /// Opens a deployed configuration by id, with the user's patches already applied.
  public func withConfig<T>(_ configID: String, _ body: (RimeConfigRef) throws -> T) throws -> T {
    try perform {
      let api = try requireAPI()
      guard let open = api.pointee.config_open else { throw RimeEngineError.apiUnavailable }
      var config = RimeConfig()
      let box = CStringBox(configID)
      guard open(box.raw, &config) else {
        throw RimeEngineError.configOpenFailed(configID)
      }
      let reference = RimeConfigRef(api: api, config: config, configID: configID)
      defer { reference.close() }
      return try body(reference)
    }
  }

  /// Opens a schema's deployed configuration, as librime sees it after deployment.
  public func withSchemaConfig<T>(_ schemaID: String, _ body: (RimeConfigRef) throws -> T) throws -> T {
    try perform {
      let api = try requireAPI()
      guard let open = api.pointee.schema_open else { throw RimeEngineError.apiUnavailable }
      var config = RimeConfig()
      let box = CStringBox(schemaID)
      guard open(box.raw, &config) else {
        throw RimeEngineError.configOpenFailed(schemaID)
      }
      let reference = RimeConfigRef(api: api, config: config, configID: schemaID)
      defer { reference.close() }
      return try body(reference)
    }
  }

  /// Builds a detached config from a YAML string. Used to turn a list or a map into something
  /// `config_set_item` can copy into a patch.
  public func configFromYAML(_ yaml: String) throws -> RimeConfigRef {
    try perform {
      let api = try requireAPI()
      guard let initialize = api.pointee.config_init,
            let load = api.pointee.config_load_string else {
        throw RimeEngineError.apiUnavailable
      }
      var config = RimeConfig()
      guard initialize(&config) else { throw RimeEngineError.configOpenFailed("(yaml)") }
      let box = CStringBox(yaml)
      guard load(&config, box.raw) else {
        _ = api.pointee.config_close?(&config)
        throw RimeEngineError.configParseFailed(String(yaml.prefix(120)))
      }
      // The handle is detached from the engine: the caller owns it and must close it. It was
      // built on this queue, and every method on it must be called from this queue too.
      return RimeConfigRef(api: api, config: config, configID: "(yaml)")
    }
  }

  /// Reads one value from the effective (deployed, patched) configuration of a schema.
  public func schemaValue(_ key: String, schemaID: String) throws -> RimeConfigValue? {
    try withSchemaConfig(schemaID) { $0.value(key) }
  }
}
