import Foundation
import os

/// System log sink. The extension is a separate process, so this is what shows up in
/// Console.app (subsystem com.acehinnnqru.arkey) when the keyboard misbehaves on a device.
enum KeyboardLog {
  private static let logger = Logger(subsystem: "com.acehinnnqru.arkey", category: "keyboard")

  static func info(_ message: String) {
    logger.info("(message, privacy: .public)")
  }

  static func error(_ message: String) {
    logger.error("(message, privacy: .public)")
  }
}
