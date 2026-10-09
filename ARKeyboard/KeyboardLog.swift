import Foundation
import os
import RimeEngine

/// System log sink. The extension is a separate process, so this is what shows up in
/// Console.app (subsystem com.acehinnnqru.arkey) when the keyboard misbehaves on a device.
enum KeyboardLog {
  private static let logger = Logger(subsystem: "com.acehinnnqru.arkey", category: "keyboard")
  private static let geometryQueue = DispatchQueue(label: "com.acehinnnqru.arkey.geometry", qos: .utility)

  static func info(_ message: String) {
    logger.info("\(message, privacy: .public)")
  }

  static func error(_ message: String) {
    logger.error("\(message, privacy: .public)")
  }

  /// Keep diagnostic disk writes off the keyboard's presentation/layout path.
  static func geometry(_ record: RimeProbeRecord, probe: RimeProbeLog?, includeSystemLog: Bool = true) {
    geometryQueue.async {
      if includeSystemLog {
        logger.notice("\(record.message ?? record.phase, privacy: .public)")
      }
      probe?.append(record)
    }
  }
}
