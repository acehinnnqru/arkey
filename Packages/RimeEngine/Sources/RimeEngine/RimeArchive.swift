import Foundation
import Compression

// MARK: - Limits

/// The caps S1 §5.2 puts on an archive. Injectable so the tests can exercise each rule without
/// building a gigabyte of input.
public struct RimeArchiveLimits: Sendable, Equatable {
  public var maxEntries: Int
  public var maxTotalUncompressedBytes: Int
  public var maxEntryUncompressedBytes: Int
  /// Uncompressed-to-compressed ratio above which an archive is treated as a bomb.
  public var compressionRatioLimit: Int
  /// The ratio rule only applies once the compressed side is at least this large: a 2-byte file
  /// that inflates to 400 bytes is not an attack.
  public var compressionRatioFloorBytes: Int

  public init(maxEntries: Int = 20_000,
              maxTotalUncompressedBytes: Int = 1 << 30,
              maxEntryUncompressedBytes: Int = 256 << 20,
              compressionRatioLimit: Int = 200,
              compressionRatioFloorBytes: Int = 1 << 20) {
    self.maxEntries = maxEntries
    self.maxTotalUncompressedBytes = maxTotalUncompressedBytes
    self.maxEntryUncompressedBytes = maxEntryUncompressedBytes
    self.compressionRatioLimit = compressionRatioLimit
    self.compressionRatioFloorBytes = compressionRatioFloorBytes
  }

  public static let standard = RimeArchiveLimits()
}

// MARK: - Errors

/// Every rule has its own error: S1-AC4 says no failure is silent and each names the file.
public enum RimeArchiveError: Error, CustomStringConvertible, Sendable, Equatable {
  case notAZip
  case truncated(String)
  case unsupportedZip64
  case unsupportedCompression(UInt16, String)
  case entryLimitExceeded(Int)
  case totalSizeLimitExceeded(Int)
  case entrySizeLimitExceeded(String, Int)
  case compressionRatioExceeded(String, Int)
  case unsafePath(String)
  case entryTypeNotAllowed(String)
  case duplicateEntry(String)
  case caseCollision(String, String)
  case checksumMismatch(String)
  case sizeMismatch(String, Int, Int)
  case extractionFailed(String)

  public var description: String {
    switch self {
    case .notAZip:
      return "the file is not a zip archive"
    case .truncated(let what):
      return "the archive is truncated: " + what
    case .unsupportedZip64:
      return "zip64 archives are not accepted: the entry caps make them unnecessary"
    case .unsupportedCompression(let method, let path):
      return "entry '" + path + "' uses compression method " + String(method) + ", which is not supported"
    case .entryLimitExceeded(let count):
      return "the archive declares more than " + String(count) + " entries"
    case .totalSizeLimitExceeded(let bytes):
      return "the archive expands to more than " + String(bytes) + " bytes"
    case .entrySizeLimitExceeded(let path, let bytes):
      return "entry '" + path + "' is larger than " + String(bytes) + " bytes"
    case .compressionRatioExceeded(let path, let ratio):
      return "entry '" + path + "' expands more than " + String(ratio) + "x: a zip bomb"
    case .unsafePath(let path):
      return "entry path is unsafe: '" + path + "'"
    case .entryTypeNotAllowed(let path):
      return "entry '" + path + "' is not a regular file or a directory"
    case .duplicateEntry(let path):
      return "entry '" + path + "' appears twice"
    case .caseCollision(let first, let second):
      return "entries '" + first + "' and '" + second + "' collide on a case-insensitive filesystem"
    case .checksumMismatch(let path):
      return "entry '" + path + "' failed its CRC check"
    case .sizeMismatch(let path, let declared, let actual):
      return "entry '" + path + "' declared " + String(declared) + " bytes and produced " + String(actual)
    case .extractionFailed(let path):
      return "entry '" + path + "' could not be written"
    }
  }
}

// MARK: - CRC32

enum RimeCRC32 {
  private static let table: [UInt32] = {
    (0..<256).map { index -> UInt32 in
      var value = UInt32(index)
      for _ in 0..<8 {
        value = (value & 1) == 1 ? (0xEDB88320 ^ (value >> 1)) : (value >> 1)
      }
      return value
    }
  }()

  static func checksum(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFFFFFF
    data.withUnsafeBytes { raw in
      for byte in raw.bindMemory(to: UInt8.self) {
        crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
      }
    }
    return crc ^ 0xFFFFFFFF
  }
}

// MARK: - Archive reader

/// A read-only zip reader that enforces S1 §5.2 before a single byte reaches its destination.
///
/// Self-contained on purpose: the hardening rules need per-entry metadata (external attributes,
/// declared sizes, both name encodings) and an archive parser that exposes them is small next to
/// the work of proving a third-party one rejects everything this one has to reject. Deflate comes
/// from Apple's Compression framework; stored entries are copied.
public struct RimeZipArchive: Sendable {
  public struct Entry: Sendable, Hashable {
    public let path: String
    public let isDirectory: Bool
    public let compressedBytes: Int
    public let uncompressedBytes: Int
    public let method: UInt16
    public let checksum: UInt32
    let localHeaderOffset: Int
  }

  public let entries: [Entry]
  private let data: Data

  public init(url: URL, limits: RimeArchiveLimits = .standard) throws {
    let values = try url.resourceValues(forKeys: [.fileSizeKey])
    guard (values.fileSize ?? 0) > 0 else { throw RimeArchiveError.notAZip }
    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    try self.init(data: data, limits: limits)
  }

  public init(data: Data, limits: RimeArchiveLimits = .standard) throws {
    self.data = data
    self.entries = try RimeZipDirectory.parse(data: data, limits: limits)
  }

  /// Unpacks into `destination`, which must already exist and be inside staging.
  ///
  /// Nothing is written outside it: each path is re-checked against the destination after
  /// normalisation, so a path that survived the directory checks cannot escape here either.
  /// On any failure the destination is removed: a half-unpacked tree is not something a caller
  /// can reason about, and the importer's contract is that staging holds either a complete tree or
  /// nothing.
  @discardableResult
  public func extract(to destination: URL, limits: RimeArchiveLimits = .standard) throws -> [String] {
    do {
      return try extractEntries(to: destination, limits: limits)
    } catch {
      try? FileManager.default.removeItem(at: destination)
      throw error
    }
  }

  private func extractEntries(to destination: URL, limits: RimeArchiveLimits) throws -> [String] {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
    let root = destination.standardizedFileURL

    let directories = entries.filter(\.isDirectory).sorted { $0.path.count < $1.path.count }
    for entry in directories {
      let target = root.appendingPathComponent(entry.path)
      guard RimeZipDirectory.isContained(target, in: root) else {
        throw RimeArchiveError.unsafePath(entry.path)
      }
      try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
    }

    var written: [String] = []
    var total: Int = 0
    for entry in entries where !entry.isDirectory {
      let target = root.appendingPathComponent(entry.path)
      guard RimeZipDirectory.isContained(target, in: root) else {
        throw RimeArchiveError.unsafePath(entry.path)
      }
      try fileManager.createDirectory(at: target.deletingLastPathComponent(),
                                      withIntermediateDirectories: true)
      let contents = try payload(for: entry, limits: limits)
      total += contents.count
      if contents.count > limits.maxEntryUncompressedBytes {
        throw RimeArchiveError.entrySizeLimitExceeded(entry.path, limits.maxEntryUncompressedBytes)
      }
      if total > limits.maxTotalUncompressedBytes {
        throw RimeArchiveError.totalSizeLimitExceeded(limits.maxTotalUncompressedBytes)
      }
      guard RimeCRC32.checksum(contents) == entry.checksum else {
        throw RimeArchiveError.checksumMismatch(entry.path)
      }
      do {
        try contents.write(to: target, options: .atomic)
      } catch {
        throw RimeArchiveError.extractionFailed(entry.path)
      }
      written.append(entry.path)
    }
    return written
  }

  private func payload(for entry: Entry, limits: RimeArchiveLimits) throws -> Data {
    // Local file header: 30 bytes, then the name and extra fields, then the payload.
    let offset = entry.localHeaderOffset
    guard offset >= 0, offset + 30 <= data.count else {
      throw RimeArchiveError.truncated(entry.path)
    }
    guard RimeZipDirectory.readUInt32(data, offset) == 0x04034b50 else {
      throw RimeArchiveError.truncated("local header for " + entry.path)
    }
    let nameLength = Int(RimeZipDirectory.readUInt16(data, offset + 26))
    let extraLength = Int(RimeZipDirectory.readUInt16(data, offset + 28))
    let start = offset + 30 + nameLength + extraLength
    guard start + entry.compressedBytes <= data.count else {
      throw RimeArchiveError.truncated("payload for " + entry.path)
    }
    let compressed = data.subdata(in: start..<(start + entry.compressedBytes))

    let contents: Data
    switch entry.method {
    case 0:
      contents = compressed
    case 8:
      contents = try RimeDeflate.inflate(compressed,
                                         path: entry.path,
                                         maximumSize: limits.maxEntryUncompressedBytes)
    default:
      throw RimeArchiveError.unsupportedCompression(entry.method, entry.path)
    }
    guard contents.count == entry.uncompressedBytes else {
      throw RimeArchiveError.sizeMismatch(entry.path, entry.uncompressedBytes, contents.count)
    }
    return contents
  }
}

// MARK: - Directory parsing

enum RimeZipDirectory {
  static func parse(data: Data, limits: RimeArchiveLimits) throws -> [RimeZipArchive.Entry] {
    let endOfCentralDirectory = try findEndOfCentralDirectory(data)
    let entryCount = Int(readUInt16(data, endOfCentralDirectory + 10))
    let directorySize = Int(readUInt32(data, endOfCentralDirectory + 12))
    let directoryOffset = Int(readUInt32(data, endOfCentralDirectory + 16))

    guard entryCount != 0xFFFF, directoryOffset != 0xFFFF_FFFF, directorySize != 0xFFFF_FFFF else {
      throw RimeArchiveError.unsupportedZip64
    }
    guard entryCount <= limits.maxEntries else {
      throw RimeArchiveError.entryLimitExceeded(limits.maxEntries)
    }
    guard directoryOffset >= 0, directoryOffset + directorySize <= data.count else {
      throw RimeArchiveError.truncated("central directory")
    }

    var entries: [RimeZipArchive.Entry] = []
    var seen: [String: String] = [:]
    var folded: [String: String] = [:]
    var cursor = directoryOffset
    var declaredTotal = 0

    for _ in 0..<entryCount {
      guard cursor + 46 <= data.count, readUInt32(data, cursor) == 0x02014b50 else {
        throw RimeArchiveError.truncated("central directory entry")
      }
      let versionMadeBy = readUInt16(data, cursor + 4)
      let flags = readUInt16(data, cursor + 8)
      let method = readUInt16(data, cursor + 10)
      let declaredCRC = readUInt32(data, cursor + 16)
      let compressedBytes = Int(readUInt32(data, cursor + 20))
      let uncompressedBytes = Int(readUInt32(data, cursor + 24))
      let nameLength = Int(readUInt16(data, cursor + 28))
      let extraLength = Int(readUInt16(data, cursor + 30))
      let commentLength = Int(readUInt16(data, cursor + 32))
      let externalAttributes = readUInt32(data, cursor + 38)
      let localOffset = Int(readUInt32(data, cursor + 42))

      guard compressedBytes != 0xFFFF_FFFF, uncompressedBytes != 0xFFFF_FFFF,
            localOffset != 0xFFFF_FFFF else {
        throw RimeArchiveError.unsupportedZip64
      }

      let nameStart = cursor + 46
      guard nameStart + nameLength + extraLength + commentLength <= data.count else {
        throw RimeArchiveError.truncated("central directory entry name")
      }
      let nameData = data.subdata(in: nameStart..<(nameStart + nameLength))
      let name = try decodeName(nameData, flags: flags)

      let host = UInt8(versionMadeBy >> 8)
      let unixMode = UInt16(externalAttributes >> 16)
      let kind = unixMode & 0xF000
      // A Unix-made entry states its type in the high bits of the external attributes. An entry
      // that states nothing (kind == 0) is taken at face value rather than refused: plenty of
      // writers leave the type out, and the name is the only signal they give.
      let statesType = host == 3 && kind != 0
      let isSymlink = statesType && kind == 0xA000
      let isDirectory = name.hasSuffix("/") || (statesType && kind == 0x4000)
      let isSpecial = statesType && kind != 0x4000 && kind != 0x8000

      guard !isSymlink && !isSpecial else {
        throw RimeArchiveError.entryTypeNotAllowed(name)
      }
      try validatePath(name)
      guard method == 0 || method == 8 else {
        throw RimeArchiveError.unsupportedCompression(method, name)
      }
      guard uncompressedBytes <= limits.maxEntryUncompressedBytes else {
        throw RimeArchiveError.entrySizeLimitExceeded(name, limits.maxEntryUncompressedBytes)
      }
      if compressedBytes >= limits.compressionRatioFloorBytes,
         uncompressedBytes > compressedBytes * limits.compressionRatioLimit {
        throw RimeArchiveError.compressionRatioExceeded(name, limits.compressionRatioLimit)
      }
      let normalized = normalize(name)
      guard seen[normalized] == nil else {
        throw RimeArchiveError.duplicateEntry(name)
      }
      let foldedName = normalized.precomposedStringWithCanonicalMapping.lowercased()
      if let other = folded[foldedName] {
        throw RimeArchiveError.caseCollision(other, name)
      }
      seen[normalized] = name
      folded[foldedName] = name

      declaredTotal += uncompressedBytes
      guard declaredTotal <= limits.maxTotalUncompressedBytes else {
        throw RimeArchiveError.totalSizeLimitExceeded(limits.maxTotalUncompressedBytes)
      }

      entries.append(RimeZipArchive.Entry(path: normalized,
                                          isDirectory: isDirectory,
                                          compressedBytes: compressedBytes,
                                          uncompressedBytes: uncompressedBytes,
                                          method: method,
                                          checksum: declaredCRC,
                                          localHeaderOffset: localOffset))
      cursor = nameStart + nameLength + extraLength + commentLength
    }
    return entries
  }

  static func validatePath(_ path: String) throws {
    guard !path.isEmpty else { throw RimeArchiveError.unsafePath(path) }
    guard !path.contains("\0") else { throw RimeArchiveError.unsafePath(path) }
    guard !path.hasPrefix("/") else { throw RimeArchiveError.unsafePath(path) }
    guard !path.contains("\\") else { throw RimeArchiveError.unsafePath(path) }
    guard !path.contains(":") else { throw RimeArchiveError.unsafePath(path) }
    guard !path.contains("//") else { throw RimeArchiveError.unsafePath(path) }
    for component in path.split(separator: "/") where component == ".." {
      throw RimeArchiveError.unsafePath(path)
    }
  }

  static func normalize(_ path: String) -> String {
    var value = path
    while value.hasSuffix("/") { value.removeLast() }
    return value
  }

  static func isContained(_ url: URL, in root: URL) -> Bool {
    let target = url.standardizedFileURL.path
    let base = root.standardizedFileURL.path
    return target == base || target.hasPrefix(base + "/")
  }

  private static func decodeName(_ data: Data, flags: UInt16) throws -> String {
    // Bit 11 is the UTF-8 flag. Without it the name is CP437 by specification; a Windows code
    // page is close enough for the paths a Rime config uses, and anything undecodable is refused
    // rather than guessed at.
    if flags & 0x0800 != 0 {
      guard let name = String(data: data, encoding: .utf8) else {
        throw RimeArchiveError.unsafePath("<undecodable name>")
      }
      return name
    }
    if let name = String(data: data, encoding: .utf8) { return name }
    guard let name = String(data: data, encoding: .isoLatin1) else {
      throw RimeArchiveError.unsafePath("<undecodable name>")
    }
    return name
  }

  private static func findEndOfCentralDirectory(_ data: Data) throws -> Int {
    let minimumSize = 22
    guard data.count >= minimumSize else { throw RimeArchiveError.notAZip }
    let maximumComment = 0xFFFF
    let searchStart = max(0, data.count - minimumSize - maximumComment)
    var index = data.count - minimumSize
    while index >= searchStart {
      if readUInt32(data, index) == 0x06054b50 {
        return index
      }
      index -= 1
    }
    throw RimeArchiveError.notAZip
  }

  static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
    guard offset >= 0, offset + 2 <= data.count else { return 0 }
    return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
  }

  static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
    guard offset >= 0, offset + 4 <= data.count else { return 0 }
    return UInt32(data[offset])
      | (UInt32(data[offset + 1]) << 8)
      | (UInt32(data[offset + 2]) << 16)
      | (UInt32(data[offset + 3]) << 24)
  }
}

// MARK: - Deflate

enum RimeDeflate {
  /// Raw DEFLATE, which is what a zip entry stores. Capped while inflating: the declared size is
  /// written by whoever built the archive.
  static func inflate(_ input: Data, path: String, maximumSize: Int) throws -> Data {
    guard !input.isEmpty else { return Data() }
    var output = Data()
    let bufferSize = 64 * 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    var failure: RimeArchiveError?
    input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      guard let source = raw.bindMemory(to: UInt8.self).baseAddress else { return }
      var stream = compression_stream(dst_ptr: buffer, dst_size: bufferSize,
                                      src_ptr: source, src_size: raw.count, state: nil)
      guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        == COMPRESSION_STATUS_OK else {
        failure = .unsupportedCompression(8, path)
        return
      }
      defer { compression_stream_destroy(&stream) }
      stream.src_ptr = source
      stream.src_size = raw.count
      stream.dst_ptr = buffer
      stream.dst_size = bufferSize

      while true {
        let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
        let produced = bufferSize - stream.dst_size
        if produced > 0 {
          output.append(buffer, count: produced)
          if output.count > maximumSize {
            failure = .entrySizeLimitExceeded(path, maximumSize)
            return
          }
        }
        if status == COMPRESSION_STATUS_END { return }
        if status == COMPRESSION_STATUS_ERROR {
          failure = .extractionFailed(path + " (the deflate stream is corrupt)")
          return
        }
        stream.dst_ptr = buffer
        stream.dst_size = bufferSize
      }
    }
    if let failure { throw failure }
    return output
  }
}

// MARK: - Writer

/// A minimal store-only zip writer.
///
/// Used by the tests to build fixtures, and by S2 §7 to export the patch set — a handful of small
/// text files, for which compression buys nothing and a well-understood 60 lines buys a lot.
public struct RimeZipWriter {
  private struct Member {
    let path: String
    let contents: Data
    let crc: UInt32
  }

  private var members: [Member] = []

  public init() {}

  public mutating func addFile(path: String, contents: Data) throws {
    try RimeZipDirectory.validatePath(path)
    members.append(Member(path: path, contents: contents, crc: RimeCRC32.checksum(contents)))
  }

  public mutating func addFile(path: String, text: String) throws {
    try addFile(path: path, contents: Data(text.utf8))
  }

  public func data() -> Data {
    var output = Data()
    var directory = Data()
    for member in members {
      let name = Data(member.path.utf8)
      let offset = UInt32(output.count)
      output.append(uint32: 0x04034b50)
      output.append(uint16: 20)          // version needed
      output.append(uint16: 0)           // flags
      output.append(uint16: 0)           // method: stored
      output.append(uint16: 0)           // time
      output.append(uint16: 0x21)        // date: 1980-01-01
      output.append(uint32: member.crc)
      output.append(uint32: UInt32(member.contents.count))
      output.append(uint32: UInt32(member.contents.count))
      output.append(uint16: UInt16(name.count))
      output.append(uint16: 0)
      output.append(name)
      output.append(member.contents)

      directory.append(uint32: 0x02014b50)
      directory.append(uint16: 0x031E)   // made by: unix, 3.0
      directory.append(uint16: 20)
      directory.append(uint16: 0)
      directory.append(uint16: 0)
      directory.append(uint16: 0)
      directory.append(uint16: 0x21)
      directory.append(uint32: member.crc)
      directory.append(uint32: UInt32(member.contents.count))
      directory.append(uint32: UInt32(member.contents.count))
      directory.append(uint16: UInt16(name.count))
      directory.append(uint16: 0)
      directory.append(uint16: 0)
      directory.append(uint16: 0)
      directory.append(uint16: 0)
      directory.append(uint32: 0o100644 << 16)
      directory.append(uint32: offset)
      directory.append(name)
    }
    let directoryOffset = UInt32(output.count)
    output.append(directory)
    output.append(uint32: 0x06054b50)
    output.append(uint16: 0)
    output.append(uint16: 0)
    output.append(uint16: UInt16(members.count))
    output.append(uint16: UInt16(members.count))
    output.append(uint32: UInt32(directory.count))
    output.append(uint32: directoryOffset)
    output.append(uint16: 0)
    return output
  }

  public func write(to url: URL) throws {
    try data().write(to: url, options: .atomic)
  }
}

extension Data {
  mutating func append(uint16 value: UInt16) {
    append(UInt8(value & 0xFF))
    append(UInt8((value >> 8) & 0xFF))
  }

  mutating func append(uint32 value: UInt32) {
    append(UInt8(value & 0xFF))
    append(UInt8((value >> 8) & 0xFF))
    append(UInt8((value >> 16) & 0xFF))
    append(UInt8((value >> 24) & 0xFF))
  }
}
